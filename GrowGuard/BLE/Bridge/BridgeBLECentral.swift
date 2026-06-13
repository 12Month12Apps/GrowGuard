//
//  BridgeBLECentral.swift
//  GrowGuard
//
//  Debug-only implementation of the BLECentral / BLEPeripheralLink seam that
//  forwards over the bridge socket instead of CoreBluetooth. Everything above
//  the seam (ConnectionPoolManager, DeviceConnection, history flow, retry/skip,
//  reconnect/resume) runs unchanged. Active only when GROWGUARD_BLE_BRIDGE is
//  set; otherwise the real CoreBluetooth transport is used.
//

#if DEBUG
import Foundation
import CoreBluetooth

final class BridgeBLECentral: NSObject, BLECentral {

    weak var centralDelegate: BLECentralDelegate?
    private(set) var state: CBManagerState = .unknown

    private let channel: BridgeChannel
    private var links: [String: BridgeBLEPeripheralLink] = [:]

    init(channel: BridgeChannel) {
        self.channel = channel
        super.init()
        channel.onReady = { [weak self] in
            guard let self = self else { return }
            self.state = .poweredOn
            self.centralDelegate?.central(self, didUpdateState: .poweredOn)
        }
        channel.onClosed = { [weak self] in
            guard let self = self else { return }
            self.state = .poweredOff
            self.centralDelegate?.central(self, didUpdateState: .poweredOff)
        }
        channel.onReceive = { [weak self] message in self?.handle(message) }
        channel.connect()
    }

    private func link(for id: String) -> BridgeBLEPeripheralLink {
        if let existing = links[id] { return existing }
        let link = BridgeBLEPeripheralLink(id: id, channel: channel)
        links[id] = link
        return link
    }

    // MARK: BLECentral

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        identifiers.map { link(for: $0.uuidString) }
    }

    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        channel.send(.connect(id: peripheral.identifier.uuidString))
    }

    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        channel.send(.cancel(id: peripheral.identifier.uuidString))
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        channel.send(.scan)
    }

    func stopScan() {
        channel.send(.stopScan)
    }

    // MARK: Inbound events

    private func handle(_ message: BridgeMessage) {
        switch message {
        case let .discovered(id, name, _, rssi):
            let link = link(for: id)
            link.cachedName = name
            centralDelegate?.central(self, didDiscover: link,
                                     advertisementData: [CBAdvertisementDataLocalNameKey: name as Any],
                                     rssi: NSNumber(value: rssi))
        case let .connected(id):
            let link = link(for: id)
            link.bridgeState = .connected
            centralDelegate?.central(self, didConnect: link)
        case let .disconnected(id, errorCode):
            let link = link(for: id)
            link.bridgeState = .disconnected
            centralDelegate?.central(self, didDisconnect: link, error: errorCode.map { Self.cbError($0) })
        case let .servicesDiscovered(id, services):
            let link = link(for: id)
            link.linkDelegate?.peripheralLink(link, didDiscoverServices: services.map { CBUUID(string: $0) }, error: nil)
        case let .charsDiscovered(id, service, chars):
            let link = link(for: id)
            link.linkDelegate?.peripheralLink(link,
                                              didDiscoverCharacteristics: chars.map { CBUUID(string: $0) },
                                              forService: CBUUID(string: service), error: nil)
        case let .valueUpdated(id, char, dataHex, errorCode):
            let link = link(for: id)
            link.linkDelegate?.peripheralLink(link,
                                              didUpdateValueFor: CBUUID(string: char),
                                              value: dataHex.flatMap { Data(hexEncoded: $0) },
                                              error: errorCode.map { Self.cbError($0) })
        case let .writeConfirmed(id, char, errorCode):
            let link = link(for: id)
            link.linkDelegate?.peripheralLink(link, didWriteValueFor: CBUUID(string: char),
                                              error: errorCode.map { Self.cbError($0) })
        case let .rssi(id, value):
            let link = link(for: id)
            link.linkDelegate?.peripheralLink(link, didReadRSSI: value, error: nil)
        case let .state(value):
            let newState = CBManagerState(rawValue: value) ?? .unknown
            state = newState
            centralDelegate?.central(self, didUpdateState: newState)
        default:
            break
        }
    }

    private static func cbError(_ code: Int) -> NSError {
        NSError(domain: CBErrorDomain, code: code)
    }
}

/// Debug-only peripheral link that forwards over the bridge socket.
final class BridgeBLEPeripheralLink: BLEPeripheralLink {

    let id: String
    private let channel: BridgeChannel
    weak var linkDelegate: BLEPeripheralLinkDelegate?
    var cachedName: String?
    var bridgeState: CBPeripheralState = .disconnected

    init(id: String, channel: BridgeChannel) {
        self.id = id
        self.channel = channel
    }

    var identifier: UUID { UUID(uuidString: id) ?? UUID() }
    var name: String? { cachedName }
    var state: CBPeripheralState { bridgeState }

    func discoverServices() {
        channel.send(.discoverServices(id: id))
    }

    func discoverCharacteristics(forService serviceUUID: CBUUID) {
        channel.send(.discoverChars(id: id, service: serviceUUID.uuidString))
    }

    func readValue(forCharacteristic characteristicUUID: CBUUID) {
        channel.send(.read(id: id, char: characteristicUUID.uuidString))
    }

    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType) {
        channel.send(.write(id: id, char: characteristicUUID.uuidString,
                            dataHex: data.hexEncodedString, withResponse: type == .withResponse))
    }

    func readRSSI() {
        channel.send(.readRSSI(id: id))
    }
}
#endif

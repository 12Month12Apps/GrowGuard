//
//  BridgeBLECentralTests.swift
//  GrowGuardTests
//
//  Drives BridgeBLECentral / BridgeBLEPeripheralLink with a fake channel and
//  asserts the seam translates requests/events correctly.
//

#if DEBUG
import XCTest
import CoreBluetooth
@testable import GrowGuard

final class FakeBridgeChannel: BridgeChannel {
    var onReceive: ((BridgeMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: (() -> Void)?
    private(set) var sent: [BridgeMessage] = []
    func connect() { onReady?() }
    func send(_ message: BridgeMessage) { sent.append(message) }
    func inject(_ message: BridgeMessage) { onReceive?(message) }
}

final class BridgeBLECentralTests: XCTestCase {

    private static let simID = "FACE0001-0000-0000-0000-00000000FACE"

    final class CentralSpy: NSObject, BLECentralDelegate {
        var discovered: [BLEPeripheralLink] = []
        var connected: [BLEPeripheralLink] = []
        var states: [CBManagerState] = []
        func central(_ central: BLECentral, didUpdateState state: CBManagerState) { states.append(state) }
        func central(_ central: BLECentral, didDiscover peripheral: BLEPeripheralLink, advertisementData: [String: Any], rssi: NSNumber) { discovered.append(peripheral) }
        func central(_ central: BLECentral, didConnect peripheral: BLEPeripheralLink) { connected.append(peripheral) }
        func central(_ central: BLECentral, didDisconnect peripheral: BLEPeripheralLink, error: Error?) {}
        func central(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheralLink, error: Error?) {}
        func central(_ central: BLECentral, willRestoreState peripherals: [BLEPeripheralLink]) {}
    }

    final class LinkSpy: BLEPeripheralLinkDelegate {
        var services: [CBUUID] = []
        var value: Data?
        func peripheralLink(_ link: BLEPeripheralLink, didDiscoverServices serviceUUIDs: [CBUUID], error: Error?) { services = serviceUUIDs }
        func peripheralLink(_ link: BLEPeripheralLink, didDiscoverCharacteristics characteristicUUIDs: [CBUUID], forService serviceUUID: CBUUID, error: Error?) {}
        func peripheralLink(_ link: BLEPeripheralLink, didUpdateValueFor characteristicUUID: CBUUID, value: Data?, error: Error?) { self.value = value }
        func peripheralLink(_ link: BLEPeripheralLink, didWriteValueFor characteristicUUID: CBUUID, error: Error?) {}
        func peripheralLink(_ link: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?) {}
    }

    func testConnectReportsPoweredOn() {
        let channel = FakeBridgeChannel()
        let central = BridgeBLECentral(channel: channel)
        let spy = CentralSpy()
        central.centralDelegate = spy
        // onReady fired during connect() in init, before the delegate was set;
        // re-assert via a state event to cover delegate-after-init.
        channel.inject(.state(value: CBManagerState.poweredOn.rawValue))
        XCTAssertEqual(spy.states.last, .poweredOn)
    }

    func testScanSurfacesDiscoveredDevice() {
        let channel = FakeBridgeChannel()
        let central = BridgeBLECentral(channel: channel)
        let spy = CentralSpy()
        central.centralDelegate = spy

        central.scanForPeripherals(withServices: nil, options: nil)
        XCTAssertEqual(channel.sent.last, .scan)

        channel.inject(.discovered(id: Self.simID, name: "Flower care", services: ["fe95"], rssi: -50))
        XCTAssertEqual(spy.discovered.first?.name, "Flower care")
        XCTAssertEqual(spy.discovered.first?.identifier.uuidString, Self.simID)
    }

    func testConnectForwardsAndReportsConnected() {
        let channel = FakeBridgeChannel()
        let central = BridgeBLECentral(channel: channel)
        let spy = CentralSpy()
        central.centralDelegate = spy

        let link = central.retrievePeripherals(withIdentifiers: [UUID(uuidString: Self.simID)!]).first!
        central.connect(link, options: nil)
        XCTAssertEqual(channel.sent.last, .connect(id: Self.simID))

        channel.inject(.connected(id: Self.simID))
        XCTAssertEqual(spy.connected.first?.identifier.uuidString, Self.simID)
        XCTAssertEqual(link.state, .connected)
    }

    func testReadForwardsAndDeliversValue() {
        let channel = FakeBridgeChannel()
        let central = BridgeBLECentral(channel: channel)
        let link = central.retrievePeripherals(withIdentifiers: [UUID(uuidString: Self.simID)!]).first!
        let spy = LinkSpy()
        link.linkDelegate = spy

        link.readValue(forCharacteristic: firmwareVersionCharacteristicUUID)
        XCTAssertEqual(channel.sent.last, .read(id: Self.simID, char: firmwareVersionCharacteristicUUID.uuidString))

        channel.inject(.valueUpdated(id: Self.simID, char: firmwareVersionCharacteristicUUID.uuidString, dataHex: "502a33", errorCode: nil))
        XCTAssertEqual(spy.value, Data(hexEncoded: "502a33"))
    }

    func testWriteEncodesResponseFlag() {
        let channel = FakeBridgeChannel()
        let central = BridgeBLECentral(channel: channel)
        let link = central.retrievePeripherals(withIdentifiers: [UUID(uuidString: Self.simID)!]).first!

        link.writeValue(Data([0xa0, 0x00, 0x00]), forCharacteristic: historyControlCharacteristicUUID, type: .withResponse)
        XCTAssertEqual(channel.sent.last,
                       .write(id: Self.simID, char: historyControlCharacteristicUUID.uuidString, dataHex: "a00000", withResponse: true))
    }
}
#endif

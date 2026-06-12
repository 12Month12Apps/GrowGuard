//
//  RecordingBLETransport.swift
//  GrowGuard
//
//  Transparente Decorators über dem BLE-Transport-Seam: leiten jeden Call
//  und jeden Delegate-Callback 1:1 weiter und zeichnen ihn dabei im
//  BLESessionRecorder auf. Immer installiert (ConnectionPoolManager.init),
//  faktisch kostenlos solange die Aufzeichnung deaktiviert ist.
//
//  Wichtig: keine Actor-Hops oder Dispatches — die Callback-Reihenfolge
//  muss exakt erhalten bleiben.
//

import Foundation
import CoreBluetooth

// MARK: - Peripheral decorator

final class RecordingPeripheralLink: BLEPeripheralLink, BLEPeripheralLinkDelegate {

    let inner: BLEPeripheralLink
    private let recorder: BLESessionRecorder
    weak var linkDelegate: BLEPeripheralLinkDelegate?

    init(wrapping inner: BLEPeripheralLink, recorder: BLESessionRecorder) {
        self.inner = inner
        self.recorder = recorder
        inner.linkDelegate = self
    }

    var identifier: UUID { inner.identifier }
    var name: String? { inner.name }
    var state: CBPeripheralState { inner.state }

    private func record(_ type: BLESessionEvent.EventType,
                        _ configure: ((inout BLESessionEvent) -> Void)? = nil) {
        guard recorder.isEnabled else { return }
        var event = BLESessionEvent(t: 0, type: type)
        configure?(&event)
        recorder.record(event, device: inner.identifier, deviceName: inner.name)
    }

    // MARK: BLEPeripheralLink (outbound)

    func discoverServices() {
        record(.discoverServices)
        inner.discoverServices()
    }

    func discoverCharacteristics(forService serviceUUID: CBUUID) {
        record(.discoverCharacteristics) { $0.service = serviceUUID.uuidString }
        inner.discoverCharacteristics(forService: serviceUUID)
    }

    func readValue(forCharacteristic characteristicUUID: CBUUID) {
        record(.read) { $0.char = characteristicUUID.uuidString }
        inner.readValue(forCharacteristic: characteristicUUID)
    }

    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType) {
        record(.write) {
            $0.char = characteristicUUID.uuidString
            $0.data = data.hexEncodedString
            $0.withResponse = (type == .withResponse)
        }
        inner.writeValue(data, forCharacteristic: characteristicUUID, type: type)
    }

    func readRSSI() {
        record(.readRSSI)
        inner.readRSSI()
    }

    // MARK: BLEPeripheralLinkDelegate (inbound)

    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverServices serviceUUIDs: [CBUUID], error: Error?) {
        record(.servicesDiscovered) {
            $0.services = serviceUUIDs.map(\.uuidString)
            $0.setError(error)
        }
        linkDelegate?.peripheralLink(self, didDiscoverServices: serviceUUIDs, error: error)
    }

    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverCharacteristics characteristicUUIDs: [CBUUID], forService serviceUUID: CBUUID, error: Error?) {
        record(.characteristicsDiscovered) {
            $0.service = serviceUUID.uuidString
            $0.chars = characteristicUUIDs.map(\.uuidString)
            $0.setError(error)
        }
        linkDelegate?.peripheralLink(self, didDiscoverCharacteristics: characteristicUUIDs, forService: serviceUUID, error: error)
    }

    func peripheralLink(_ link: BLEPeripheralLink, didUpdateValueFor characteristicUUID: CBUUID, value: Data?, error: Error?) {
        record(.valueUpdated) {
            $0.char = characteristicUUID.uuidString
            $0.data = value?.hexEncodedString
            $0.setError(error)
        }
        linkDelegate?.peripheralLink(self, didUpdateValueFor: characteristicUUID, value: value, error: error)
    }

    func peripheralLink(_ link: BLEPeripheralLink, didWriteValueFor characteristicUUID: CBUUID, error: Error?) {
        record(.writeConfirmed) {
            $0.char = characteristicUUID.uuidString
            $0.setError(error)
        }
        linkDelegate?.peripheralLink(self, didWriteValueFor: characteristicUUID, error: error)
    }

    func peripheralLink(_ link: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?) {
        record(.rssiRead) {
            $0.rssi = rssi
            $0.setError(error)
        }
        linkDelegate?.peripheralLink(self, didReadRSSI: rssi, error: error)
    }
}

// MARK: - Central decorator

final class RecordingBLECentral: BLECentral, BLECentralDelegate {

    private let inner: BLECentral
    private let recorder: BLESessionRecorder

    /// Ein stabiler Wrapper pro Peripheral-Identität — DeviceConnection
    /// verlässt sich darauf, über alle Callbacks dieselbe Link-Instanz
    /// zu sehen (gleiche Garantie wie CoreBluetoothCentral)
    private var wrappers: [UUID: RecordingPeripheralLink] = [:]

    weak var centralDelegate: BLECentralDelegate?

    init(wrapping inner: BLECentral, recorder: BLESessionRecorder = .shared) {
        self.inner = inner
        self.recorder = recorder
        inner.centralDelegate = self
    }

    var state: CBManagerState { inner.state }

    private func wrap(_ link: BLEPeripheralLink) -> RecordingPeripheralLink {
        if let existing = wrappers[link.identifier], existing.inner === link {
            return existing
        }
        let wrapper = RecordingPeripheralLink(wrapping: link, recorder: recorder)
        wrappers[link.identifier] = wrapper
        return wrapper
    }

    /// Auspacken vor Calls an das innere Central —
    /// `CoreBluetoothCentral.requireWrapper` castet auf seinen eigenen Typ
    private func unwrap(_ link: BLEPeripheralLink) -> BLEPeripheralLink {
        (link as? RecordingPeripheralLink)?.inner ?? link
    }

    private func record(_ type: BLESessionEvent.EventType,
                        device: BLEPeripheralLink,
                        _ configure: ((inout BLESessionEvent) -> Void)? = nil) {
        guard recorder.isEnabled else { return }
        var event = BLESessionEvent(t: 0, type: type)
        configure?(&event)
        recorder.record(event, device: device.identifier, deviceName: device.name)
    }

    // MARK: BLECentral (outbound)

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        inner.retrievePeripherals(withIdentifiers: identifiers).map { wrap($0) }
    }

    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        record(.connectRequested, device: peripheral)
        inner.connect(unwrap(peripheral), options: options)
    }

    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        record(.cancelConnect, device: peripheral)
        inner.cancelConnection(unwrap(peripheral))
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        inner.scanForPeripherals(withServices: serviceUUIDs, options: options)
    }

    func stopScan() {
        inner.stopScan()
    }

    // MARK: BLECentralDelegate (inbound)

    func central(_ central: BLECentral, didUpdateState state: CBManagerState) {
        if recorder.isEnabled {
            var event = BLESessionEvent(t: 0, type: .bluetoothState)
            event.state = Int(state.rawValue)
            recorder.recordCentralEvent(event)
        }
        centralDelegate?.central(self, didUpdateState: state)
    }

    func central(_ central: BLECentral, didDiscover peripheral: BLEPeripheralLink, advertisementData: [String: Any], rssi: NSNumber) {
        centralDelegate?.central(self, didDiscover: wrap(peripheral), advertisementData: advertisementData, rssi: rssi)
    }

    func central(_ central: BLECentral, didConnect peripheral: BLEPeripheralLink) {
        let wrapped = wrap(peripheral)
        record(.connected, device: wrapped)
        centralDelegate?.central(self, didConnect: wrapped)
    }

    func central(_ central: BLECentral, didDisconnect peripheral: BLEPeripheralLink, error: Error?) {
        let wrapped = wrap(peripheral)
        record(.disconnected, device: wrapped) { $0.setError(error) }
        centralDelegate?.central(self, didDisconnect: wrapped, error: error)
    }

    func central(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheralLink, error: Error?) {
        let wrapped = wrap(peripheral)
        record(.failedToConnect, device: wrapped) { $0.setError(error) }
        centralDelegate?.central(self, didFailToConnect: wrapped, error: error)
    }

    func central(_ central: BLECentral, willRestoreState peripherals: [BLEPeripheralLink]) {
        // State Restoration unverändert durchreichen (inkl. des gepufferten
        // Pfads in CoreBluetoothCentral) — sonst bricht der Background-Relaunch
        centralDelegate?.central(self, willRestoreState: peripherals.map { wrap($0) })
    }
}

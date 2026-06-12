//
//  CoreBluetoothTransport.swift
//  GrowGuard
//
//  Production implementations of the BLE transport seam, backed by
//  CBCentralManager/CBPeripheral. These are thin forwarding wrappers:
//  no behavior beyond translating delegate callbacks into the
//  UUID/Data-based protocol surface.
//

import Foundation
import CoreBluetooth

// MARK: - Peripheral wrapper

final class CoreBluetoothPeripheral: NSObject, BLEPeripheralLink, CBPeripheralDelegate {

    let peripheral: CBPeripheral
    weak var linkDelegate: BLEPeripheralLinkDelegate?

    /// Lookup tables so the protocol surface can work with bare UUIDs
    private var servicesByUUID: [CBUUID: CBService] = [:]
    private var characteristicsByUUID: [CBUUID: CBCharacteristic] = [:]

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var state: CBPeripheralState { peripheral.state }

    func discoverServices() {
        peripheral.discoverServices(nil)
    }

    func discoverCharacteristics(forService serviceUUID: CBUUID) {
        guard let service = servicesByUUID[serviceUUID] else {
            AppLogger.ble.bleWarning("discoverCharacteristics: unknown service \(serviceUUID.uuidString) on \(self.identifier)")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func readValue(forCharacteristic characteristicUUID: CBUUID) {
        guard let characteristic = characteristicsByUUID[characteristicUUID] else {
            AppLogger.ble.bleWarning("readValue: unknown characteristic \(characteristicUUID.uuidString) on \(self.identifier)")
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType) {
        guard let characteristic = characteristicsByUUID[characteristicUUID] else {
            AppLogger.ble.bleWarning("writeValue: unknown characteristic \(characteristicUUID.uuidString) on \(self.identifier)")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    func readRSSI() {
        peripheral.readRSSI()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        for service in services {
            servicesByUUID[service.uuid] = service
        }
        linkDelegate?.peripheralLink(self, didDiscoverServices: services.map { $0.uuid }, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            characteristicsByUUID[characteristic.uuid] = characteristic
        }
        linkDelegate?.peripheralLink(self,
                                     didDiscoverCharacteristics: characteristics.map { $0.uuid },
                                     forService: service.uuid,
                                     error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        linkDelegate?.peripheralLink(self, didUpdateValueFor: characteristic.uuid, value: characteristic.value, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        linkDelegate?.peripheralLink(self, didWriteValueFor: characteristic.uuid, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        linkDelegate?.peripheralLink(self, didReadRSSI: RSSI.intValue, error: error)
    }
}

// MARK: - Central wrapper

final class CoreBluetoothCentral: NSObject, BLECentral, CBCentralManagerDelegate {

    private var centralManager: CBCentralManager!

    /// State restoration can fire during CBCentralManager init, before the
    /// pool assigns itself as delegate — buffer and replay in that case.
    private var pendingRestoredPeripherals: [BLEPeripheralLink] = []

    weak var centralDelegate: BLECentralDelegate? {
        didSet {
            if let delegate = centralDelegate, !pendingRestoredPeripherals.isEmpty {
                let restored = pendingRestoredPeripherals
                pendingRestoredPeripherals.removeAll()
                delegate.central(self, willRestoreState: restored)
            }
        }
    }

    /// One stable wrapper per CBPeripheral so DeviceConnection always sees
    /// the same BLEPeripheralLink identity across callbacks.
    private var wrappers: [UUID: CoreBluetoothPeripheral] = [:]

    init(options: [String: Any]? = nil) {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    var state: CBManagerState { centralManager.state }

    private func wrapper(for peripheral: CBPeripheral) -> CoreBluetoothPeripheral {
        if let existing = wrappers[peripheral.identifier] {
            // Re-assert the delegate in case another component (e.g. the
            // pairing flow's own CBCentralManager in AddDeviceBLE) claimed
            // this CBPeripheral meanwhile
            peripheral.delegate = existing
            return existing
        }
        let wrapper = CoreBluetoothPeripheral(peripheral: peripheral)
        wrappers[peripheral.identifier] = wrapper
        return wrapper
    }

    private func requireWrapper(_ link: BLEPeripheralLink) -> CoreBluetoothPeripheral? {
        guard let wrapper = link as? CoreBluetoothPeripheral else {
            AppLogger.ble.bleError("BLECentral received a foreign peripheral link: \(link.identifier)")
            return nil
        }
        return wrapper
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        centralManager.retrievePeripherals(withIdentifiers: identifiers).map { wrapper(for: $0) }
    }

    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        guard let wrapper = requireWrapper(peripheral) else { return }
        centralManager.connect(wrapper.peripheral, options: options)
    }

    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        guard let wrapper = requireWrapper(peripheral) else { return }
        centralManager.cancelPeripheralConnection(wrapper.peripheral)
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        centralManager.scanForPeripherals(withServices: serviceUUIDs, options: options)
    }

    func stopScan() {
        centralManager.stopScan()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralDelegate?.central(self, didUpdateState: central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        centralDelegate?.central(self, didDiscover: wrapper(for: peripheral), advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        centralDelegate?.central(self, didConnect: wrapper(for: peripheral))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        centralDelegate?.central(self, didDisconnect: wrapper(for: peripheral), error: error)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralDelegate?.central(self, didFailToConnect: wrapper(for: peripheral), error: error)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let links = restored.map { wrapper(for: $0) }
        if let delegate = centralDelegate {
            delegate.central(self, willRestoreState: links)
        } else {
            pendingRestoredPeripherals.append(contentsOf: links)
        }
    }
}

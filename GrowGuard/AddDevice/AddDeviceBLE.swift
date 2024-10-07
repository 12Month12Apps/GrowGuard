//
//  AddDeviceBLE.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import CoreBluetooth

class AddDeviceBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var realTimeSensorValuesCharacteristic: CBCharacteristic?
    var historyControlCharacteristic: CBCharacteristic?
    var historyDataCharacteristic: CBCharacteristic?
    var deviceTimeCharacteristic: CBCharacteristic?
    var entryCountCharacteristic: CBCharacteristic?

    var foundDevice: ((CBPeripheral) -> ())
    
    init(foundDevice: @escaping ((CBPeripheral) -> ())) {
        self.foundDevice = foundDevice

        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
        } else {
            print("Bluetooth is not available.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        foundDevice(peripheral)
    }
}

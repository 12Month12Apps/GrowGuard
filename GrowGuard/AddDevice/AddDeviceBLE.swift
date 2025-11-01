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
    private var shouldScan = false

    var foundDevice: ((CBPeripheral) -> ())
    var stateChanged: ((CBManagerState) -> ())?

    init(foundDevice: @escaping ((CBPeripheral) -> ()), stateChanged: ((CBManagerState) -> ())? = nil) {
        self.foundDevice = foundDevice
        self.stateChanged = stateChanged

        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateChanged?(central.state)

        if central.state == .poweredOn {
            if shouldScan {
                centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            }
        } else {
            centralManager.stopScan()
            print("Bluetooth is not available. State: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        foundDevice(peripheral)
    }

    func startScanning() {
        shouldScan = true
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
        }
    }

    func stopScanning() {
        shouldScan = false
        centralManager.stopScan()
    }
}

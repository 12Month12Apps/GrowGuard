//
//  AddDeviceViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import CoreBluetooth
import SwiftData

@Observable class AddDeviceViewModel {
    var devices: [CBPeripheral] = []
    var addDevice:  CBPeripheral?
    var ble: AddDeviceBLE?
    var allSavedDevices: [FlowerDevice]
    
    init(allSavedDevices: [FlowerDevice]) {
        self.devices = []
        self.allSavedDevices = allSavedDevices
        
        self.ble = AddDeviceBLE { peripheral in
            self.addToList(peripheral: peripheral)
        }
    }
    
    func addToList(peripheral: CBPeripheral) {
        let exists = devices.first { element in
            element.identifier.uuidString == peripheral.identifier.uuidString
        }
        
        if exists == nil {
            devices.append(peripheral)
        }
    }
    
    @MainActor
    func tapOnDevice(peripheral: CBPeripheral) {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == peripheral.identifier.uuidString
        })
        
        if isSaved == false {
            self.addDevice = peripheral
            let newItem = FlowerDevice(added: Date(),
                                       lastUpdate: Date(),
                                       peripheral: peripheral)
            
            DataService.sharedModelContainer.mainContext.insert(newItem)
        }
    }
}

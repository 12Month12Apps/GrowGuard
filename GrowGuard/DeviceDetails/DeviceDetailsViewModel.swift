//
//  DeviceDetailsViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import Foundation
import CoreBluetooth
import Combine

@Observable class DeviceDetailsViewModel {
    let ble = FlowerCareManager.shared
    var device: FlowerDevice
    var subscription: AnyCancellable?
    var subscriptionHistory: AnyCancellable?
    var groupingOption: Calendar.Component = .day
    
    init(device: FlowerDevice) {
        self.device = device
        
        self.subscription = ble.sensorDataPublisher.sink { data in
            self.device.sensorData.append(data)
            self.device.lastUpdate = Date()
            
            Task {
                await self.saveDatabase()
            }
        }
        
        self.subscriptionHistory = ble.historicalDataPublisher.sink { data in
            print(data.brightness)
        }
    }
    
    func loadDetails() {
        ble.connectToKnownDevice(device: device)
    }
    
//    func reloadSensor() {
//        ble.reloadScanning()
//    }
    
    @MainActor
    func saveDatabase() {
        do {
            _ = try DataService.sharedModelContainer.mainContext.save()
        } catch{
            print(error.localizedDescription)
        }
    }
    
    @MainActor
    func delete() {
        DataService.sharedModelContainer.mainContext.delete(device)
        
        saveDatabase()
    }

}

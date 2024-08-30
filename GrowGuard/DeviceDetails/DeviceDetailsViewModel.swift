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
    var sensorData: SensorData?
    var subscription: AnyCancellable?
    var subscriptionHistory: AnyCancellable?
    var groupingOption: Calendar.Component = .day
    
    init(device: FlowerDevice) {
        self.device = device
        
        self.subscription = ble.sensorDataPublisher.sink { data in
            self.sensorData = data
            self.device.sensorData.append(data)
            self.device.lastUpdate = Date()
        }
        
        self.subscriptionHistory = ble.historicalDataPublisher.sink { data in
            print(data.brightness)
        }
    }
    
    func loadDetails() {
        ble.startScanning(device: device)
    }
    
    func reloadSensor() {
        ble.reloadScanning()
    }
    
    @MainActor
    func delete() {
        DataService.sharedModelContainer.mainContext.delete(device)
    }

}

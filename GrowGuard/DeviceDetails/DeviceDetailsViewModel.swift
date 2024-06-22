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
    let ble = FlowerCareManager()
    var device: FlowerDevice
    var sensorData: SensorData?
    var subscription: AnyCancellable?
    
    
    init(device: FlowerDevice) {
        self.device = device
    }
    
    func loadDetails() {
        ble.startScanning(device: device)
        
        self.subscription = ble.sensorDataPublisher.sink { data in
            self.sensorData = data
        }
    }
    
}

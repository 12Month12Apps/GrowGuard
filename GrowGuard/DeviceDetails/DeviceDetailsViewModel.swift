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
        
        PlantMonitorService.shared.checkDeviceStatus(device: device)
        
        self.subscription = ble.sensorDataPublisher.sink { data in
            self.device.sensorData.append(data)
            self.device.lastUpdate = Date()
            
            Task {
                await self.saveDatabase()
            }
        }
        
        self.subscriptionHistory = ble.historicalDataPublisher.sink { data in
//            print(data.brightness)
            
            if !self.device.sensorData.contains(where: {
                $0.date == data.date &&
                $0.temperature == data.temperature &&
                $0.brightness == data.brightness &&
                $0.moisture == data.moisture &&
                $0.conductivity == data.conductivity
            }) {
                guard let sensorData = PlantMonitorService.shared.validateHistoricSensorData(data, device: device) else { return }
                
                self.device.sensorData.append(sensorData)
                Task {
                    await self.saveDatabase()
                }
            }
        }
    }
    
    func loadDetails() {
        ble.connectToKnownDevice(device: device)
        ble.requestLiveData()
    }
    
    func blinkLED() {
        ble.connectToKnownDevice(device: device)
        ble.blinkLED()
    }
    
    @MainActor
    func saveDatabase() {
        do {
            _ = try DataService.sharedModelContainer.mainContext.save()
        } catch{
            print(error.localizedDescription)
        }
    }

    @MainActor
    func fetchHistoricalData() {
        // Connect to the device
        ble.connectToKnownDevice(device: device)
        ble.requestHistoricalData()

        // Subscribe to historical data
//        let cancellable = FlowerCareManager.shared.historicalDataPublisher
//            .sink { [weak self] historicalData in
//                guard let self = self else { return }
//                
//                // Convert historical data to SensorData and add to device
//                let sensorData = SensorData(
//                    temperature: historicalData.temperature,
//                    brightness: historicalData.brightness,
//                    moisture: historicalData.moisture,
//                    conductivity: historicalData.conductivity,
//                    date: historicalData.date,
//                    device: self.device
//                )
//                
//                // Add data to the device (avoiding duplicates)
//                if !self.device.sensorData.contains(where: {
//                    $0.date == sensorData.date &&
//                    $0.temperature == sensorData.temperature &&
//                    $0.brightness == sensorData.brightness &&
//                    $0.moisture == sensorData.moisture &&
//                    $0.conductivity == sensorData.conductivity
//                }) {
//                    self.device.sensorData.append(sensorData)
//                    self.saveDatabase()
//                }
//            }
        
        // Store cancellable reference if needed
        // self.cancellables.insert(cancellable)
        
//        // Start the fetch process
//        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//            FlowerCareManager.shared.fetchEntryCount()
//        }
    }

}

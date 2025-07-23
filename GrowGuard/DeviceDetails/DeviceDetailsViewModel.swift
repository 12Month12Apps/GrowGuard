//
//  DeviceDetailsViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import Foundation
import CoreBluetooth
import Combine
import CoreData

@Observable class DeviceDetailsViewModel {
    let ble = FlowerCareManager.shared
    var device: FlowerDeviceDTO
    var subscription: AnyCancellable?
    var subscriptionHistory: AnyCancellable?
    var groupingOption: Calendar.Component = .day
    private let repositoryManager = RepositoryManager.shared
    
    init(device: FlowerDeviceDTO) {
        self.device = device
        
        Task {
            await try PlantMonitorService.shared.checkDeviceStatus(device: device)
            
            self.subscription = ble.sensorDataPublisher.sink { data in
                Task {
                    await self.saveSensorData(data)
                    await self.updateDeviceLastUpdate()
                }
            }
        }
        
        self.subscriptionHistory = ble.historicalDataPublisher.sink { data in
            Task {
                await self.saveHistoricalSensorData(data)
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
    private func saveSensorData(_ data: SensorDataTemp) async {
        do {
            _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: device.uuid)
        } catch {
            print("Error saving sensor data: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func saveHistoricalSensorData(_ data: HistoricalSensorData) async {
        do {
            // Check for duplicates using repository
            let existingSensorData = try await repositoryManager.sensorDataRepository.getSensorData(for: device.uuid, limit: nil)
            
            let isDuplicate = existingSensorData.contains(where: {
                $0.date == data.date &&
                $0.temperature == data.temperature &&
                Int32($0.brightness) == data.brightness &&
                Int16($0.moisture) == data.moisture &&
                Int16($0.conductivity) == data.conductivity
            })
            
            if !isDuplicate {
                _ = try await PlantMonitorService.shared.validateHistoricSensorData(data, deviceUUID: device.uuid)
            }
        } catch {
            print("Error saving historical sensor data: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func updateDeviceLastUpdate() async {
        do {
            let updatedDevice = FlowerDeviceDTO(
                id: device.id,
                name: device.name,
                uuid: device.uuid,
                peripheralID: device.peripheralID,
                battery: device.battery,
                firmware: device.firmware,
                isSensor: device.isSensor,
                added: device.added,
                lastUpdate: Date(),
                optimalRange: device.optimalRange,
                potSize: device.potSize,
                sensorData: device.sensorData
            )
            try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
            self.device = updatedDevice
        } catch {
            print("Error updating device: \(error.localizedDescription)")
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

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
    
    // MARK: - Smart Sensor Data Loading
    @MainActor private let sensorDataManager = SensorDataManager.shared
    var currentWeekData: [SensorDataDTO] = []
    var isLoadingSensorData = false
    
    @MainActor
    var currentWeekDisplayText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: sensorDataManager.currentWeek)?.start ?? sensorDataManager.currentWeek
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 6, to: startOfWeek) ?? sensorDataManager.currentWeek
        return "\(formatter.string(from: startOfWeek)) - \(formatter.string(from: endOfWeek))"
    }
    
    init(device: FlowerDeviceDTO) {
        self.device = device
        
        Task {
            try await PlantMonitorService.shared.checkDeviceStatus(device: device)
            
            self.subscription = ble.sensorDataPublisher.sink { data in
                Task {
                    if let dto = data.toTemp() {
                        await self.saveSensorData(dto)
                        await self.updateDeviceLastUpdate()
                    }
                }
            }
            
            // Load current week's sensor data immediately
            do {
                let weekData = try await self.sensorDataManager.getCurrentWeekData(for: device.uuid)
                await MainActor.run {
                    self.currentWeekData = weekData
                }
                // Preload adjacent weeks for smooth navigation
                await self.sensorDataManager.preloadAdjacentWeeks(for: device.uuid)
            } catch {
                print("Failed to load current week data: \(error)")
            }
        }
        
        self.subscriptionHistory = ble.historicalDataPublisher.sink { data in
            Task {
                await self.saveHistoricalSensorData(data)
            }
        }
    }
    
    func loadDetails() {
        ble.connectToKnownDevice(deviceUUID: device.uuid)
        ble.requestLiveData()
    }
    
    func blinkLED() {
        ble.connectToKnownDevice(deviceUUID: device.uuid)
        ble.blinkLED()
    }
    
    @MainActor
    private func saveSensorData(_ data: SensorDataTemp) async {
        do {
            if let deviceUUID = data.device {
                _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: deviceUUID)
            }
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

    // MARK: - Week Navigation Methods
    
    @MainActor
    func goToPreviousWeek() async {
        isLoadingSensorData = true
        do {
            let weekData = try await sensorDataManager.goToPreviousWeek(for: device.uuid)
            currentWeekData = weekData
        } catch {
            print("Failed to load previous week data: \(error)")
        }
        isLoadingSensorData = false
    }
    
    @MainActor
    func goToNextWeek() async {
        isLoadingSensorData = true
        do {
            let weekData = try await sensorDataManager.goToNextWeek(for: device.uuid)
            currentWeekData = weekData
        } catch {
            print("Failed to load next week data: \(error)")
        }
        isLoadingSensorData = false
    }
    
    @MainActor
    func refreshCurrentWeek() async {
        isLoadingSensorData = true
        // Clear cache for this device to force fresh data
        sensorDataManager.clearCache(for: device.uuid)
        do {
            let weekData = try await sensorDataManager.getCurrentWeekData(for: device.uuid)
            currentWeekData = weekData
        } catch {
            print("Failed to refresh current week data: \(error)")
        }
        isLoadingSensorData = false
    }

    @MainActor
    func fetchHistoricalData() {
        // Connect to the device
        ble.connectToKnownDevice(deviceUUID: device.uuid)
        ble.requestHistoricalData()
    }

}

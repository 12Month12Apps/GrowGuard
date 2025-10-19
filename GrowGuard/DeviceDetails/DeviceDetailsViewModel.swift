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
    var rssiDistanceSubscription: AnyCancellable?
    var deviceUpdateSubscription: AnyCancellable?
    var groupingOption: Calendar.Component = .day
    private let repositoryManager = RepositoryManager.shared
    
    // MARK: - Connection Quality & Distance
    var connectionDistanceHint: String = ""
    
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
                print("📡 DeviceDetailsViewModel: Received new sensor data from BLE")
                Task {
                    if let dto = data.toTemp() {
                        print("📡 DeviceDetailsViewModel: Converting sensor data to temp format")
                        let success = await self.saveSensorData(dto)
                        if success {
                            await self.updateDeviceLastUpdate()
                        }
                    } else {
                        print("❌ DeviceDetailsViewModel: Failed to convert sensor data to temp format")
                    }
                }
            }
            
            // Subscribe to distance hints for connection quality feedback
            self.rssiDistanceSubscription = ble.rssiDistancePublisher.sink { hint in
                Task { @MainActor in
                    self.connectionDistanceHint = hint
                }
            }
            
            // Subscribe to device updates (battery, firmware, etc.)
            self.deviceUpdateSubscription = ble.deviceUpdatePublisher.sink { updatedDevice in
                Task { @MainActor in
                    // Only update if this is the same device
                    if updatedDevice.uuid == self.device.uuid {
                        print("📱 DeviceDetailsViewModel: Received device update for \(updatedDevice.uuid)")
                        self.device = updatedDevice
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
        
        // Listen for historical data loading completion to refresh cache
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: nil, queue: .main) { [weak self] notification in
            if let deviceUUID = notification.object as? String, deviceUUID == self?.device.uuid {
                Task { @MainActor in
                    await self?.refreshCurrentWeekSilently()
                }
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
    private func saveSensorData(_ data: SensorDataTemp) async -> Bool {
        do {
            if let deviceUUID = data.device {
                print("💾 DeviceDetailsViewModel: Saving sensor data for device \(deviceUUID)")
                _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: deviceUUID)
                
                // Refresh current week data to show the new sensor data
                print("🔄 DeviceDetailsViewModel: Refreshing current week data after saving new sensor data")
                await refreshCurrentWeekSilently()
                return true
            }
            return false
        } catch {
            print("Error saving sensor data: \(error.localizedDescription)")
            return false
        }
    }
    
    @MainActor
    private func refreshCurrentWeekSilently() async {
        // Clear cache for this device to force fresh data
        print("🗑️ DeviceDetailsViewModel: Clearing cache for device \(device.uuid)")
        sensorDataManager.clearCache(for: device.uuid)
        do {
            let weekData = try await sensorDataManager.getCurrentWeekData(for: device.uuid)
            print("📊 DeviceDetailsViewModel: Loaded \(weekData.count) sensor data entries for current week")
            currentWeekData = weekData
        } catch {
            print("Failed to refresh current week data silently: \(error)")
        }
    }
    
    @MainActor
    private func saveHistoricalSensorData(_ data: HistoricalSensorData) async {
        guard data.deviceUUID == device.uuid else {
            print("⚠️ DeviceDetailsViewModel: Ignoring historical data for foreign device \(data.deviceUUID)")
            return
        }
        do {
            // Fast duplicate check: only check recent entries within a small time window
            // This avoids loading thousands of records for each historical entry
            let startDate = data.date.addingTimeInterval(-3600) // 1 hour window
            let endDate = data.date.addingTimeInterval(3600)
            let recentData = try await repositoryManager.sensorDataRepository.getSensorDataInDateRange(for: device.uuid, startDate: startDate, endDate: endDate)
            
            let isDuplicate = recentData.contains(where: {
                abs($0.date.timeIntervalSince(data.date)) < 60 && // Within 1 minute
                $0.temperature == data.temperature &&
                Int32($0.brightness) == data.brightness &&
                Int16($0.moisture) == data.moisture &&
                Int16($0.conductivity) == data.conductivity
            })
            
            if !isDuplicate {
                // Try to validate and save the data - if validation returns nil, the data is invalid and rejected
                if let validatedData = try await PlantMonitorService.shared.validateHistoricSensorData(data, deviceUUID: device.uuid) {
                    print("✅ Saved valid historical entry")
                } else {
                    print("🚨 Rejected invalid historical entry - not saved to database")
                }
                
                // Note: Cache refresh moved to end of historical data loading for massive performance gain
                // No need to clear cache and reload data after every single entry
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
                selectedFlower: device.selectedFlower,
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
    
    // MARK: - Settings Management
    
    /// Saves the updated settings (optimal range and pot size) to the database
    /// - Parameters:
    ///   - optimalRange: The updated optimal range settings, or nil to remove
    ///   - potSize: The updated pot size settings, or nil to remove
    @MainActor
    func saveSettings(optimalRange: OptimalRangeDTO?, potSize: PotSizeDTO?) async throws {
        print("💾 DeviceDetailsViewModel: Saving settings for device \(device.uuid)")
        print("  Current device optimalRange: \(device.optimalRange != nil ? "exists" : "nil")")
        print("  Current device potSize: \(device.potSize != nil ? "exists" : "nil")")
        print("  New optimalRange: \(optimalRange != nil ? "exists" : "nil")")
        print("  New potSize: \(potSize != nil ? "exists" : "nil")")
        
        if let optimalRange = optimalRange {
            print("  New OptimalRange - Min/Max Temp: \(optimalRange.minTemperature)/\(optimalRange.maxTemperature)")
        }
        if let potSize = potSize {
            print("  New PotSize - Width/Height/Volume: \(potSize.width)/\(potSize.height)/\(potSize.volume)")
        }
        
        do {
            // Create updated device with new settings
            let updatedDevice = FlowerDeviceDTO(
                id: device.id,
                name: device.name,
                uuid: device.uuid,
                peripheralID: device.peripheralID,
                battery: device.battery,
                firmware: device.firmware,
                isSensor: device.isSensor,
                added: device.added,
                lastUpdate: Date(), // Update timestamp
                optimalRange: optimalRange,
                potSize: potSize,
                selectedFlower: device.selectedFlower,
                sensorData: device.sensorData
            )
            
            print("🗃️ DeviceDetailsViewModel: Calling repository.updateDevice...")
            // Save to database
            try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
            print("✅ DeviceDetailsViewModel: Repository.updateDevice completed successfully")
            
            // Update local device only after successful database save
            self.device = updatedDevice
            print("📱 DeviceDetailsViewModel: Local device updated")
            
            print("✅ DeviceDetailsViewModel: Settings saved successfully")
            
        } catch {
            print("❌ DeviceDetailsViewModel: Failed to save settings: \(error.localizedDescription)")
            print("❌ Error details: \(error)")
            // Don't update local device if database save fails
            throw error
        }
    }

}

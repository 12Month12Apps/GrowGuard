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
import ActivityKit

@Observable class DeviceDetailsViewModel {
    let ble = FlowerCareManager.shared
    var device: FlowerDeviceDTO
    var subscription: AnyCancellable?
    var subscriptionHistory: AnyCancellable?
    var rssiDistanceSubscription: AnyCancellable?
    var deviceUpdateSubscription: AnyCancellable?
    var groupingOption: Calendar.Component = .day
    private let repositoryManager = RepositoryManager.shared

    // MARK: - Connection Pool Migration (Parallel Implementation)
    // AKTIVIERT: ConnectionPool-Implementierung ist jetzt aktiv!
    // WICHTIG: ConnectionPoolManager.swift und DeviceConnection.swift müssen im Xcode Target sein!
    // Falls Build-Fehler: In Xcode -> File Inspector -> Target Membership -> GrowGuard anhaken
    private let connectionPool = ConnectionPoolManager.shared
    private let settingsStore = SettingsStore.shared
    private var deviceConnection: DeviceConnection?
    private var poolConnectionStateSubscription: AnyCancellable?
    private var poolSensorDataSubscription: AnyCancellable?
    private var poolHistoricalDataSubscription: AnyCancellable?
    private var poolHistoryProgressSubscription: AnyCancellable?
    private var connectionModeObserver: NSObjectProtocol?

    // Feature Flag: true = neue ConnectionPool Implementierung, false = alte FlowerCareManager
    var useConnectionPool: Bool

    // MARK: - Historical Data Loading
    var isLoadingHistory = false
    var historyLoadingProgress: (current: Int, total: Int) = (0, 0)
    private var historicalDataBatchCounter = 0
    private var historyLoadedThisSession = false // Prevents auto-restart after completion

    // MARK: - Live Activity for Background History Loading
    private let liveActivityService = HistoryLoadingActivityService.shared
    var isLiveActivityEnabled = true // User can toggle this
    
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
        self.useConnectionPool = settingsStore.useConnectionPool

        Task { @MainActor in
            // Check immediately if history loading is already in progress for this device
            if self.liveActivityService.hasActivity(for: device.uuid) {
                self.isLoadingHistory = true
                AppLogger.ble.info("📊 DeviceDetailsViewModel: History loading already in progress for device \(device.uuid)")
            }
        }

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

        connectionModeObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let rawValue = notification.userInfo?[SettingsStore.changeUserInfoKey] as? String,
                let key = SettingsStore.ChangeKey(rawValue: rawValue)
            else { return }

            if key == .connectionMode {
                self?.handleConnectionModeChange(self?.settingsStore.connectionMode ?? .connectionPool)
            }
        }

        // Listen for historical data loading completion to refresh cache
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: nil, queue: .main) { [weak self] notification in
            if let deviceUUID = notification.object as? String, deviceUUID == self?.device.uuid {
                Task { @MainActor in
                    // Reset batch counter
                    self?.historicalDataBatchCounter = 0
                    // Final refresh after all data loaded
                    await self?.refreshCurrentWeekSilently()
                }
            }
        }
    }

    deinit {
        if let observer = connectionModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Connection Pool Methods (New Implementation)
    // ✅ AKTIVIERT: ConnectionPool-Implementierung ist jetzt verfügbar!

    private func handleConnectionModeChange(_ mode: ConnectionMode) {
        let shouldUsePool = (mode == .connectionPool)

        Task { @MainActor in
            guard shouldUsePool != self.useConnectionPool else { return }
            self.useConnectionPool = shouldUsePool

            if shouldUsePool {
                self.connectionPool.resetRetryCounter(for: self.device.uuid)
            } else {
                self.disconnectViaPool()
            }
        }
    }

    /// Verbindet zum Gerät über den ConnectionPoolManager (neue Implementierung)
    @MainActor private func connectViaPool() {
        AppLogger.ble.bleConnection("DeviceDetailsViewModel: Connecting via ConnectionPool to device \(device.uuid)")

        // Hole oder erstelle DeviceConnection vom Pool
        deviceConnection = connectionPool.getConnection(for: device.uuid)

        guard let connection = deviceConnection else {
            AppLogger.ble.bleError("DeviceDetailsViewModel: Failed to get connection from pool")
            return
        }

        // Only enable auto-start if history hasn't been loaded this session
        // This prevents the loop where history restarts after completion on reconnect
        if !historyLoadedThisSession {
            connection.setAutoStartHistoryFlowEnabled(true)
            AppLogger.ble.info("📊 DeviceDetailsViewModel: Auto-start enabled (history not loaded yet)")
        } else {
            connection.setAutoStartHistoryFlowEnabled(false)
            AppLogger.ble.info("📊 DeviceDetailsViewModel: Auto-start disabled (history already loaded this session)")
        }

        // Sync current history progress if loading is already in progress
        if connection.isHistoryLoading {
            let progress = connection.currentHistoryProgress
            self.isLoadingHistory = true
            self.historyLoadingProgress = progress
            AppLogger.ble.info("📊 DeviceDetailsViewModel: Synced history progress \(progress.current)/\(progress.total)")
        }

        // Subscribe zu Sensor-Daten vom ConnectionPool
        poolSensorDataSubscription = connection.sensorDataPublisher.sink { [weak self] (data: SensorDataTemp) in
            print("📡 DeviceDetailsViewModel (Pool): Received new sensor data from ConnectionPool")
            Task { @MainActor in
                guard let self = self else { return }
                // Verarbeite Sensor-Daten
                let success = await self.saveSensorData(data)
                if success {
                    await self.updateDeviceLastUpdate()
                }
            }
        }

        // Subscribe zu Historical Data vom ConnectionPool
        poolHistoricalDataSubscription = connection.historicalDataPublisher.sink { [weak self] (data: HistoricalSensorData) in
            print("📡 DeviceDetailsViewModel (Pool): Received historical sensor data from ConnectionPool")
            print("📅 Historical data date: \(data.date), temp: \(data.temperature)°C, moisture: \(data.moisture)%")
            Task { @MainActor in
                guard let self = self else { return }
                await self.saveHistoricalSensorData(data)

                // Check if History Flow is completed by listening to the connection
                // Note: We'll set isLoadingHistory to false when connection disconnects or in completion handler
            }
        }

        // Subscribe zu History Progress vom ConnectionPool
        poolHistoryProgressSubscription = connection.historyProgressPublisher.sink { [weak self] (current: Int, total: Int) in
            Task { @MainActor in
                guard let self = self else { return }
                print("📊 DeviceDetailsViewModel (Pool): History progress: \(current)/\(total)")

                // Detect auto-start: if we receive progress but weren't loading, history auto-started
                if total > 0 && !self.isLoadingHistory {
                    AppLogger.ble.info("📊 DeviceDetailsViewModel: History loading auto-started, making it visible to user")
                    self.isLoadingHistory = true

                    // Start Live Activity for background progress tracking
                    if self.isLiveActivityEnabled && !self.liveActivityService.hasActivity(for: self.device.uuid) {
                        let activityStarted = self.liveActivityService.startActivity(
                            deviceName: self.device.name,
                            deviceUUID: self.device.uuid,
                            totalEntries: total
                        )
                        if activityStarted {
                            AppLogger.ble.info("📊 DeviceDetailsViewModel: Live Activity started for auto-started history loading")
                        }
                    }
                }

                self.historyLoadingProgress = (current, total)

                // Update Live Activity with progress
                if self.isLiveActivityEnabled && self.liveActivityService.hasActivity(for: self.device.uuid) {
                    self.liveActivityService.updateProgress(
                        currentEntry: current,
                        totalEntries: total,
                        connectionStatus: .loading
                    )
                }
            }
        }

        // Listen for historical data loading completion
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: device.uuid, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoadingHistory = false
                // Mark history as loaded to prevent auto-restart on reconnect
                self.historyLoadedThisSession = true
                // Reset batch counter
                self.historicalDataBatchCounter = 0
                // Disable auto-start now that history loading is complete
                self.deviceConnection?.setAutoStartHistoryFlowEnabled(false)
                // End Live Activity with completed status
                if self.liveActivityService.hasActivity(for: self.device.uuid) {
                    self.liveActivityService.endActivity(status: .completed)
                }
                AppLogger.ble.info("📊 DeviceDetailsViewModel: History loading completed, auto-restart disabled")
                // Final refresh after all data loaded
                await self.refreshCurrentWeekSilently()
            }
        }

        // Subscribe zu Connection State vom ConnectionPool
        poolConnectionStateSubscription = connection.connectionStatePublisher.sink { [weak self] (state: DeviceConnection.ConnectionState) in
            Task { @MainActor in
                guard let self = self else { return }
                AppLogger.ble.bleConnection("DeviceDetailsViewModel (Pool): Connection state changed to \(state)")

                // Update Live Activity connection status
                if self.isLoadingHistory && self.liveActivityService.hasActivity(for: self.device.uuid) {
                    switch state {
                    case .connecting:
                        self.liveActivityService.updateConnectionStatus(.connecting)
                    case .connected:
                        self.liveActivityService.updateConnectionStatus(.connected)
                    case .authenticated:
                        self.liveActivityService.updateConnectionStatus(.loading)
                    case .disconnected:
                        // If still loading, show reconnecting status
                        self.liveActivityService.updateConnectionStatus(.reconnecting, isPaused: true)
                    case .error:
                        self.liveActivityService.updateConnectionStatus(.reconnecting, isPaused: true)
                    }
                }

                // Bei erfolgreicher Authentication: Fordere Live-Daten an
                if state == .authenticated {
                    AppLogger.ble.bleConnection("DeviceDetailsViewModel (Pool): Device authenticated, requesting live data")
                    connection.requestLiveData()
                }
            }
        }

        // Starte Verbindung über ConnectionPool
        connectionPool.connect(to: device.uuid)
    }

    /// Stoppt die Verbindung über den ConnectionPool
    @MainActor private func disconnectViaPool() {
        AppLogger.ble.bleConnection("DeviceDetailsViewModel: Disconnecting via ConnectionPool from device \(device.uuid)")

        // Cancel Subscriptions
        poolSensorDataSubscription?.cancel()
        poolHistoricalDataSubscription?.cancel()
        poolHistoryProgressSubscription?.cancel()
        poolConnectionStateSubscription?.cancel()

        // End Live Activity if still running
        if liveActivityService.hasActivity(for: device.uuid) {
            liveActivityService.endActivity(status: HistoryLoadingAttributes.ConnectionStatus.failed)
        }

        // Disconnecte vom Pool
        connectionPool.disconnect(from: device.uuid)

        // Cleanup
        deviceConnection = nil
        isLoadingHistory = false
    }

    @MainActor func loadDetails() {
        // ✅ AKTIVIERT: Nutzt jetzt ConnectionPool (wenn useConnectionPool = true)
        // Fallback auf alte FlowerCareManager Implementierung (wenn useConnectionPool = false)

        if useConnectionPool {
            // Neue Implementierung: Nutze ConnectionPoolManager
            AppLogger.ble.bleConnection("DeviceDetailsViewModel: Using ConnectionPool implementation")

            // Reset retry counter for fresh start
            connectionPool.resetRetryCounter(for: device.uuid)

            connectViaPool()
        } else {
            // Alte Implementierung: Nutze FlowerCareManager (Fallback)
            AppLogger.ble.bleConnection("DeviceDetailsViewModel: Using legacy FlowerCareManager implementation")
            ble.connectToKnownDevice(deviceUUID: device.uuid)
            ble.requestLiveData()
        }
    }
    
    func blinkLED() {
        // Note: blinkLED() nutzt vorerst immer FlowerCareManager
        // TODO: DeviceConnection.blinkLED() implementieren für ConnectionPool
        ble.connectToKnownDevice(deviceUUID: device.uuid)
        ble.blinkLED()
    }
    
    @MainActor
    private func saveSensorData(_ data: SensorDataTemp) async -> Bool {
        do {
            if let deviceUUID = data.device {
                print("💾 DeviceDetailsViewModel: Saving sensor data for device \(deviceUUID)")
                _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: deviceUUID, source: .liveUserTriggered)

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
            if let first = weekData.first, let last = weekData.last {
                print("📅 Current week data range: \(first.date) to \(last.date)")
            }
            currentWeekData = weekData
            print("✅ DeviceDetailsViewModel: currentWeekData updated with \(currentWeekData.count) entries")
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
                    print("✅ Saved valid historical entry dated \(data.date)")

                    // Increment batch counter
                    historicalDataBatchCounter += 1

                    // Batch UI updates: Refresh UI every 50 entries for visual feedback without killing performance
                    if historicalDataBatchCounter % 50 == 0 {
                        print("🔄 DeviceDetailsViewModel: Batch update #\(historicalDataBatchCounter/50) after \(historicalDataBatchCounter) entries - refreshing UI NOW")
                        await refreshCurrentWeekSilently()
                    }
                } else {
                    print("🚨 Rejected invalid historical entry dated \(data.date) - not saved to database")
                }
            } else {
                print("⏭️ Skipped duplicate historical entry dated \(data.date)")
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
        AppLogger.ble.info("📊 DeviceDetailsViewModel: Starting historical data fetch for device \(self.device.uuid)")

        // Reset batch counter for new history flow
        historicalDataBatchCounter = 0

        // Start Live Activity for background progress tracking
        if isLiveActivityEnabled {
            let activityStarted = liveActivityService.startActivity(
                deviceName: device.name,
                deviceUUID: device.uuid,
                totalEntries: 0 // Will be updated once we know the total
            )
            if activityStarted {
                AppLogger.ble.info("📊 DeviceDetailsViewModel: Live Activity started for history loading")
            } else {
                AppLogger.ble.warning("📊 DeviceDetailsViewModel: Could not start Live Activity (may be disabled)")
            }
        }

        if useConnectionPool {
            // ✅ Neue Implementierung: Nutze ConnectionPool
            AppLogger.ble.bleConnection("DeviceDetailsViewModel: Using ConnectionPool for historical data")

            guard let connection = deviceConnection else {
                AppLogger.ble.bleError("DeviceDetailsViewModel: No connection available, connecting first...")
                // Verbinde zuerst, dann starte History Flow
                connectViaPool()

                // Warte kurz und starte dann History Flow
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, let connection = self.deviceConnection else { return }
                    // Enable auto-start for reconnection during history loading
                    connection.setAutoStartHistoryFlowEnabled(true)
                    self.isLoadingHistory = true
                    connection.startHistoryDataFlow()
                }
                return
            }

            // Connection existiert bereits - starte History Flow direkt
            // Enable auto-start for reconnection during history loading
            connection.setAutoStartHistoryFlowEnabled(true)
            isLoadingHistory = true
            connection.startHistoryDataFlow()

        } else {
            // Alte Implementierung: Nutze FlowerCareManager (Fallback)
            AppLogger.ble.bleConnection("DeviceDetailsViewModel: Using legacy FlowerCareManager for historical data")
            ble.connectToKnownDevice(deviceUUID: device.uuid)
            ble.requestHistoricalData()
        }
    }

    /// Cancel the ongoing history loading and end Live Activity
    @MainActor
    func cancelHistoryLoading() {
        AppLogger.ble.info("📊 DeviceDetailsViewModel: Cancelling history loading for device \(self.device.uuid)")

        isLoadingHistory = false
        historicalDataBatchCounter = 0

        // End the Live Activity
        if liveActivityService.hasActivity(for: self.device.uuid) {
            liveActivityService.endActivity(status: HistoryLoadingAttributes.ConnectionStatus.failed)
        }

        // Stop the history flow based on connection mode
        if useConnectionPool, let connection = deviceConnection {
            // Disable auto-start to prevent unwanted resumption
            connection.setAutoStartHistoryFlowEnabled(false)
            connection.cleanupHistoryFlow()
        } else {
            // Legacy FlowerCareManager mode
            FlowerCareManager.shared.cancelHistoryDataLoading()
        }
    }
    
    // MARK: - Settings Management
    
    /// Saves the updated settings (optimal range and pot size) to the database
    /// - Parameters:
    ///   - optimalRange: The updated optimal range settings, or nil to remove
    ///   - potSize: The updated pot size settings, or nil to remove
    @MainActor
    func saveSettings(deviceName: String, optimalRange: OptimalRangeDTO?, potSize: PotSizeDTO?) async throws {
        print("💾 DeviceDetailsViewModel: Saving settings for device \(device.uuid)")
        print("  Current device name: '\(device.name)'")
        print("  New device name: '\(deviceName)'")
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
                name: deviceName, // Use the updated name
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
            print("📱 DeviceDetailsViewModel: Local device updated with name '\(self.device.name)'")

            print("✅ DeviceDetailsViewModel: Settings saved successfully")

        } catch {
            print("❌ DeviceDetailsViewModel: Failed to save settings: \(error.localizedDescription)")
            print("❌ Error details: \(error)")
            // Don't update local device if database save fails
            throw error
        }
    }

}

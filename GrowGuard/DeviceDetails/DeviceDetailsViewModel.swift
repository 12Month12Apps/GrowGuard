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
    var device: FlowerDeviceDTO
    var groupingOption: Calendar.Component = .day
    private let repositoryManager = RepositoryManager.shared

    // MARK: - BLE (ConnectionPool)
    private let connectionPool = ConnectionPoolManager.shared
    private var deviceConnection: DeviceConnection?
    private var poolConnectionStateSubscription: AnyCancellable?
    private var poolSensorDataSubscription: AnyCancellable?
    private var poolHistoricalDataSubscription: AnyCancellable?
    private var poolHistoryProgressSubscription: AnyCancellable?
    private var poolDeviceInfoSubscription: AnyCancellable?
    private var poolRSSISubscription: AnyCancellable?
    private var blinkOnAuthenticationSubscription: AnyCancellable?

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
    var isNextWeekInFuture: Bool {
        let calendar = Calendar.current
        let currentViewedWeekStart = calendar.dateInterval(of: .weekOfYear, for: sensorDataManager.currentWeek)?.start ?? sensorDataManager.currentWeek
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return currentViewedWeekStart >= thisWeekStart
    }

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

        Task { @MainActor in
            // Check immediately if history loading is already in progress for this device
            if self.liveActivityService.hasActivity(for: device.uuid) {
                self.isLoadingHistory = true
                AppLogger.ble.info("📊 DeviceDetailsViewModel: History loading already in progress for device \(device.uuid)")
            }
        }

        Task {
            try await PlantMonitorService.shared.checkDeviceStatus(device: device)

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

    // MARK: - Connection Pool Methods

    /// Verbindet zum Gerät über den ConnectionPoolManager
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

        // Subscribe zu Geräte-Infos (Batterie/Firmware) vom ConnectionPool
        poolDeviceInfoSubscription = connection.deviceInfoPublisher.sink { [weak self] info in
            Task { @MainActor in
                await self?.updateDeviceInfo(battery: info.battery, firmware: info.firmware)
            }
        }

        // Subscribe zu RSSI für den Entfernungs-Hinweis in der UI
        poolRSSISubscription = connection.rssiPublisher.sink { [weak self] rssi in
            Task { @MainActor in
                self?.connectionDistanceHint = Self.distanceHint(forRSSI: rssi)
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

                // Detect auto-start: if we receive progress but weren't loading, history auto-started.
                // Only trigger when current < total — receiving the final (N, N) update after
                // completion should not restart the loading state.
                if total > 0 && current < total && !self.isLoadingHistory {
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

                // Direct completion signal: all entries received. This catches the race where the
                // HistoricalDataLoadingCompleted notification handler hasn't run yet but progress
                // already shows 100%.
                if total > 0 && current >= total && self.isLoadingHistory {
                    AppLogger.ble.info("📊 DeviceDetailsViewModel: Progress reached 100%, marking loading as complete")
                    self.isLoadingHistory = false
                    if self.liveActivityService.hasActivity(for: self.device.uuid) {
                        self.liveActivityService.endActivity(status: .completed)
                    }
                    return
                }

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
        // NOTE: object: nil is intentional — NotificationCenter uses object identity not equality,
        // so filtering by device.uuid (a Swift String) would never match the posted String instance.
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: nil, queue: .main) { [weak self] notification in
            guard let deviceUUID = notification.object as? String, deviceUUID == self?.device.uuid else { return }
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
                    case .disconnected, .error:
                        // cleanupHistoryFlow() resets isHistoryLoading synchronously before posting
                        // the completion notification. If the connection is no longer loading AND
                        // progress reached 100%, the flow finished normally — complete rather than pause.
                        // Requiring progress.total > 0 && current >= total prevents false completion
                        // during the initial connecting phase where the flow hasn't started yet.
                        let progress = self.historyLoadingProgress
                        let finishedBeforeDisconnect = self.deviceConnection?.isHistoryLoading == false
                            && progress.total > 0
                            && progress.current >= progress.total
                        if finishedBeforeDisconnect {
                            self.isLoadingHistory = false
                            self.liveActivityService.endActivity(status: .completed)
                        } else {
                            self.liveActivityService.updateConnectionStatus(.reconnecting, isPaused: true)
                        }
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
        poolDeviceInfoSubscription?.cancel()
        poolRSSISubscription?.cancel()

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
        // Reset retry counter for fresh start
        connectionPool.resetRetryCounter(for: device.uuid)
        connectViaPool()
    }

    @MainActor
    func blinkLED() {
        if let connection = deviceConnection, connection.connectionState == .authenticated {
            connection.blinkLED()
        } else {
            // Nicht verbunden (Sensor trennt nach Inaktivität selbst):
            // erst verbinden, dann einmalig nach Authentifizierung blinken
            connectionPool.resetRetryCounter(for: device.uuid)
            connectViaPool()
            blinkOnAuthenticationSubscription = deviceConnection?.connectionStatePublisher
                .filter { $0 == .authenticated }
                .prefix(1)
                .sink { [weak self] _ in
                    self?.deviceConnection?.blinkLED()
                    self?.blinkOnAuthenticationSubscription = nil
                }
        }
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
    
    /// Aktualisiert Batterie/Firmware in der Datenbank.
    /// `lastUpdate` bleibt unverändert — Batterie-Reads sind keine Messung.
    @MainActor
    private func updateDeviceInfo(battery: Int, firmware: String) async {
        do {
            let updatedDevice = FlowerDeviceDTO(
                id: device.id,
                name: device.name,
                uuid: device.uuid,
                peripheralID: device.peripheralID,
                battery: Int16(battery),
                firmware: firmware,
                isSensor: device.isSensor,
                added: device.added,
                lastUpdate: device.lastUpdate,
                optimalRange: device.optimalRange,
                potSize: device.potSize,
                selectedFlower: device.selectedFlower,
                sensorData: device.sensorData
            )
            try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
            self.device = updatedDevice
            AppLogger.ble.info("🔋 Updated battery to \(battery)% / firmware \(firmware) for device \(self.device.uuid)")
        } catch {
            print("Error updating device battery: \(error.localizedDescription)")
        }
    }

    /// RSSI → Entfernungs-Hinweis für die UI
    private static func distanceHint(forRSSI rssi: Int) -> String {
        if rssi >= -65 {
            return "Close (Good signal)"
        } else if rssi >= -80 {
            return "Medium (Fair signal)"
        } else {
            return "Far (Poor signal)"
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

        // Eine Connection ist nur nutzbar, wenn sie authenticated ist.
        // FlowerCare-Sensoren trennen die Verbindung selbst nach wenigen
        // Sekunden Inaktivität — ein vorhandenes, aber totes Connection-
        // Objekt muss daher wie "nicht verbunden" behandelt werden
        // (startHistoryDataFlow auf einer toten Connection ist ein No-Op).
        guard let connection = deviceConnection, connection.connectionState == .authenticated else {
            AppLogger.ble.bleConnection("DeviceDetailsViewModel: No usable connection (state: \(String(describing: deviceConnection?.connectionState))), reconnecting first...")
            isLoadingHistory = true
            connectionPool.resetRetryCounter(for: device.uuid)
            connectViaPool()
            // Explizite Nutzer-Aktion erzwingt Auto-Start, unabhängig von
            // historyLoadedThisSession (connectViaPool setzt das Flag sonst
            // konservativ) — der Flow startet nach der Authentifizierung
            deviceConnection?.setAutoStartHistoryFlowEnabled(true)
            return
        }

        // Connection existiert bereits - starte History Flow direkt
        // Enable auto-start for reconnection during history loading
        connection.setAutoStartHistoryFlowEnabled(true)
        isLoadingHistory = true
        connection.startHistoryDataFlow()
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

        // Stop the history flow
        if let connection = deviceConnection {
            // Disable auto-start to prevent unwanted resumption
            connection.setAutoStartHistoryFlowEnabled(false)
            connection.cleanupHistoryFlow()
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

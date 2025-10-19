//
//  Settings.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import SwiftUI
import Foundation
import UserNotifications

@Observable
class SettingsViewModel {
    var potSize: PotSizeDTO
    var optimalRange: OptimalRangeDTO
    var selectedFlower: VMSpecies? {
        didSet {
            if !isLoadingData {
                updateOptimalRangeFromFlower()
            }
        }
    }
    var isLoading: Bool = false
    var isCleaningDatabase: Bool = false
    var cleanupStats: (totalEntries: Int, invalidEntries: Int)? = nil
    var cleanupResult: String? = nil
    
    // Sensor data deletion
    var isDeletingSensorData: Bool = false
    var sensorDataCount: Int = 0
    var sensorDataDeleteResult: String? = nil
    
    // Debug: Test Notifications
    var testNotificationDate: Date = Date().addingTimeInterval(30) // Default: 30 seconds from now
    var testNotificationResult: String? = nil
    var isSchedulingTestNotification: Bool = false
    var notificationAuthorizationStatus: String = "Checking..."
    var pendingNotificationsCount: Int = 0
    var detailedNotificationInfo: String = ""
    var isRunningOnSimulator: Bool = false
    private var isLoadingData: Bool = false
    private let deviceUUID: String
    private let repositoryManager = RepositoryManager.shared
    
    init(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        // Initialize with default values, will be loaded in loadSettings()
        self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
        self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
        self.selectedFlower = nil
    }
    
    @MainActor
    func loadSettings() async {
        isLoading = true
        isLoadingData = true
        print("🔧 SettingsViewModel: Loading settings for device \(deviceUUID)")
        
        await withTaskGroup(of: Void.self) { group in
            // Load potSize and optimalRange concurrently
            group.addTask { [weak self] in
                await self?.loadPotSize()
            }
            
            group.addTask { [weak self] in
                await self?.loadOptimalRange()
            }
            
            group.addTask { [weak self] in
                await self?.loadSelectedFlower()
            }
        }
        
        isLoadingData = false
        isLoading = false
        print("✅ SettingsViewModel: Settings loaded successfully")
    }
    
    @MainActor
    private func loadPotSize() async {
        do {
            if let loadedPotSize = try await repositoryManager.potSizeRepository.getPotSize(for: deviceUUID) {
                print("  Loaded PotSize - Width/Height/Volume: \(loadedPotSize.width)/\(loadedPotSize.height)/\(loadedPotSize.volume)")
                self.potSize = loadedPotSize
            } else {
                print("  No PotSize found, using defaults")
                self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load potSize: \(error)")
            self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
        }
    }
    
    @MainActor
    private func loadOptimalRange() async {
        do {
            if let loadedOptimalRange = try await repositoryManager.optimalRangeRepository.getOptimalRange(for: deviceUUID) {
                print("  Loaded OptimalRange - Min/Max Temp: \(loadedOptimalRange.minTemperature)/\(loadedOptimalRange.maxTemperature)")
                self.optimalRange = loadedOptimalRange
            } else {
                print("  No OptimalRange found, using defaults")
                self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load optimalRange: \(error)")
            self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
        }
    }
    
    @MainActor
    private func loadSelectedFlower() async {
        print("🔍 SettingsViewModel.loadSelectedFlower: Starting for device \(deviceUUID)")
        do {
            if let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) {
                print("🔍 Device found, selectedFlower: \(device.selectedFlower?.name ?? "nil")")
                self.selectedFlower = device.selectedFlower
                if let flower = device.selectedFlower {
                    print("✅  Loaded SelectedFlower: \(flower.name) (ID: \(flower.id))")
                } else {
                    print("ℹ️  No flower selected for this device")
                }
            } else {
                print("❌  Device not found, no flower information available")
                self.selectedFlower = nil
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load selectedFlower: \(error)")
            self.selectedFlower = nil
        }
    }
    
    func getUpdatedPotSize() -> PotSizeDTO {
        return potSize
    }
    
    func getUpdatedOptimalRange() -> OptimalRangeDTO {
        return optimalRange
    }
    
    func getSelectedFlower() -> VMSpecies? {
        return selectedFlower
    }
    
    @MainActor
    func saveSettings() async throws {
        print("💾 SettingsViewModel: Saving settings for device \(deviceUUID)")
        
        // Get current device first
        guard let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) else {
            print("❌ SettingsViewModel.saveSettings: Device not found")
            throw RepositoryError.deviceNotFound
        }
        
        // Save potSize and optimalRange separately first (these have their own entities)
        try await repositoryManager.potSizeRepository.savePotSize(potSize)
        print("  Saved PotSize - Width/Height/Volume: \(potSize.width)/\(potSize.height)/\(potSize.volume)")
        
        try await repositoryManager.optimalRangeRepository.saveOptimalRange(optimalRange)
        print("  Saved OptimalRange - Min/Max Temp: \(optimalRange.minTemperature)/\(optimalRange.maxTemperature)")
        
        // Now update the device with the selectedFlower in a single operation
        let updatedDevice = FlowerDeviceDTO(
            id: device.id,
            name: device.name,
            uuid: device.uuid,
            peripheralID: device.peripheralID,
            battery: device.battery,
            firmware: device.firmware,
            isSensor: device.isSensor,
            added: device.added,
            lastUpdate: device.lastUpdate,
            optimalRange: device.optimalRange, // Keep existing relationships
            potSize: device.potSize, // Keep existing relationships
            selectedFlower: selectedFlower, // Only update the flower
            sensorData: device.sensorData
        )
        
        print("🔧 Saving device with flower: \(selectedFlower?.name ?? "nil") (ID: \(selectedFlower?.id ?? 0))")
        try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
        
        if let flower = selectedFlower {
            print("✅  Saved SelectedFlower: \(flower.name) (ID: \(flower.id))")
        } else {
            print("✅  Removed flower selection")
        }
        
        print("✅ SettingsViewModel: Settings saved successfully")
    }
    
    
    private func updateOptimalRangeFromFlower() {
        guard let flower = selectedFlower else { return }
        
        // Update moisture values if the selected flower has them
        if let minMoisture = flower.minMoisture {
            optimalRange = OptimalRangeDTO(
                id: optimalRange.id,
                minTemperature: optimalRange.minTemperature,
                maxTemperature: optimalRange.maxTemperature,
                minBrightness: optimalRange.minBrightness,
                maxBrightness: optimalRange.maxBrightness,
                minMoisture: Int16(minMoisture),
                maxMoisture: flower.maxMoisture != nil ? Int16(flower.maxMoisture!) : optimalRange.maxMoisture,
                minConductivity: optimalRange.minConductivity,
                maxConductivity: optimalRange.maxConductivity,
                deviceUUID: optimalRange.deviceUUID
            )
            print("🌱 SettingsViewModel: Updated moisture range from flower - Min: \(minMoisture), Max: \(flower.maxMoisture ?? Int(optimalRange.maxMoisture))")
        }
    }
    
    @MainActor
    func loadDatabaseStats() async {
        do {
            let stats = try await PlantMonitorService.shared.getInvalidDataStatistics()
            self.cleanupStats = stats
        } catch {
            print("❌ Failed to load database stats: \(error)")
        }
    }
    
    @MainActor
    func loadSensorDataCount() async {
        do {
            let sensorData = try await repositoryManager.sensorDataRepository.getSensorData(for: deviceUUID, limit: nil)
            self.sensorDataCount = sensorData.count
            print("📊 SettingsViewModel: Loaded sensor data count: \(sensorDataCount)")
        } catch {
            print("❌ Failed to load sensor data count: \(error)")
            self.sensorDataCount = 0
        }
    }
    
    @MainActor
    func deleteAllSensorData() async {
        isDeletingSensorData = true
        sensorDataDeleteResult = nil
        
        do {
            // Get count before deletion for success message
            let countBeforeDelete = sensorDataCount
            
            try await repositoryManager.sensorDataRepository.deleteAllSensorData(for: deviceUUID)
            sensorDataDeleteResult = L10n.SensorData.deleteSuccess(countBeforeDelete)
            
            // Update count after deletion
            await loadSensorDataCount()
            
            print("✅ SettingsViewModel: Successfully deleted all sensor data for device \(deviceUUID)")
        } catch {
            sensorDataDeleteResult = L10n.SensorData.deleteError + ": \(error.localizedDescription)"
            print("❌ SettingsViewModel: Failed to delete sensor data: \(error)")
        }
        
        isDeletingSensorData = false
    }
    
    @MainActor
    func cleanupDatabase() async {
        isCleaningDatabase = true
        cleanupResult = nil
        
        do {
            let deletedCount = try await PlantMonitorService.shared.cleanupInvalidSensorData()
            cleanupResult = "✅ Cleaned up \(deletedCount) invalid entries"
            
            // Reload stats after cleanup
            await loadDatabaseStats()
        } catch {
            cleanupResult = "❌ Cleanup failed: \(error.localizedDescription)"
        }
        
        isCleaningDatabase = false
    }
    
    @MainActor
    func scheduleTestNotification() async {
        print("🧪 SettingsViewModel: Starting scheduleTestNotification...")
        isSchedulingTestNotification = true
        testNotificationResult = nil
        
        do {
            // Get the device info for the notification
            guard let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                testNotificationResult = "❌ Device not found"
                isSchedulingTestNotification = false
                return
            }
            
            // Cancel any existing test notifications
            await cancelTestNotifications()
            
            // Create test notification content
            let content = UNMutableNotificationContent()
            content.title = "🧪 TEST: \(device.name)"
            content.body = "This is a test notification scheduled from debug menu."
            content.sound = .default
            content.categoryIdentifier = "WATERING_REMINDER"
            content.userInfo = [
                "deviceUUID": device.uuid,
                "notificationType": "test"
            ]
            
            // Create trigger based on selected time
            let timeFromNow = testNotificationDate.timeIntervalSinceNow
            
            if timeFromNow <= 0 {
                testNotificationResult = "❌ Selected time is in the past"
                isSchedulingTestNotification = false
                return
            }
            
            let trigger: UNNotificationTrigger
            if timeFromNow < 60 {
                // For times less than 1 minute, use time interval trigger
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timeFromNow), repeats: false)
            } else {
                // For longer times, use calendar trigger for precision
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: testNotificationDate)
                trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            }
            
            let identifier = "test-notification-\(deviceUUID)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            try await UNUserNotificationCenter.current().add(request)
            print("✅ SettingsViewModel: Successfully added notification request with identifier: \(identifier)")
            
            // Immediately check if it was actually scheduled
            let pendingAfter = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let wasScheduled = pendingAfter.contains { $0.identifier == identifier }
            print("🔍 SettingsViewModel: Notification in pending list: \(wasScheduled)")
            
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            
            if timeFromNow < 60 {
                testNotificationResult = "✅ Test notification scheduled in \(Int(timeFromNow)) seconds"
            } else {
                testNotificationResult = "✅ Test notification scheduled for \(formatter.string(from: testNotificationDate))"
            }
            
            // Refresh status to show updated pending count
            await checkNotificationStatus()
            
            print("🧪 SettingsViewModel: Scheduled test notification for \(device.name) at \(testNotificationDate)")
            print("🧪 SettingsViewModel: Trigger details: \(trigger)")
            
        } catch {
            testNotificationResult = "❌ Failed to schedule: \(error.localizedDescription)"
            print("❌ SettingsViewModel: Failed to schedule test notification: \(error)")
        }
        
        isSchedulingTestNotification = false
    }
    
    func cancelTestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        
        let testIdentifiers = pendingRequests
            .filter { $0.identifier.contains("test-notification") }
            .map { $0.identifier }
        
        center.removeDeliveredNotifications(withIdentifiers: testIdentifiers)
        center.removePendingNotificationRequests(withIdentifiers: testIdentifiers)
        
        if !testIdentifiers.isEmpty {
            print("🧪 SettingsViewModel: Cancelled \(testIdentifiers.count) test notifications")
        }
    }
    
    @MainActor
    func checkNotificationStatus() async {
        let center = UNUserNotificationCenter.current()
        
        // Check authorization status
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            notificationAuthorizationStatus = "❓ Not Asked Yet"
        case .denied:
            notificationAuthorizationStatus = "❌ Denied - Check Settings"
        case .authorized:
            notificationAuthorizationStatus = "✅ Authorized"
        case .provisional:
            notificationAuthorizationStatus = "⚡ Provisional"
        case .ephemeral:
            notificationAuthorizationStatus = "🕐 Ephemeral"
        @unknown default:
            notificationAuthorizationStatus = "❓ Unknown Status"
        }
        
        // Add additional status info
        if settings.authorizationStatus == .authorized {
            var statusDetails: [String] = []
            if settings.alertSetting == .disabled {
                statusDetails.append("No Alerts")
            }
            if settings.soundSetting == .disabled {
                statusDetails.append("No Sound")
            }
            if settings.badgeSetting == .disabled {
                statusDetails.append("No Badge")
            }
            if !statusDetails.isEmpty {
                notificationAuthorizationStatus += " (\(statusDetails.joined(separator: ", ")))"
            }
        }
        
        // Count pending notifications
        let pendingRequests = await center.pendingNotificationRequests()
        pendingNotificationsCount = pendingRequests.count
        
        // Detailed device and system info
        var deviceInfo: [String] = []
        
        #if targetEnvironment(simulator)
        isRunningOnSimulator = true
        deviceInfo.append("📱 iOS Simulator (notifications may not show)")
        #else
        isRunningOnSimulator = false
        deviceInfo.append("📱 Physical Device")
        #endif
        
        deviceInfo.append("iOS \(UIDevice.current.systemVersion)")
        
        // Detailed notification settings
        var settingsInfo: [String] = []
        settingsInfo.append("Alert: \(settings.alertSetting == .enabled ? "✅" : "❌")")
        settingsInfo.append("Sound: \(settings.soundSetting == .enabled ? "🔊" : "🔇")")
        settingsInfo.append("Badge: \(settings.badgeSetting == .enabled ? "🔴" : "⚪")")
        settingsInfo.append("Lock Screen: \(settings.lockScreenSetting == .enabled ? "🔒" : "❌")")
        settingsInfo.append("Notification Center: \(settings.notificationCenterSetting == .enabled ? "📋" : "❌")")
        settingsInfo.append("Banner: \(settings.alertSetting == .enabled ? "🏷️" : "❌")")
        
        detailedNotificationInfo = "\(deviceInfo.joined(separator: ", "))\n\(settingsInfo.joined(separator: ", "))"
        
        // Log all pending notifications for debugging
        print("🧪 SettingsViewModel: Current notification status:")
        print("  Authorization: \(notificationAuthorizationStatus)")
        print("  Pending notifications: \(pendingNotificationsCount)")
        print("  Device: \(deviceInfo.joined(separator: ", "))")
        print("  Settings: \(settingsInfo.joined(separator: ", "))")
        
        for request in pendingRequests {
            print("  - \(request.identifier): \(request.content.title)")
            if let trigger = request.trigger {
                if let timeInterval = trigger as? UNTimeIntervalNotificationTrigger {
                    print("    Fires in: \(timeInterval.timeInterval) seconds")
                } else if let calendar = trigger as? UNCalendarNotificationTrigger {
                    print("    Fires at: \(calendar.dateComponents)")
                }
            } else {
                print("    ⚡ IMMEDIATE (no trigger - should fire now)")
            }
        }
    }
    
    @MainActor
    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                testNotificationResult = "✅ Notification permission granted!"
                print("🧪 SettingsViewModel: Notification permission granted")
            } else {
                testNotificationResult = "❌ Notification permission denied"
                print("🧪 SettingsViewModel: Notification permission denied")
            }
            await checkNotificationStatus()
        } catch {
            testNotificationResult = "❌ Permission request failed: \(error.localizedDescription)"
            print("🧪 SettingsViewModel: Permission request failed: \(error)")
        }
    }
    
    @MainActor
    func sendImmediateTestNotification() async {
        print("🚨 SettingsViewModel: Sending IMMEDIATE test notification...")
        
        do {
            guard let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                testNotificationResult = "❌ Device not found"
                return
            }
            
            // Create immediate notification (no trigger = immediate)
            let content = UNMutableNotificationContent()
            content.title = "🚨 IMMEDIATE TEST"
            content.body = "This should appear RIGHT NOW if notifications work!"
            content.sound = .default
            content.badge = 1
            content.categoryIdentifier = "WATERING_REMINDER"
            content.userInfo = [
                "deviceUUID": device.uuid,
                "notificationType": "immediate-test"
            ]
            
            let identifier = "immediate-test-\(deviceUUID)-\(Date().timeIntervalSince1970)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            
            print("🚨 SettingsViewModel: Adding immediate notification request...")
            try await UNUserNotificationCenter.current().add(request)
            print("✅ SettingsViewModel: Immediate notification request added successfully")
            
            testNotificationResult = "🚨 Immediate notification sent! Should appear NOW"
            
            // Check if it's actually in the system
            let allPending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let immediateFound = allPending.contains { $0.identifier == identifier }
            print("🔍 SettingsViewModel: Immediate notification in pending list: \(immediateFound)")
            
            if !immediateFound {
                print("⚠️ SettingsViewModel: Immediate notification NOT found in pending - it should have fired immediately")
            }
            
            await checkNotificationStatus()
            
        } catch {
            testNotificationResult = "❌ Immediate test failed: \(error.localizedDescription)"
            print("❌ SettingsViewModel: Immediate notification failed: \(error)")
        }
    }
}

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var isSaving = false
    @State private var saveError: Error?
    @State private var showSaveError = false
    @State private var showFlowerSelection = false
    let isSensor: Bool
    let onSave: (OptimalRangeDTO, PotSizeDTO) -> Void
    @Environment(\.dismiss) private var dismiss
    
    init(deviceUUID: String, isSensor: Bool = true, onSave: @escaping (OptimalRangeDTO, PotSizeDTO) -> Void) {
        self.isSensor = isSensor
        self.onSave = onSave
        self._viewModel = State(initialValue: SettingsViewModel(deviceUUID: deviceUUID))
    }
    
    var calculatedVolume: Double? {
        guard viewModel.potSize.width > 0, viewModel.potSize.height > 0 else { return nil }
        let radius = viewModel.potSize.width
        return Double.pi * pow(radius, 2) * viewModel.potSize.height
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                List {
                Section(header: Text("Plant Selection")) {
                    if let selectedFlower = viewModel.selectedFlower {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.15))
                                    .frame(width: 50, height: 50)

                                Image(systemName: "leaf.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedFlower.name)
                                    .font(.headline)

                                if let minMoisture = selectedFlower.minMoisture,
                                   let maxMoisture = selectedFlower.maxMoisture {
                                    Text("Moisture: \(minMoisture)% - \(maxMoisture)%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                showFlowerSelection = true
                            } label: {
                                Text("Change")
                                    .font(.subheadline)
                            }
                        }
                        .padding(.vertical, 4)

                        Button {
                            viewModel.selectedFlower = nil
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Remove Plant")
                            }
                            .foregroundColor(.red)
                        }
                    } else {
                        Button {
                            showFlowerSelection = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Select Plant")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text("Pot Size")) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "arrow.left.and.right")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            Text("Radius (cm)")
                            Spacer()
                            TextField("0", value: $viewModel.potSize.width, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }

                        HStack {
                            Image(systemName: "arrow.up.and.down")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            Text("Height (cm)")
                            Spacer()
                            TextField("0", value: $viewModel.potSize.height, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "cube")
                                    .foregroundColor(.blue)
                                    .frame(width: 30)
                                Text("Volume (cm³)")
                                Spacer()
                                TextField("0", value: $viewModel.potSize.volume, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }

                            if let calculated = calculatedVolume {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Calculated: \(String(format: "%.1f", calculated)) cm³")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Button {
                                        viewModel.potSize.volume = calculated
                                    } label: {
                                        HStack {
                                            Image(systemName: "checkmark.circle")
                                            Text("Use calculated volume")
                                        }
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    }
                                }
                                .padding(.leading, 30)
                            }
                        }
                    }
                }
                
                Section(header: Text("Optimal Ranges")) {
                    if let selectedFlower = viewModel.selectedFlower,
                       selectedFlower.minMoisture != nil || selectedFlower.maxMoisture != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Values from \(selectedFlower.name)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 4)
                    }

                    VStack(spacing: 16) {
                        // Moisture
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Moisture", systemImage: "drop.fill")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)

                            HStack {
                                Text("Min")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: $viewModel.optimalRange.minMoisture, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("%")
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("Max")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: $viewModel.optimalRange.maxMoisture, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("%")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if isSensor {
                            Divider()

                            // Temperature
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Temperature", systemImage: "thermometer")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)

                                HStack {
                                    Text("Min")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.minTemperature, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("°C")
                                        .foregroundColor(.secondary)

                                    Spacer()

                                    Text("Max")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.maxTemperature, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("°C")
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            // Brightness
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Brightness", systemImage: "sun.max.fill")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.yellow)

                                HStack {
                                    Text("Min")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.minBrightness, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("lux")
                                        .foregroundColor(.secondary)

                                    Spacer()

                                    Text("Max")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.maxBrightness, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("lux")
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            // Conductivity
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Conductivity", systemImage: "bolt.fill")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)

                                HStack {
                                    Text("Min")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.minConductivity, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("µS/cm")
                                        .foregroundColor(.secondary)
                                        .font(.caption)

                                    Spacer()

                                    Text("Max")
                                        .frame(width: 50, alignment: .leading)
                                    TextField("0", value: $viewModel.optimalRange.maxConductivity, format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 60)
                                    Text("µS/cm")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                }
                .disabled(viewModel.isLoading || isSaving)

                if viewModel.isLoading || isSaving {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(viewModel.isLoading ? "Loading..." : "Saving...")
                            .padding(.top)
                    }
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .cornerRadius(10)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(viewModel.isLoading || isSaving)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveSettings()
                        }
                    }
                    .disabled(viewModel.isLoading || isSaving)
                }
            }
            .navigationTitle("Settings")
            .task {
                await viewModel.loadSettings()
            }
            .alert("Save Error", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text(saveError?.localizedDescription ?? "Unknown error occurred")
            }
            .sheet(isPresented: $showFlowerSelection) {
                FlowerSelectionView(selectedFlower: $viewModel.selectedFlower)
            }
        }
    }
    
    @MainActor
    private func saveSettings() async {
        isSaving = true
        
        do {
            try await viewModel.saveSettings()
            
            let updatedOptimalRange = viewModel.getUpdatedOptimalRange()
            let updatedPotSize = viewModel.getUpdatedPotSize()
            
            onSave(updatedOptimalRange, updatedPotSize)
            dismiss()
        } catch {
            saveError = error
            showSaveError = true
        }
        
        isSaving = false
    }
}

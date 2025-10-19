//
//  LogExportView.swift
//  GrowGuard
//
//  Created for beta testing support
//

import SwiftUI
import UserNotifications

@Observable
class DebugMenuViewModel {
    // Database cleanup
    var isCleaningDatabase = false
    var cleanupStats: (totalEntries: Int, invalidEntries: Int)? = nil
    var cleanupResult: String? = nil

    // Sensor data deletion
    var isDeletingSensorData = false
    var sensorDataCount = 0
    var sensorDataDeleteResult: String? = nil
    var selectedDeviceUUID: String? = nil

    // Notifications
    var testNotificationDate = Date().addingTimeInterval(30)
    var testNotificationResult: String? = nil
    var isSchedulingTestNotification = false
    var notificationAuthorizationStatus = "Checking..."
    var pendingNotificationsCount = 0
    var detailedNotificationInfo = ""
    var isRunningOnSimulator = false

    private let repositoryManager = RepositoryManager.shared

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
    func cleanupDatabase() async {
        isCleaningDatabase = true
        cleanupResult = nil

        do {
            let deletedCount = try await PlantMonitorService.shared.cleanupInvalidSensorData()
            cleanupResult = "✅ Cleaned up \(deletedCount) invalid entries"
            await loadDatabaseStats()
        } catch {
            cleanupResult = "❌ Cleanup failed: \(error.localizedDescription)"
        }

        isCleaningDatabase = false
    }

    @MainActor
    func loadSensorDataCount(for deviceUUID: String) async {
        do {
            let sensorData = try await repositoryManager.sensorDataRepository.getSensorData(for: deviceUUID, limit: nil)
            self.sensorDataCount = sensorData.count
            print("📊 Loaded sensor data count: \(sensorDataCount)")
        } catch {
            print("❌ Failed to load sensor data count: \(error)")
            self.sensorDataCount = 0
        }
    }

    @MainActor
    func deleteAllSensorData(for deviceUUID: String) async {
        isDeletingSensorData = true
        sensorDataDeleteResult = nil

        do {
            let countBeforeDelete = sensorDataCount
            try await repositoryManager.sensorDataRepository.deleteAllSensorData(for: deviceUUID)
            sensorDataDeleteResult = "✅ Deleted \(countBeforeDelete) sensor data entries"
            await loadSensorDataCount(for: deviceUUID)
        } catch {
            sensorDataDeleteResult = "❌ Delete failed: \(error.localizedDescription)"
        }

        isDeletingSensorData = false
    }

    @MainActor
    func checkNotificationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            notificationAuthorizationStatus = "❓ Not Asked Yet"
        case .denied:
            notificationAuthorizationStatus = "❌ Denied"
        case .authorized:
            notificationAuthorizationStatus = "✅ Authorized"
        case .provisional:
            notificationAuthorizationStatus = "⚡ Provisional"
        case .ephemeral:
            notificationAuthorizationStatus = "🕐 Ephemeral"
        @unknown default:
            notificationAuthorizationStatus = "❓ Unknown"
        }

        let pendingRequests = await center.pendingNotificationRequests()
        pendingNotificationsCount = pendingRequests.count

        #if targetEnvironment(simulator)
        isRunningOnSimulator = true
        #else
        isRunningOnSimulator = false
        #endif
    }

    @MainActor
    func scheduleTestNotification() async {
        isSchedulingTestNotification = true
        testNotificationResult = nil

        do {
            let content = UNMutableNotificationContent()
            content.title = "🧪 Test Notification"
            content.body = "This is a test notification"
            content.sound = .default

            let timeFromNow = testNotificationDate.timeIntervalSinceNow
            guard timeFromNow > 0 else {
                testNotificationResult = "❌ Time is in the past"
                isSchedulingTestNotification = false
                return
            }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timeFromNow), repeats: false)
            let request = UNNotificationRequest(identifier: "test-\(UUID())", content: content, trigger: trigger)

            try await UNUserNotificationCenter.current().add(request)
            testNotificationResult = "✅ Scheduled in \(Int(timeFromNow))s"
            await checkNotificationStatus()
        } catch {
            testNotificationResult = "❌ Failed: \(error.localizedDescription)"
        }

        isSchedulingTestNotification = false
    }

    @MainActor
    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            testNotificationResult = granted ? "✅ Permission granted" : "❌ Permission denied"
            await checkNotificationStatus()
        } catch {
            testNotificationResult = "❌ Request failed: \(error.localizedDescription)"
        }
    }
}

struct LogExportView: View {
    @State private var isExporting = false
    @State private var exportedLogURL: URL?
    @State private var showShareSheet = false
    @State private var logHours = 24
    @State private var showSuccessAlert = false
    @State private var errorMessage: String?
    @State private var viewModel = DebugMenuViewModel()
    @State private var allDevices: [FlowerDeviceDTO] = []
    @State private var showDeleteConfirmation = false

    let logHourOptions = [6, 12, 24, 48, 72]
    
    var body: some View {
        Form {
            Section(header: Text("Debug Log Export")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export app logs for debugging and support")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Log Duration:")
                        Spacer()
                        Picker("Hours", selection: $logHours) {
                            ForEach(logHourOptions, id: \.self) { hours in
                                Text("\(hours)h").tag(hours)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Button(action: exportLogs) {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text(isExporting ? "Exporting..." : "Export Logs")
                        }
                    }
                    .disabled(isExporting)
                    .buttonStyle(.borderedProminent)
                    
                    if let url = exportedLogURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log file exported:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.blue)
                                .onTapGesture {
                                    showShareSheet = true
                                }
                        }
                    }
                }
            }
            
            Section(header: Text("Database Maintenance")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let stats = viewModel.cleanupStats {
                        HStack {
                            Text("Total entries:")
                                .font(.caption)
                            Text("\(stats.totalEntries)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Invalid entries:")
                                .font(.caption)
                            Text("\(stats.invalidEntries)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(stats.invalidEntries > 0 ? .red : .green)
                        }
                    }

                    if let result = viewModel.cleanupResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("✅") ? .green : .red)
                    }

                    Button {
                        Task {
                            await viewModel.cleanupDatabase()
                        }
                    } label: {
                        HStack {
                            if viewModel.isCleaningDatabase {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text(viewModel.isCleaningDatabase ? "Cleaning..." : "Clean Invalid Data")
                        }
                    }
                    .disabled(viewModel.isCleaningDatabase)
                    .foregroundColor(.red)
                }
            }

            Section(header: Text("Sensor Data Management")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Select Device", selection: $viewModel.selectedDeviceUUID) {
                        Text("Select a device").tag(nil as String?)
                        ForEach(allDevices, id: \.uuid) { device in
                            Text(device.name).tag(device.uuid as String?)
                        }
                    }

                    if let deviceUUID = viewModel.selectedDeviceUUID {
                        HStack {
                            Text("Sensor data entries:")
                                .font(.caption)
                            Text("\(viewModel.sensorDataCount)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(viewModel.sensorDataCount > 0 ? .blue : .secondary)
                        }

                        if let result = viewModel.sensorDataDeleteResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result.contains("✅") ? .green : .red)
                        }

                        Button {
                            if viewModel.sensorDataCount > 0 {
                                showDeleteConfirmation = true
                            }
                        } label: {
                            HStack {
                                if viewModel.isDeletingSensorData {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "trash.fill")
                                }
                                Text(viewModel.isDeletingSensorData ? "Deleting..." : "Delete All Data")
                            }
                        }
                        .disabled(viewModel.isDeletingSensorData || viewModel.sensorDataCount == 0)
                        .foregroundColor(viewModel.sensorDataCount > 0 ? .red : .secondary)
                        .buttonStyle(.plain)
                    }
                }
            }

            Section(header: Text("Notification Testing")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status:")
                            .font(.caption)
                        Text(viewModel.notificationAuthorizationStatus)
                            .font(.caption)
                            .foregroundColor(viewModel.notificationAuthorizationStatus.contains("✅") ? .green : .red)
                    }

                    HStack {
                        Text("Pending:")
                            .font(.caption)
                        Text("\(viewModel.pendingNotificationsCount)")
                            .font(.caption)

                        Spacer()

                        Button("Refresh") {
                            Task {
                                await viewModel.checkNotificationStatus()
                            }
                        }
                        .font(.caption2)
                    }

                    if viewModel.notificationAuthorizationStatus.contains("❌") || viewModel.notificationAuthorizationStatus.contains("❓") {
                        Button("Request Permission") {
                            Task {
                                await viewModel.requestNotificationPermission()
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    }

                    if viewModel.isRunningOnSimulator {
                        Text("⚠️ Running on Simulator - notifications may not work")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    DatePicker("Test Time", selection: $viewModel.testNotificationDate, in: Date()...)
                        .datePickerStyle(.compact)

                    if let result = viewModel.testNotificationResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("✅") ? .green : .red)
                    }

                    Button {
                        Task {
                            await viewModel.scheduleTestNotification()
                        }
                    } label: {
                        HStack {
                            if viewModel.isSchedulingTestNotification {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "bell.badge")
                            }
                            Text(viewModel.isSchedulingTestNotification ? "Scheduling..." : "Schedule Test")
                        }
                    }
                    .disabled(viewModel.isSchedulingTestNotification)
                }
            }

            Section(header: Text("Quick Actions")) {
                Button("Test BLE Connection") {
                    AppLogger.ble.info("🧪 Manual BLE connection test initiated by user")
                }

                Button("Log Device Info") {
                    logDeviceInformation()
                }

                Button("Clear Exported Logs") {
                    clearExportedLogs()
                }
                .foregroundColor(.red)
            }

            Section(footer: Text("Logs contain BLE communication, sensor data, and error information. No personal data is included.")) {
                EmptyView()
            }
        }
        .navigationTitle("Debug Tools")
        .task {
            async let devices = loadDevices()
            async let stats = viewModel.loadDatabaseStats()
            async let notifStatus = viewModel.checkNotificationStatus()
            _ = await (devices, stats, notifStatus)
        }
        .onChange(of: viewModel.selectedDeviceUUID) { _, newValue in
            if let uuid = newValue {
                Task {
                    await viewModel.loadSensorDataCount(for: uuid)
                }
            }
        }
        .alert("Export Successful", isPresented: $showSuccessAlert) {
            Button("Share") { showShareSheet = true }
            Button("OK") { }
        } message: {
            Text("Debug logs have been exported and are ready to share.")
        }
        .alert("Export Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Delete Sensor Data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let uuid = viewModel.selectedDeviceUUID {
                    Task {
                        await viewModel.deleteAllSensorData(for: uuid)
                    }
                }
            }
        } message: {
            Text("This will permanently delete all sensor data for this device. This action cannot be undone.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedLogURL {
                ShareSheet(items: [url])
            }
        }
    }

    @MainActor
    private func loadDevices() async {
        do {
            allDevices = try await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
        } catch {
            print("❌ Failed to load devices: \(error)")
        }
    }
    
    private func exportLogs() {
        isExporting = true
        errorMessage = nil
        
        Task {
            do {
                let logURL = await AppLogger.exportLogsForSharing(lastHours: logHours)
                
                await MainActor.run {
                    if let url = logURL {
                        exportedLogURL = url
                        showSuccessAlert = true
                        AppLogger.general.info("✅ Log export completed: \(url.lastPathComponent)")
                    } else {
                        errorMessage = "Failed to export logs. Please try again."
                        AppLogger.general.error("❌ Log export failed")
                    }
                    isExporting = false
                }
            }
        }
    }
    
    private func logDeviceInformation() {
        let device = UIDevice.current
        AppLogger.general.info("📱 Device Info - Model: \(device.model), iOS: \(device.systemVersion), Name: \(device.name)")
        AppLogger.general.info("📱 App Info - Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"), Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")")
    }
    
    private func clearExportedLogs() {
        if let url = exportedLogURL {
            try? FileManager.default.removeItem(at: url)
            exportedLogURL = nil
            AppLogger.general.info("🗑️ Exported log files cleared by user")
        }
    }
}

// Share Sheet for iOS
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationView {
        LogExportView()
    }
}

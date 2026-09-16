import SwiftUI
import UIKit

@Observable
final class AppSettingsViewModel {
    private let settingsStore: SettingsStore
    private let calendar: Calendar
    private let notificationService: NotificationService
    private var settingsObserver: NSObjectProtocol?

    var preferredReminderTime: Date

    // Push Token Debug Info
    var currentDeviceToken: String?
    var isReregisteringToken: Bool = false

    // Background Task Debug Info - Execution
    var refreshTaskCount: Int = 0
    var processingTaskCount: Int = 0
    var lastRefreshDate: Date?
    var lastProcessingDate: Date?
    var executionHistory: [TaskExecution] = []

    // Background Task Debug Info - Scheduling
    var refreshScheduleCount: Int = 0
    var processingScheduleCount: Int = 0
    var scheduleFailureCount: Int = 0
    var lastRefreshScheduledDate: Date?
    var lastProcessingScheduledDate: Date?
    var schedulingHistory: [SchedulingEvent] = []

    // Background Task Debug Info - Silent Push (phase 2)
    var pushReceivedCount: Int = 0
    var lastPushReceivedDate: Date?

    // Background Task Debug Info - BLE wake reads
    var wakeReadSuccessCount: Int = 0
    var wakeReadFailureCount: Int = 0
    var lastWakeReadDate: Date?

    init(
        settingsStore: SettingsStore = .shared,
        calendar: Calendar = .current,
        notificationService: NotificationService = .shared
    ) {
        self.settingsStore = settingsStore
        self.calendar = calendar
        self.notificationService = notificationService
        self.preferredReminderTime = settingsStore.reminderDate(for: calendar)
        self.currentDeviceToken = settingsStore.deviceToken

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let keyRaw = notification.userInfo?[SettingsStore.changeUserInfoKey] as? String,
                let key = SettingsStore.ChangeKey(rawValue: keyRaw),
                let self = self
            else { return }

            switch key {
            case .reminderTime:
                self.preferredReminderTime = self.settingsStore.reminderDate(for: self.calendar)
            case .serverURL:
                // Server URL changes are handled elsewhere
                break
            }
        }

        loadBackgroundTaskStats()
    }

    func loadBackgroundTaskStats() {
        let tracker = BackgroundTaskTracker.shared

        // Execution stats
        refreshTaskCount = tracker.refreshTaskCount
        processingTaskCount = tracker.processingTaskCount
        lastRefreshDate = tracker.lastRefreshDate
        lastProcessingDate = tracker.lastProcessingDate
        executionHistory = tracker.executionHistory

        // Scheduling stats
        refreshScheduleCount = tracker.refreshScheduleCount
        processingScheduleCount = tracker.processingScheduleCount
        scheduleFailureCount = tracker.scheduleFailureCount
        lastRefreshScheduledDate = tracker.lastRefreshScheduledDate
        lastProcessingScheduledDate = tracker.lastProcessingScheduledDate
        schedulingHistory = tracker.schedulingHistory

        // Silent push stats
        pushReceivedCount = tracker.pushReceivedCount
        lastPushReceivedDate = tracker.lastPushReceivedDate

        // BLE wake read stats
        wakeReadSuccessCount = tracker.wakeReadSuccessCount
        wakeReadFailureCount = tracker.wakeReadFailureCount
        lastWakeReadDate = tracker.lastWakeReadDate
    }

    func resetBackgroundTaskStats() {
        BackgroundTaskTracker.shared.resetAll()
        loadBackgroundTaskStats()
    }

    func updateReminderTime(_ newValue: Date) {
        settingsStore.updateReminderTime(with: newValue, calendar: calendar)

        Task {
            await notificationService.reschedulePersistentWateringReminders()
        }
    }

    @MainActor
    func reregisterPushToken() {
        isReregisteringToken = true

        // Clear the current token
        settingsStore.deviceToken = nil
        currentDeviceToken = nil

        // Re-register for remote notifications - this will trigger didRegisterForRemoteNotificationsWithDeviceToken
        UIApplication.shared.registerForRemoteNotifications()

        // Update state after a short delay (token registration is async)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            currentDeviceToken = settingsStore.deviceToken
            isReregisteringToken = false
        }
    }

    func refreshDeviceToken() {
        currentDeviceToken = settingsStore.deviceToken
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AppSettingsView: View {
    @State private var viewModel = AppSettingsViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section(header: Text(L10n.Settings.notificationSection)) {
                DatePicker(
                    L10n.Settings.dailyReminderTime,
                    selection: $viewModel.preferredReminderTime,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: viewModel.preferredReminderTime) { newValue in
                    viewModel.updateReminderTime(newValue)
                }

                Text(L10n.Settings.dailyReminderDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // Debug: Push Notification Token
            Section(header: Text("Push Token (Debug)")) {
                if let token = viewModel.currentDeviceToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Token:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(token)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No token registered")
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.reregisterPushToken()
                } label: {
                    if viewModel.isReregisteringToken {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Registering...")
                        }
                    } else {
                        Label("Re-register Push Token", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(viewModel.isReregisteringToken)

                Button {
                    viewModel.refreshDeviceToken()
                } label: {
                    Label("Refresh Token Display", systemImage: "arrow.clockwise")
                }
            }

            // Debug: Background Task Scheduling
            Section(header: Text("Task Scheduling (Debug)")) {
                // Scheduling stats
                HStack {
                    Label("Refresh Scheduled", systemImage: "calendar.badge.clock")
                    Spacer()
                    Text("\(viewModel.refreshScheduleCount)x")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Processing Scheduled", systemImage: "calendar.badge.plus")
                    Spacer()
                    Text("\(viewModel.processingScheduleCount)x")
                        .foregroundStyle(.secondary)
                }

                if viewModel.scheduleFailureCount > 0 {
                    HStack {
                        Label("Schedule Failures", systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Text("\(viewModel.scheduleFailureCount)")
                            .foregroundStyle(.red)
                    }
                }

                // Last scheduled times
                if let lastScheduled = viewModel.lastRefreshScheduledDate {
                    HStack {
                        Label("Last Refresh Scheduled", systemImage: "clock")
                        Spacer()
                        Text(lastScheduled, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastScheduled = viewModel.lastProcessingScheduledDate {
                    HStack {
                        Label("Last Processing Scheduled", systemImage: "clock.fill")
                        Spacer()
                        Text(lastScheduled, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                // Scheduling history
                if !viewModel.schedulingHistory.isEmpty {
                    DisclosureGroup("Scheduling History (\(viewModel.schedulingHistory.count))") {
                        ForEach(viewModel.schedulingHistory.prefix(10)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(event.type.rawValue)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(event.type == .refresh ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                                        .cornerRadius(4)

                                    Image(systemName: event.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(event.success ? .green : .red)
                                        .font(.caption)

                                    Spacer()

                                    Text(event.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text(event.source.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if let error = event.error {
                                        Text("- \(error)")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            // Debug: Background Task Execution
            Section(header: Text("Task Execution (Debug)")) {
                // Summary stats
                HStack {
                    Label("Refresh Executed", systemImage: "arrow.clockwise")
                    Spacer()
                    Text("\(viewModel.refreshTaskCount)x")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Processing Executed", systemImage: "bolt.fill")
                    Spacer()
                    Text("\(viewModel.processingTaskCount)x")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Silent Pushes Received", systemImage: "envelope.badge")
                    Spacer()
                    Text("\(viewModel.pushReceivedCount)x")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("BLE Wake Reads", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text("\(viewModel.wakeReadSuccessCount) ok")
                        .foregroundStyle(.green)
                    Text("\(viewModel.wakeReadFailureCount) failed")
                        .foregroundStyle(viewModel.wakeReadFailureCount > 0 ? .red : .secondary)
                }

                // Conversion rate (scheduled vs executed)
                if viewModel.refreshScheduleCount > 0 {
                    HStack {
                        Label("Refresh Success Rate", systemImage: "percent")
                        Spacer()
                        let rate = Double(viewModel.refreshTaskCount) / Double(viewModel.refreshScheduleCount) * 100
                        Text(String(format: "%.0f%%", min(rate, 100)))
                            .foregroundStyle(rate > 50 ? .green : (rate > 10 ? .orange : .red))
                    }
                }

                // Last execution times
                if let lastRefresh = viewModel.lastRefreshDate {
                    HStack {
                        Label("Last Refresh", systemImage: "clock")
                        Spacer()
                        Text(lastRefresh, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastProcessing = viewModel.lastProcessingDate {
                    HStack {
                        Label("Last Processing", systemImage: "clock.fill")
                        Spacer()
                        Text(lastProcessing, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastPush = viewModel.lastPushReceivedDate {
                    HStack {
                        Label("Last Push", systemImage: "envelope.open")
                        Spacer()
                        Text(lastPush, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastWakeRead = viewModel.lastWakeReadDate {
                    HStack {
                        Label("Last BLE Wake Read", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(lastWakeRead, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                // Execution history
                if !viewModel.executionHistory.isEmpty {
                    DisclosureGroup("Execution History (\(viewModel.executionHistory.count))") {
                        ForEach(viewModel.executionHistory) { execution in
                            ExecutionHistoryRow(execution: execution)
                        }
                    }
                }

                // Actions
                Button(role: .destructive) {
                    viewModel.resetBackgroundTaskStats()
                } label: {
                    Label("Reset All Statistics", systemImage: "trash")
                }

                Button {
                    viewModel.loadBackgroundTaskStats()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle(L10n.Navigation.settings)
        // Background work updates the tracker while this tab stays alive —
        // reload instead of showing the numbers from app launch
        .onAppear {
            viewModel.loadBackgroundTaskStats()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.loadBackgroundTaskStats()
            }
        }
    }
}

/// One execution history entry: what ran, what triggered it, how it ended
private struct ExecutionHistoryRow: View {
    let execution: TaskExecution

    private var typeColor: Color {
        switch execution.type {
        case .refresh: return .blue
        case .processing: return .orange
        case .silentPush: return .purple
        case .bleWake: return .teal
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(execution.type.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor.opacity(0.2))
                    .cornerRadius(4)

                if let success = execution.success {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(success ? .green : .red)
                        .font(.caption)
                }

                Spacer()

                // Absolute time to line up with server push rounds
                Text(execution.date, format: .dateTime.day().month().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text("Trigger: \(execution.triggerLabel)")
                if let detail = execution.detail {
                    Text("· \(detail)")
                        .foregroundStyle(execution.success == false ? .red : .secondary)
                }
                if execution.duration > 0 {
                    Text("· " + String(format: "%.1fs", execution.duration))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        AppSettingsView()
    }
}

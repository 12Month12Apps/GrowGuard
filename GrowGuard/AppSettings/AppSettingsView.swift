import SwiftUI

@Observable
final class AppSettingsViewModel {
    private let settingsStore: SettingsStore
    private let calendar: Calendar
    private let notificationService: NotificationService
    private var settingsObserver: NSObjectProtocol?

    var preferredReminderTime: Date
    var useConnectionPool: Bool

    // Background Task Debug Info
    var refreshTaskCount: Int = 0
    var processingTaskCount: Int = 0
    var lastRefreshDate: Date?
    var lastProcessingDate: Date?
    var executionHistory: [TaskExecution] = []

    init(
        settingsStore: SettingsStore = .shared,
        calendar: Calendar = .current,
        notificationService: NotificationService = .shared
    ) {
        self.settingsStore = settingsStore
        self.calendar = calendar
        self.notificationService = notificationService
        self.preferredReminderTime = settingsStore.reminderDate(for: calendar)
        self.useConnectionPool = settingsStore.useConnectionPool

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
            case .connectionMode:
                self.useConnectionPool = self.settingsStore.useConnectionPool
            case .reminderTime:
                self.preferredReminderTime = self.settingsStore.reminderDate(for: self.calendar)
            }
        }

        loadBackgroundTaskStats()
    }

    func loadBackgroundTaskStats() {
        let tracker = BackgroundTaskTracker.shared
        refreshTaskCount = tracker.refreshTaskCount
        processingTaskCount = tracker.processingTaskCount
        lastRefreshDate = tracker.lastRefreshDate
        lastProcessingDate = tracker.lastProcessingDate
        executionHistory = tracker.executionHistory
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

    func updateConnectionMode(_ newValue: Bool) {
        let mode: ConnectionMode = newValue ? .connectionPool : .flowercare
        settingsStore.connectionMode = mode
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AppSettingsView: View {
    @State private var viewModel = AppSettingsViewModel()

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

            Section(header: Text(L10n.Settings.connectionModeSection)) {
                Toggle(L10n.Settings.connectionModeToggle, isOn: $viewModel.useConnectionPool)
                    .onChange(of: viewModel.useConnectionPool) { newValue in
                        viewModel.updateConnectionMode(newValue)
                    }

                Text(L10n.Settings.connectionModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // Debug: Background Task Statistics
            Section(header: Text("Background Tasks (Debug)")) {
                // Summary stats
                HStack {
                    Label("Refresh Tasks", systemImage: "arrow.clockwise")
                    Spacer()
                    Text("\(viewModel.refreshTaskCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Processing Tasks", systemImage: "bolt.fill")
                    Spacer()
                    Text("\(viewModel.processingTaskCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Total Executions", systemImage: "number")
                    Spacer()
                    Text("\(viewModel.refreshTaskCount + viewModel.processingTaskCount)")
                        .fontWeight(.semibold)
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

                // Execution history
                if !viewModel.executionHistory.isEmpty {
                    DisclosureGroup("Recent History (\(viewModel.executionHistory.count))") {
                        ForEach(viewModel.executionHistory.prefix(10)) { execution in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(execution.type.rawValue)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(execution.type == .refresh ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                                        .cornerRadius(4)

                                    Spacer()

                                    Text(execution.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    Label("\(execution.successfulDevices)", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Label("\(execution.failedDevices)", systemImage: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Label("\(execution.dataPoints) pts", systemImage: "chart.bar.fill")
                                        .foregroundStyle(.blue)
                                    Text(String(format: "%.1fs", execution.duration))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Actions
                Button(role: .destructive) {
                    viewModel.resetBackgroundTaskStats()
                } label: {
                    Label("Reset Statistics", systemImage: "trash")
                }

                Button {
                    viewModel.loadBackgroundTaskStats()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle(L10n.Navigation.settings)
    }
}

#Preview {
    NavigationStack {
        AppSettingsView()
    }
}

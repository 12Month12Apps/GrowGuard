import SwiftUI

@Observable
final class AppSettingsViewModel {
    private let settingsStore: SettingsStore
    private let calendar: Calendar
    private let notificationService: NotificationService
    private var settingsObserver: NSObjectProtocol?

    var preferredReminderTime: Date
    var useConnectionPool: Bool

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
        }
        .navigationTitle(L10n.Navigation.settings)
    }
}

#Preview {
    NavigationStack {
        AppSettingsView()
    }
}

import SwiftUI

@Observable
final class AppSettingsViewModel {
    private let preferenceStore: NotificationPreferenceStore
    private let calendar: Calendar

    var preferredReminderTime: Date

    init(
        preferenceStore: NotificationPreferenceStore = .shared,
        calendar: Calendar = .current
    ) {
        self.preferenceStore = preferenceStore
        self.calendar = calendar
        self.preferredReminderTime = preferenceStore.reminderDate(for: calendar)
    }

    func updateReminderTime(_ newValue: Date) {
        preferenceStore.updateReminderTime(with: newValue, calendar: calendar)

        Task {
            await PlantMonitorService.shared.rescheduleDailyRemindersToPreferredTime()
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
        }
        .navigationTitle(L10n.Navigation.settings)
    }
}

#Preview {
    NavigationStack {
        AppSettingsView()
    }
}

import Foundation

/// Stores user preferences for notification scheduling
final class NotificationPreferenceStore {
    static let shared = NotificationPreferenceStore()

    private let defaults: UserDefaults
    private let reminderHourKey = "notification.dailyReminderHour"
    private let reminderMinuteKey = "notification.dailyReminderMinute"
    private let fallbackHour = 9
    private let fallbackMinute = 0

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    /// Returns the preferred reminder time as hour/minute components
    func preferredReminderComponents() -> DateComponents {
        let hour = defaults.object(forKey: reminderHourKey) as? Int ?? fallbackHour
        let minute = defaults.object(forKey: reminderMinuteKey) as? Int ?? fallbackMinute

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    /// Returns a date on the current day matching the preferred reminder time
    func reminderDate(for calendar: Calendar = .current) -> Date {
        let components = preferredReminderComponents()
        var base = calendar.dateComponents([.year, .month, .day], from: Date())
        base.hour = components.hour
        base.minute = components.minute

        return calendar.date(from: base) ?? Date()
    }

    /// Saves the preferred reminder time (hour/minute) to user defaults
    func updateReminderTime(with date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? fallbackHour
        let minute = components.minute ?? fallbackMinute

        defaults.set(hour, forKey: reminderHourKey)
        defaults.set(minute, forKey: reminderMinuteKey)
    }
}

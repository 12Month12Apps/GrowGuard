import Foundation

enum ConnectionMode: String {
    case flowercare
    case connectionPool
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("SettingsStore.settingsDidChange")
}

/// Central store for user-configurable app settings backed by UserDefaults
final class SettingsStore {
    enum ChangeKey: String {
        case connectionMode
        case reminderTime
        case serverURL
    }

    static let shared = SettingsStore()
    static let changeUserInfoKey = "SettingsStore.changedKey"

    private let defaults: UserDefaults
    private let reminderHourKey = "notification.dailyReminderHour"
    private let reminderMinuteKey = "notification.dailyReminderMinute"
    private let connectionModeKey = "ble.connectionMode"
    private let serverURLKey = "server.url"
    private let deviceTokenKey = "server.deviceToken"
    private let fallbackHour = 9
    private let fallbackMinute = 0

    /// Default server URL - update this to your production server
    private let defaultServerURL = "https://growguardserver.veit.pro"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Connection Mode

    var connectionMode: ConnectionMode {
        get {
            if let storedValue = defaults.string(forKey: connectionModeKey),
               let mode = ConnectionMode(rawValue: storedValue) {
                return mode
            }
            return .connectionPool
        }
        set {
            defaults.set(newValue.rawValue, forKey: connectionModeKey)
            notifyChange(.connectionMode)
        }
    }

    var useConnectionPool: Bool {
        connectionMode == .connectionPool
    }

    // MARK: - Reminder Time

    func preferredReminderComponents() -> DateComponents {
        let hour = defaults.object(forKey: reminderHourKey) as? Int ?? fallbackHour
        let minute = defaults.object(forKey: reminderMinuteKey) as? Int ?? fallbackMinute

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    func reminderDate(for calendar: Calendar = .current) -> Date {
        let components = preferredReminderComponents()
        var base = calendar.dateComponents([.year, .month, .day], from: Date())
        base.hour = components.hour
        base.minute = components.minute

        return calendar.date(from: base) ?? Date()
    }

    func updateReminderTime(with date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? fallbackHour
        let minute = components.minute ?? fallbackMinute

        defaults.set(hour, forKey: reminderHourKey)
        defaults.set(minute, forKey: reminderMinuteKey)

        notifyChange(.reminderTime)
    }

    // MARK: - Server Configuration

    /// The URL of the GrowGuard server
    var serverURL: String {
        get {
            defaults.string(forKey: serverURLKey) ?? defaultServerURL
        }
        set {
            defaults.set(newValue, forKey: serverURLKey)
            notifyChange(.serverURL)
        }
    }

    /// The APNs device token stored locally (hex format)
    var deviceToken: String? {
        get {
            defaults.string(forKey: deviceTokenKey)
        }
        set {
            defaults.set(newValue, forKey: deviceTokenKey)
        }
    }

    /// Whether the device is registered with the server for push notifications
    var isRegisteredForPush: Bool {
        deviceToken != nil && !deviceToken!.isEmpty
    }

    // MARK: - Helpers

    private func notifyChange(_ key: ChangeKey) {
        NotificationCenter.default.post(
            name: .settingsDidChange,
            object: self,
            userInfo: [Self.changeUserInfoKey: key.rawValue]
        )
    }
}

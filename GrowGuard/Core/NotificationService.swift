import Foundation
import UserNotifications

/// Centralizes scheduling and management of user notifications used across the app.
final class NotificationService {
    static let shared = NotificationService()

    private let center: UNUserNotificationCenter
    private let settingsStore: SettingsStore
    private let defaults: UserDefaults

    /// Cooldown period for immediate watering notifications (24 hours)
    private let immediateNotificationCooldown: TimeInterval = 24 * 60 * 60

    init(
        center: UNUserNotificationCenter = .current(),
        settingsStore: SettingsStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.settingsStore = settingsStore
        self.defaults = defaults
    }

    private enum Identifier {
        static func wateringImmediate(for uuid: String) -> String { "watering-immediate-\(uuid)" }
        static func wateringDaily(for uuid: String) -> String { "watering-daily-\(uuid)" }
    }

    private enum DefaultsKey {
        static func lastImmediateNotification(for uuid: String) -> String { "notification.lastImmediate.\(uuid)" }
        static func lastMoistureAboveMin(for uuid: String) -> String { "notification.lastMoistureAboveMin.\(uuid)" }
    }

    /// Schedules the immediate and recurring watering reminders for a device.
    /// Uses a 24-hour cooldown to prevent notification spam when moisture remains below threshold.
    func scheduleWateringNotifications(for device: FlowerDeviceDTO) async {
        let pendingRequests = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()
        let immediateIdentifier = Identifier.wateringImmediate(for: device.uuid)
        let dailyIdentifier = Identifier.wateringDaily(for: device.uuid)

        // Remove legacy one-off reminders from older builds
        let legacyReminderIds = pendingRequests
            .filter { $0.identifier.contains(device.uuid) && $0.identifier.contains("watering-reminder") }
            .map { $0.identifier }
        if !legacyReminderIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: legacyReminderIds)
            print("🧹 NotificationService: Removed legacy reminders for \(device.name)")
        }

        // Check both pending and delivered notifications to avoid duplicates
        let hasImmediateInSystem = pendingRequests.contains { $0.identifier == immediateIdentifier }
            || deliveredNotifications.contains { $0.request.identifier == immediateIdentifier }
        let hasDaily = pendingRequests.contains { $0.identifier == dailyIdentifier }

        // Check cooldown: Don't send a new immediate notification if we sent one recently
        let shouldSendImmediate = shouldSendImmediateNotification(for: device.uuid, hasImmediateInSystem: hasImmediateInSystem)

        let immediateContent = UNMutableNotificationContent()
        immediateContent.title = "💧 Water Your \(device.name)"
        immediateContent.body = "Moisture level is below optimal range. Your plant needs water now!"
        immediateContent.sound = .default
        immediateContent.categoryIdentifier = "WATERING_REMINDER"
        immediateContent.interruptionLevel = .timeSensitive
        immediateContent.relevanceScore = 1.0
        immediateContent.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "immediate"
        ]

        let immediateRequest = UNNotificationRequest(identifier: immediateIdentifier, content: immediateContent, trigger: nil)

        do {
            if shouldSendImmediate {
                try await center.add(immediateRequest)
                recordImmediateNotificationSent(for: device.uuid)
                print("📱 NotificationService: Scheduled immediate watering notification for \(device.name)")
            } else if hasImmediateInSystem {
                print("⏭️ NotificationService: Immediate watering notification already in system for \(device.name)")
            } else {
                print("⏭️ NotificationService: Skipping immediate notification for \(device.name) - cooldown active")
            }

            if !hasDaily {
                let dailyContent = UNMutableNotificationContent()
                dailyContent.title = "🚨 Still Needs Water: \(device.name)"
                dailyContent.body = "Your plant is still below optimal moisture. Please water it today."
                dailyContent.sound = .default
                dailyContent.categoryIdentifier = "WATERING_REMINDER"
                dailyContent.interruptionLevel = .timeSensitive
                dailyContent.relevanceScore = 0.9
                dailyContent.userInfo = [
                    "deviceUUID": device.uuid,
                    "notificationType": "dailyReminder"
                ]

                let preferenceComponents = settingsStore.preferredReminderComponents()
                let dailyTrigger = UNCalendarNotificationTrigger(dateMatching: preferenceComponents, repeats: true)
                let dailyRequest = UNNotificationRequest(identifier: dailyIdentifier, content: dailyContent, trigger: dailyTrigger)
                try await center.add(dailyRequest)
                print("📱 NotificationService: Scheduled recurring watering reminder for \(device.name)")
            } else {
                print("⏭️ NotificationService: Recurring watering reminder already scheduled for \(device.name)")
            }
        } catch {
            print("❌ NotificationService: Failed to schedule watering reminders: \(error)")
        }
    }

    // MARK: - Cooldown Management

    /// Determines if we should send a new immediate notification based on cooldown and system state.
    private func shouldSendImmediateNotification(for deviceUUID: String, hasImmediateInSystem: Bool) -> Bool {
        // If notification is already in the system (pending or delivered), don't send another
        if hasImmediateInSystem {
            return false
        }

        // Check if we've sent one recently (cooldown)
        let lastSentKey = DefaultsKey.lastImmediateNotification(for: deviceUUID)
        if let lastSent = defaults.object(forKey: lastSentKey) as? Date {
            let timeSinceLastNotification = Date().timeIntervalSince(lastSent)
            if timeSinceLastNotification < immediateNotificationCooldown {
                let hoursRemaining = (immediateNotificationCooldown - timeSinceLastNotification) / 3600
                print("🕐 NotificationService: Cooldown active for \(deviceUUID) - \(String(format: "%.1f", hoursRemaining))h remaining")
                return false
            }
        }

        return true
    }

    /// Records that we sent an immediate notification for a device.
    private func recordImmediateNotificationSent(for deviceUUID: String) {
        let key = DefaultsKey.lastImmediateNotification(for: deviceUUID)
        defaults.set(Date(), forKey: key)
    }

    /// Call this when moisture recovers above the minimum threshold to reset the cooldown.
    /// This allows a new immediate notification when moisture drops below minimum again.
    func resetNotificationCooldown(for deviceUUID: String) {
        let lastSentKey = DefaultsKey.lastImmediateNotification(for: deviceUUID)
        defaults.removeObject(forKey: lastSentKey)
        print("🔄 NotificationService: Reset notification cooldown for \(deviceUUID)")
    }

    /// Schedules a predictive watering notification.
    func schedulePredictiveNotification(for device: FlowerDeviceDTO, wateringDate: Date) async {
        await cancelNotifications(for: device.uuid)

        let notificationDate = wateringDate.addingTimeInterval(-2 * 60 * 60) // 2 hours before

        guard notificationDate > Date() else {
            print("⚠️ NotificationService: Skipping predictive notification - would be in the past")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "🌱 \(device.name) Will Need Water Soon"
        content.body = "Based on current trends, your plant will need watering in about 2 hours."
        content.sound = .default
        content.categoryIdentifier = "WATERING_REMINDER"
        content.interruptionLevel = .active
        content.relevanceScore = 0.7
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "predictive"
        ]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = "watering-predictive-\(device.uuid)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            print("📱 NotificationService: Scheduled predictive watering notification for \(device.name)")
        } catch {
            print("❌ NotificationService: Failed to schedule predictive notification: \(error)")
        }
    }

    /// Removes pending and delivered notifications related to a specific device.
    func cancelNotifications(for deviceUUID: String) async {
        let pendingRequests = await center.pendingNotificationRequests()

        let identifiersToRemove = pendingRequests
            .filter { $0.identifier.contains(deviceUUID) }
            .map { $0.identifier }

        center.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)

        print("🗑️ NotificationService: Cancelled \(identifiersToRemove.count) notifications for device \(deviceUUID)")
    }

    /// Reschedules any persistent watering reminders to match the current preferences.
    func reschedulePersistentWateringReminders() async {
        let pendingRequests = await center.pendingNotificationRequests()
        let preferenceComponents = settingsStore.preferredReminderComponents()
        let recurringRequests = pendingRequests.filter { $0.identifier.contains("watering-daily-") }

        guard !recurringRequests.isEmpty else {
            print("ℹ️ NotificationService: No persistent watering reminders to reschedule")
            return
        }

        for request in recurringRequests {
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            let updatedTrigger = UNCalendarNotificationTrigger(dateMatching: preferenceComponents, repeats: true)
            let updatedRequest = UNNotificationRequest(identifier: request.identifier, content: request.content, trigger: updatedTrigger)

            do {
                try await center.add(updatedRequest)
                print("🔁 NotificationService: Rescheduled reminder \(request.identifier)")
            } catch {
                print("❌ NotificationService: Failed to reschedule reminder \(request.identifier): \(error)")
            }
        }
    }
}

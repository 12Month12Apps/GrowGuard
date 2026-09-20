import Foundation
import UserNotifications

/// The families of notification the app owns, distinguished by identifier
/// prefix. Cancelling has to be scoped to a family: the watering paths run
/// after every wake read, and an unscoped sweep would delete the sensor-health
/// alerts that were just delivered while their once-per-episode markers stay
/// set — the alert would never be posted again.
enum NotificationKind: CaseIterable {
    case watering
    case sensorHealth

    /// Every identifier of this kind starts with this prefix.
    var identifierPrefix: String {
        switch self {
        case .watering: return "watering-"
        case .sensorHealth: return "sensor-"
        }
    }

    /// Prefixes builds before this family's naming wrote. A pending request
    /// survives an app update, so an identifier from an older build is still
    /// in the system afterwards and has to be swept as a member of its kind.
    var legacyPrefixes: [String] {
        switch self {
        // The REMIND_LATER snooze was `reminder-later-<uuid>` before it moved
        // inside the `watering-` family.
        case .watering: return ["reminder-later-"]
        case .sensorHealth: return []
        }
    }
}

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

    /// Prefix of the snooze the user sets from the REMIND_LATER action.
    static let reminderLaterPrefix = "watering-reminder-later-"

    /// The snooze scheduled from the REMIND_LATER notification action. Inside
    /// the `watering-` family so `cancelNotifications(for:kinds: [.watering])`
    /// sweeps it when the plant is watered or the device is deleted — an
    /// unprefixed identifier outlived both.
    static func reminderLaterIdentifier(for uuid: String) -> String {
        reminderLaterPrefix + uuid
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
        let legacyReminderIds = Self.legacyReminderIdentifiers(
            pending: pendingRequests.map(\.identifier),
            deviceUUID: device.uuid
        )
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

    /// One-off reminders from builds before the `watering-` prefixes existed.
    /// Pure so the exclusion below can be tested without UNUserNotificationCenter.
    ///
    /// `watering-reminder-later-` is *not* legacy: it is the snooze the user
    /// just chose from the REMIND_LATER action. Every wake read with moisture
    /// still below the minimum calls `scheduleWateringNotifications`, and the
    /// 24 h immediate cooldown means no replacement alert is posted — sweeping
    /// the snooze here would silently drop it while the plant is still dry, so
    /// the user would hear nothing until the daily reminder. A new watering
    /// schedule does not supersede a snooze the user set minutes ago.
    ///
    /// `reminder-later-` *is* legacy: that is what old builds wrote for the
    /// snooze, before it was renamed into the `watering-` family. Matching
    /// only `watering-reminder` left a pending one from before the upgrade
    /// untouched by this sweep and by the kind filter alike.
    static func legacyReminderIdentifiers(pending: [String], deviceUUID: String) -> [String] {
        pending.filter {
            $0.contains(deviceUUID)
                && ($0.contains("watering-reminder") || $0.hasPrefix("reminder-later-"))
                && !$0.hasPrefix(reminderLaterPrefix)
        }
    }

    /// Identifiers to sweep for one device, restricted to the given kinds.
    /// Pure so the scoping can be tested without UNUserNotificationCenter.
    ///
    /// Sensor-health notifications are posted with a nil trigger, so they are
    /// only ever delivered and never pending — both lists have to be searched.
    static func identifiersToCancel(pending: [String],
                                    delivered: [String],
                                    deviceUUID: String,
                                    kinds: Set<NotificationKind>) -> [String] {
        let prefixes = kinds.flatMap { [$0.identifierPrefix] + $0.legacyPrefixes }
        func matches(_ identifier: String) -> Bool {
            identifier.contains(deviceUUID) && prefixes.contains { identifier.hasPrefix($0) }
        }
        var identifiers = Set(pending.filter(matches))
        identifiers.formUnion(delivered.filter(matches))
        return Array(identifiers)
    }

    /// Removes pending and delivered notifications of the given kinds for a
    /// device. Defaults to the watering family: the callers on the watering
    /// path must not touch sensor-health alerts.
    func cancelNotifications(for deviceUUID: String, kinds: Set<NotificationKind> = [.watering]) async {
        let pendingRequests = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()

        let identifiersToRemove = Self.identifiersToCancel(
            pending: pendingRequests.map(\.identifier),
            delivered: deliveredNotifications.map(\.request.identifier),
            deviceUUID: deviceUUID,
            kinds: kinds
        )

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

// MARK: - Sensor health (spec 2026-09-14-sensor-health-design.md)

/// Seam for SensorHealthMonitor; tests record calls instead of touching
/// UNUserNotificationCenter.
protocol SensorHealthNotifying {
    func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async
    func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async
}

extension NotificationService: SensorHealthNotifying {

    private enum SensorHealthIdentifier {
        // `sensor-` prefix + UUID: cancelNotifications(for:kinds:) sweeps these
        // only when `.sensorHealth` is asked for — never from a watering path
        static func unreachable(for uuid: String) -> String { "sensor-unreachable-\(uuid)" }
        static func lowBattery(for uuid: String) -> String { "sensor-battery-\(uuid)" }
    }

    func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async {
        let days = SensorHealth.daysSilent(since: since, now: now)
        let content = UNMutableNotificationContent()
        var body: String
        if confirmedByPeer {
            content.title = L10n.SensorHealth.Notification.Confirmed.title(device.name)
            body = device.location.map { L10n.SensorHealth.Notification.Confirmed.bodyLocation($0, days) }
                ?? L10n.SensorHealth.Notification.Confirmed.body(days)
        } else {
            content.title = L10n.SensorHealth.Notification.Unreachable.title(device.name)
            body = device.location.map { L10n.SensorHealth.Notification.Unreachable.bodyLocation($0, days) }
                ?? L10n.SensorHealth.Notification.Unreachable.body(days)
        }
        if let lastKnownBattery {
            body += L10n.SensorHealth.Notification.lastKnown(lastKnownBattery)
        }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 0.8
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": confirmedByPeer ? "sensorUnreachableConfirmed" : "sensorUnreachable"
        ]

        let identifier = SensorHealthIdentifier.unreachable(for: device.uuid)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            print("📱 NotificationService: Sent unreachable notification (confirmed: \(confirmedByPeer)) for \(device.name)")
        } catch {
            print("❌ NotificationService: Failed to send unreachable notification: \(error)")
        }
    }

    func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.SensorHealth.Notification.LowBattery.title(device.name)
        content.body = L10n.SensorHealth.Notification.LowBattery.body(percent)
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 0.6
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "sensorLowBattery"
        ]

        let identifier = SensorHealthIdentifier.lowBattery(for: device.uuid)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            print("📱 NotificationService: Sent low battery notification (\(percent) %) for \(device.name)")
        } catch {
            print("❌ NotificationService: Failed to send low battery notification: \(error)")
        }
    }
}

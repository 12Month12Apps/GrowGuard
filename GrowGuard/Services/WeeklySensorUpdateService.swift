//
//  WeeklySensorUpdateService.swift
//  GrowGuard
//
//  Created by Claude on 19.10.25.
//

import Foundation
import UserNotifications

class WeeklySensorUpdateService {
    static let shared = WeeklySensorUpdateService()

    private let notificationIdentifier = "pro.veit.GrowGuard.weeklySensorUpdate"
    private let categoryIdentifier = "SENSOR_UPDATE_REMINDER"

    private init() {}

    /// Schedule a weekly reminder to update sensor data
    /// The notification will be sent every week at the specified day and time
    func scheduleWeeklyReminder(weekday: Int = 1, hour: Int = 10, minute: Int = 0) async {
        print("🔔 WeeklySensorUpdateService: Scheduling weekly sensor update reminder...")

        // Request notification authorization if needed
        let center = UNUserNotificationCenter.current()

        // Cancel existing weekly reminder
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Zeit für Sensor-Updates! 📊"
        content.body = "Vergiss nicht, deine Sensordaten zu aktualisieren, um deine Pflanzen optimal zu überwachen."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.badge = 1

        // Create weekly trigger
        // weekday: 1 = Sunday, 2 = Monday, ..., 7 = Saturday
        var dateComponents = DateComponents()
        dateComponents.weekday = weekday
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        // Create request
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )

        // Schedule notification
        do {
            try await center.add(request)

            // Log next trigger date for debugging
            if let nextTriggerDate = trigger.nextTriggerDate() {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                formatter.locale = Locale(identifier: "de_DE")
                print("✅ WeeklySensorUpdateService: Weekly reminder scheduled for \(formatter.string(from: nextTriggerDate))")
            } else {
                print("✅ WeeklySensorUpdateService: Weekly reminder scheduled successfully")
            }
        } catch {
            print("❌ WeeklySensorUpdateService: Failed to schedule weekly reminder: \(error.localizedDescription)")
        }
    }

    /// Cancel the weekly reminder
    func cancelWeeklyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        print("🔕 WeeklySensorUpdateService: Weekly reminder canceled")
    }

    /// Check if weekly reminder is currently scheduled
    func isReminderScheduled() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        return pendingRequests.contains { $0.identifier == notificationIdentifier }
    }

    /// Get the next scheduled reminder date
    func getNextReminderDate() async -> Date? {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()

        if let request = pendingRequests.first(where: { $0.identifier == notificationIdentifier }),
           let trigger = request.trigger as? UNCalendarNotificationTrigger {
            return trigger.nextTriggerDate()
        }

        return nil
    }
}

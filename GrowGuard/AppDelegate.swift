//
//  AppDelegate.swift
//  GrowGuard
//
//  Created by Veit Progl on 01.09.24.
//

import UIKit
import BackgroundTasks
import SwiftUI
import Combine
import SwiftData
import UserNotifications
import CoreData

class AppDelegate: NSObject, UIApplicationDelegate {
    
    
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Create the BLE stack and wake handler before anything else: when
        // iOS relaunches the app for a completed pending connect (state
        // restoration), these must exist to receive the events
        _ = ConnectionPoolManager.shared
        BackgroundBLEWakeService.shared.start()

        // SwiftUI scene lifecycle: applicationDidEnterBackground is never
        // called on the app delegate — schedule BG tasks via the
        // UIApplication notification instead (posted in every lifecycle)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePlantMonitoringTask(source: .enterBackground)
            self?.scheduleProcessingTask(source: .enterBackground)
        }

        // Clear any lingering notification badges from previous sessions
        application.applicationIconBadgeNumber = 0

        // Add notification actions
        let waterAction = UNNotificationAction(identifier: "WATER_ACTION", title: "Mark as Watered", options: .foreground)
        let remindLaterAction = UNNotificationAction(identifier: "REMIND_LATER", title: "Remind Me Later", options: .foreground)
        
        let wateringCategory = UNNotificationCategory(
            identifier: "WATERING_REMINDER",
            actions: [waterAction, remindLaterAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        // Add sensor update reminder category
        let sensorUpdateCategory = UNNotificationCategory(
            identifier: "SENSOR_UPDATE_REMINDER",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        UNUserNotificationCenter.current().setNotificationCategories([wateringCategory, sensorUpdateCategory])
        
        // ⚠️ CRITICAL: Set the notification delegate - this is required for notifications to work!
        UNUserNotificationCenter.current().delegate = self
        
        // Register background task for daily plant monitoring (quick refresh)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "pro.veit.GrowGuard.plantMonitor", using: nil) { task in
            self.handlePlantMonitoringTask(task: task as! BGAppRefreshTask)
        }

        // Register background processing task for longer operations (historical sync)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.growguard.processing", using: nil) { task in
            self.handleProcessingTask(task: task as! BGProcessingTask)
        }
        
        // Silent pushes (phase 2: hourly server push arms pending connects)
        // need NO user permission — register unconditionally so the device
        // token reaches the server even if notification permission is denied
        print("📲 AppDelegate: Registering for remote notifications...")
        application.registerForRemoteNotifications()

        // BGTask scheduling must not depend on the notification permission
        // either — schedule at launch unconditionally
        schedulePlantMonitoringTask(source: .appLaunch)
        scheduleProcessingTask(source: .appLaunch)

        // Anfrage für die Berechtigung, Benachrichtigungen zu senden (inkl. Time-Sensitive)
        print("🔐 AppDelegate: Requesting notification permissions including Time-Sensitive...")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ AppDelegate: Notification permissions granted (including Time-Sensitive)")

                    // Check if time-sensitive notifications are actually enabled
                    UNUserNotificationCenter.current().getNotificationSettings { settings in
                        print("📱 AppDelegate: Notification settings:")
                        print("   Authorization Status: \(settings.authorizationStatus.rawValue)")
                        print("   Alert Setting: \(settings.alertSetting.rawValue)")
                        print("   Sound Setting: \(settings.soundSetting.rawValue)")
                        print("   Badge Setting: \(settings.badgeSetting.rawValue)")
                        print("   Time Sensitive Setting: \(settings.timeSensitiveSetting.rawValue)")

                        if settings.timeSensitiveSetting == .enabled {
                            print("🚨 AppDelegate: Time-Sensitive notifications are ENABLED - urgent plant alerts will break through Do Not Disturb!")
                        } else {
                            print("⚠️ AppDelegate: Time-Sensitive notifications not fully enabled - some urgent alerts may be delayed")
                        }
                    }

                    // Validate notification system after permission is granted
                    Task {
                        await self.validateNotificationSystem()

                        // Schedule weekly sensor update reminder
                        await WeeklySensorUpdateService.shared.scheduleWeeklyReminder()
                    }
                } else if let error = error {
                    print("❌ AppDelegate: Failed to request authorization for notifications: \(error.localizedDescription)")
                } else {
                    print("❌ AppDelegate: Notification permission denied by user - urgent plant alerts will not work")
                }
            }
        }
        
        return true
    }
    
    // MARK: - Remote Notification Registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Convert device token to hex string
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📲 AppDelegate: Received APNs device token: \(tokenString.prefix(16))...")

        // Store token locally
        SettingsStore.shared.deviceToken = tokenString

        // Register token with server
        Task {
            await registerDeviceTokenWithServer(tokenString)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ AppDelegate: Failed to register for remote notifications: \(error.localizedDescription)")
    }

    /// Registers the device token with the GrowGuard server
    private func registerDeviceTokenWithServer(_ token: String) async {
        do {
            let response = try await GrowGuardAPIClient.shared.registerDevice(token: token)
            if response.success {
                print("✅ AppDelegate: Device token registered with server successfully")
            } else {
                print("⚠️ AppDelegate: Server registration failed: \(response.message ?? "Unknown error")")
            }
        } catch {
            print("❌ AppDelegate: Failed to register device token with server: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote Notification Handling (Silent Push)

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📬 AppDelegate: Received remote notification (silent push)")

        // Check if this is a silent/background notification
        let isContentAvailable = (userInfo["aps"] as? [String: Any])?["content-available"] as? Int == 1

        if isContentAvailable {
            print("🔄 AppDelegate: Silent push — arming background connects")
            BackgroundTaskTracker.shared.recordPushReceived()
            Task { @MainActor in
                await BackgroundBLEWakeService.shared.armAll(source: .backgroundPush)
                completionHandler(.newData)
            }
        } else {
            print("ℹ️ AppDelegate: Non-silent notification received")
            completionHandler(.noData)
        }
    }

    private func schedulePlantMonitoringTask(source: SchedulingSource) {
        let request = BGAppRefreshTaskRequest(identifier: "pro.veit.GrowGuard.plantMonitor")
        // Use 15 minutes (iOS minimum for BGAppRefreshTask) for more frequent attempts
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundTaskTracker.shared.recordSchedulingAttempt(
                type: .refresh,
                success: true,
                source: source
            )
        } catch {
            BackgroundTaskTracker.shared.recordSchedulingAttempt(
                type: .refresh,
                success: false,
                error: error.localizedDescription,
                source: source
            )
        }
    }
    
    private func handlePlantMonitoringTask(task: BGAppRefreshTask) {
        // Schedule next monitoring task
        schedulePlantMonitoringTask(source: .afterExecution)

        // Arm-don't-fetch (spec 2026-06-12): only issue pending connects
        // here. The read happens on the BLE wake via BackgroundBLEWakeService,
        // so nothing races the ~30 s window.
        let armWork = Task { @MainActor in
            await BackgroundBLEWakeService.shared.armAll(source: .backgroundTask)
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            armWork.cancel()
        }
    }

    // MARK: - Background Processing Task (Historical Sync)

    private func scheduleProcessingTask(source: SchedulingSource) {
        let request = BGProcessingTaskRequest(identifier: "com.growguard.processing")
        request.requiresNetworkConnectivity = false
        // Removed requiresExternalPower to allow running without charging
        // This gives us more opportunities for background execution
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundTaskTracker.shared.recordSchedulingAttempt(
                type: .processing,
                success: true,
                source: source
            )
        } catch {
            BackgroundTaskTracker.shared.recordSchedulingAttempt(
                type: .processing,
                success: false,
                error: error.localizedDescription,
                source: source
            )
        }
    }

    private func handleProcessingTask(task: BGProcessingTask) {
        // Schedule next processing task
        scheduleProcessingTask(source: .afterExecution)

        print("📚 AppDelegate: Processing task — background history sync")

        let syncWork = Task { @MainActor in
            await BackgroundHistorySyncService.shared.syncAllDevices()
            await PlantMonitorService.shared.performDailyDeviceCheck()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            // Suspends the in-flight flow (progress kept for resume) and
            // makes syncAllDevices return, which completes the task above
            Task { @MainActor in
                BackgroundHistorySyncService.shared.requestExpiration()
            }
            _ = syncWork
        }
    }

    // MARK: - Notification System Validation
    
    private func validateNotificationSystem() async {
        print("🔍 AppDelegate: Validating notification system...")
        
        let center = UNUserNotificationCenter.current()
        
        // 1. Check if delegate is set
        if center.delegate == nil {
            print("❌ AppDelegate: CRITICAL - UNUserNotificationCenter delegate is not set!")
        } else {
            print("✅ AppDelegate: UNUserNotificationCenter delegate is properly set")
        }
        
        // 2. Check authorization status
        let settings = await center.notificationSettings()
        print("🔍 AppDelegate: Notification authorization status: \(settings.authorizationStatus.rawValue)")
        print("🔍 AppDelegate: Alert setting: \(settings.alertSetting.rawValue)")
        print("🔍 AppDelegate: Sound setting: \(settings.soundSetting.rawValue)")
        print("🔍 AppDelegate: Badge setting: \(settings.badgeSetting.rawValue)")
        
        // 3. Check categories
        let categories = await center.notificationCategories()
        let hasWateringCategory = categories.contains { $0.identifier == "WATERING_REMINDER" }
        
        if hasWateringCategory {
            print("✅ AppDelegate: WATERING_REMINDER category is registered")
        } else {
            print("❌ AppDelegate: WATERING_REMINDER category is missing!")
        }
        
        // 4. Send test notification to validate the system (disabled for production)
        // await sendSystemValidationNotification()
    }
    
//    // Ergänze diese Methoden entsprechend dem Aufbau deiner App
//    @MainActor
//    func fetchSavedDevices() throws -> [FlowerDevice] {
//        let fetchDescriptor = FetchDescriptor<FlowerDevice>()
//
//        do {
//            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
//            return result
//        } catch {
//            print(error.localizedDescription)
//            throw error
//        }
//    }
    
    
//    // Methode zum Senden einer lokalen Benachrichtigung
//    func sendCompletionNotification() {
//        let content = UNMutableNotificationContent()
//        content.title = "Datenaktualisierung abgeschlossen"
//        content.body = "Die Sensorendaten wurden erfolgreich aktualisiert."
//        content.sound = .default
//        
//        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
//        
//        UNUserNotificationCenter.current().add(request) { error in
//            if let error = error {
//                print("Failed to deliver notification: \(error.localizedDescription)")
//            }
//        }
//    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // ⚠️ CRITICAL: This method is required to show notifications when app is in foreground!
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("🚨 AppDelegate: Notification received while app in foreground: \(notification.request.content.title)")
        
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        let userInfoDeviceId = userInfo["deviceUUID"] as? String
        let identifierDeviceId = identifier.split(separator: "-").last.map(String.init)

        guard let deviceId = userInfoDeviceId ?? identifierDeviceId, !deviceId.isEmpty else {
            print("⚠️ AppDelegate: Unable to determine device UUID for notification \(identifier)")
            completionHandler()
            return
        }
        
        switch response.actionIdentifier {
        case "WATER_ACTION":
            // Mark plant as watered using the new watering event system
            Task {
                await PlantMonitorService.shared.recordWateringEvent(
                    for: deviceId,
                    source: WateringSource.notification,
                    notes: "Marked as watered from notification"
                )
                print("💧 AppDelegate: Recorded watering event for device \(deviceId) from notification")
            }
        case "REMIND_LATER":
            // Schedule a reminder for 2 hours later using the notification service
            Task {
                if let device = try? await fetchDevices(withId: deviceId).first {
                    // Cancel existing notifications and schedule a new one for 2 hours later
                    // Cancel notifications by recreating them - simplified approach
                    let center = UNUserNotificationCenter.current()
                    let pendingRequests = await center.pendingNotificationRequests()
                    let identifiersToRemove = pendingRequests
                        .filter {
                            $0.identifier.contains(deviceId) &&
                            !$0.identifier.contains("watering-daily")
                        }
                        .map { $0.identifier }
                    center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
                    
                    let content = UNMutableNotificationContent()
                    content.title = response.notification.request.content.title
                    content.body = "Reminder: Your plant still needs water!"
                    content.sound = .default
                    content.categoryIdentifier = "WATERING_REMINDER"
                    content.userInfo = response.notification.request.content.userInfo
                    content.interruptionLevel = .timeSensitive
                    
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2 * 60 * 60, repeats: false)
                    let request = UNNotificationRequest(identifier: "reminder-later-\(deviceId)", content: content, trigger: trigger)
                    
                    try await UNUserNotificationCenter.current().add(request)
                    print("⏰ AppDelegate: Scheduled reminder for device \(deviceId) in 2 hours")
                }
            }
        default:
            break
        }
        
        completionHandler()
    }
    
    @MainActor
    func fetchDevices(withId uuid: String) async throws -> [FlowerDeviceDTO] {
        do {
            if let device = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: uuid) {
                return [device]
            } else {
                return []
            }
        } catch {
            print("Error fetching device: \(error.localizedDescription)")
            throw error
        }
    }
}

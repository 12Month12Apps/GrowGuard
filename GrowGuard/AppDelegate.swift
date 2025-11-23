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
        
        // Anfrage für die Berechtigung, Benachrichtigungen zu senden (inkl. Time-Sensitive)
        print("🔐 AppDelegate: Requesting notification permissions including Time-Sensitive...")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ AppDelegate: Notification permissions granted (including Time-Sensitive)")

                    // Register for remote notifications
                    print("📲 AppDelegate: Registering for remote notifications...")
                    application.registerForRemoteNotifications()

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

                    // Schedule background tasks on app launch (more aggressive scheduling)
                    self.schedulePlantMonitoringTask(source: .appLaunch)
                    self.scheduleProcessingTask(source: .appLaunch)
                } else if let error = error {
                    print("❌ AppDelegate: Failed to request authorization for notifications: \(error.localizedDescription)")
                } else {
                    print("❌ AppDelegate: Notification permission denied by user - urgent plant alerts will not work")
                }
            }
        }
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule plant monitoring task when app goes to background
        schedulePlantMonitoringTask(source: .enterBackground)

        // Schedule processing task for historical sync
        scheduleProcessingTask(source: .enterBackground)
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
            print("🔄 AppDelegate: Processing background notification - triggering sensor data fetch")

            // Trigger background sensor data fetch (source: backgroundPush)
            Task { @MainActor in
                let fetchResult = await BackgroundSensorDataService.shared.fetchSensorDataInBackground(source: .backgroundPush)

                print("📊 AppDelegate: Remote push fetch completed - \(fetchResult.successfulDevices.count) devices, \(fetchResult.totalDataPoints) data points in \(String(format: "%.1f", fetchResult.duration))s")

                // Perform device status checks with the new data
                await PlantMonitorService.shared.performDailyDeviceCheck()

                // Report result to iOS
                if fetchResult.successfulDevices.isEmpty && fetchResult.failedDevices.isEmpty {
                    completionHandler(.noData)
                } else if !fetchResult.successfulDevices.isEmpty {
                    completionHandler(.newData)
                } else {
                    completionHandler(.failed)
                }
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

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let operation = BlockOperation {
            // Perform device monitoring in background with sensor data fetch
            let group = DispatchGroup()
            group.enter()

            Task { @MainActor in
                defer { group.leave() }

                print("🔄 AppDelegate: Starting background sensor data fetch")

                // Step 1: Fetch fresh sensor data from devices using ConnectionPool (source: backgroundTask)
                let fetchResult = await BackgroundSensorDataService.shared.fetchSensorDataInBackground(source: .backgroundTask)

                print("📊 AppDelegate: Background fetch completed - \(fetchResult.successfulDevices.count) devices, \(fetchResult.totalDataPoints) data points in \(String(format: "%.1f", fetchResult.duration))s")

                // Track execution for debugging
                BackgroundTaskTracker.shared.recordRefreshTaskExecution(result: fetchResult)
                BackgroundTaskTracker.shared.printSummary()

                // Step 2: Perform device status checks with the new data
                await PlantMonitorService.shared.performDailyDeviceCheck()

                print("✅ AppDelegate: Completed plant monitoring task")
            }

            group.wait()
        }

        task.expirationHandler = {
            print("⏰ AppDelegate: Plant monitoring task expired, cancelling fetch")
            Task { @MainActor in
                BackgroundSensorDataService.shared.cancelFetch()
            }
            queue.cancelAllOperations()
        }

        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
        }

        queue.addOperation(operation)
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

        print("🔄 AppDelegate: Starting background processing task for historical sync")

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let operation = BlockOperation {
            let group = DispatchGroup()
            group.enter()

            Task { @MainActor in
                defer { group.leave() }

                // Processing task has more time - fetch data and sync historical if needed
                print("📊 AppDelegate: Processing task - fetching sensor data with extended time")

                // Use extended timeout for processing task (source: backgroundTask)
                let fetchResult = await BackgroundSensorDataService.shared.fetchSensorDataInBackground(source: .backgroundTask)

                print("📊 AppDelegate: Processing fetch completed - \(fetchResult.successfulDevices.count) devices in \(String(format: "%.1f", fetchResult.duration))s")

                // Track execution for debugging
                BackgroundTaskTracker.shared.recordProcessingTaskExecution(result: fetchResult)
                BackgroundTaskTracker.shared.printSummary()

                // Run device checks
                await PlantMonitorService.shared.performDailyDeviceCheck()

                print("✅ AppDelegate: Completed processing task")
            }

            group.wait()
        }

        task.expirationHandler = {
            print("⏰ AppDelegate: Processing task expired")
            Task { @MainActor in
                BackgroundSensorDataService.shared.cancelFetch()
            }
            queue.cancelAllOperations()
        }

        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
        }

        queue.addOperation(operation)
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
    
//    func scanAndCollectData(for device: FlowerDevice, using ble: FlowerCareManager) async {
//        await withCheckedContinuation { continuation in
//            var subscription: AnyCancellable?
//
//            ble.connectToKnownDevice(device: device)
//            ble.requestLiveData()
//
//            subscription = ble.sensorDataPublisher.sink { data in
//                device.sensorData.append(data)
//                
//                // Check moisture level after adding new data
//                PlantMonitorService.shared.checkDeviceStatus(device: device)
//                
//                do {
//                    try DataService.sharedModelContainer.mainContext.save()
//                } catch {
//                    print(error.localizedDescription)
//                }
//                
//                subscription?.cancel()
//                continuation.resume()
//            }
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

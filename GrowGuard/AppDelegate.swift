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
        
        // Register background task for daily plant monitoring
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "pro.veit.GrowGuard.plantMonitor", using: nil) { task in
            self.handlePlantMonitoringTask(task: task as! BGAppRefreshTask)
        }
        
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
    
    /// Check current notification permission status (can be called anytime)
    func checkNotificationPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                print("📱 AppDelegate: Current notification permissions:")
                print("   Authorization: \(settings.authorizationStatus.rawValue)")
                print("   Time-Sensitive: \(settings.timeSensitiveSetting.rawValue)")
                
                switch settings.authorizationStatus {
                case .notDetermined:
                    print("⚪ Notifications: Not asked yet")
                case .denied:
                    print("🔴 Notifications: DENIED - Plant alerts won't work!")
                case .authorized:
                    print("🟢 Notifications: Authorized")
                case .provisional:
                    print("🟡 Notifications: Provisional (quiet)")
                case .ephemeral:
                    print("🟡 Notifications: Ephemeral")
                @unknown default:
                    print("❓ Notifications: Unknown status")
                }
                
                if settings.timeSensitiveSetting == .enabled {
                    print("🚨 Time-Sensitive: ENABLED - Urgent alerts will break through Do Not Disturb")
                } else {
                    print("⚠️ Time-Sensitive: DISABLED - Urgent alerts may be delayed")
                }
            }
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule plant monitoring task when app goes to background
        schedulePlantMonitoringTask()
    }
    
    private func schedulePlantMonitoringTask() {
        let request = BGAppRefreshTaskRequest(identifier: "pro.veit.GrowGuard.plantMonitor")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60) // Check every 12 hours
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ AppDelegate: Scheduled plant monitoring task")
        } catch {
            print("❌ AppDelegate: Unable to submit plant monitoring task: \(error.localizedDescription)")
        }
    }
    
    private func handlePlantMonitoringTask(task: BGAppRefreshTask) {
        // Schedule next monitoring task
        schedulePlantMonitoringTask()
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let operation = BlockOperation {
            // Perform daily device monitoring in background
            let group = DispatchGroup()
            group.enter()
            
            Task {
                defer { group.leave() }
                await PlantMonitorService.shared.performDailyDeviceCheck()
                print("✅ AppDelegate: Completed plant monitoring task")
            }
            
            group.wait()
        }
        
        task.expirationHandler = {
            print("⏰ AppDelegate: Plant monitoring task expired")
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
    
    private func sendSystemValidationNotification() async {
        print("🧪 AppDelegate: Sending system validation notification...")
        
        let content = UNMutableNotificationContent()
        content.title = "✅ GrowGuard Notifications Active"
        content.body = "Push notifications are working correctly! This test was sent automatically."
        content.sound = .default
        content.badge = 1
        content.categoryIdentifier = "WATERING_REMINDER"
        
        let identifier = "system-validation-\(Date().timeIntervalSince1970)"
        
        // Use time interval of 2 seconds to ensure it shows up
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ AppDelegate: System validation notification scheduled")
        } catch {
            print("❌ AppDelegate: Failed to send validation notification: \(error)")
        }
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
        let deviceId = identifier.components(separatedBy: "-")[1]
        
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
                    let identifiersToRemove = pendingRequests.filter { $0.identifier.contains(deviceId) }.map { $0.identifier }
                    center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
                    
                    let content = UNMutableNotificationContent()
                    content.title = response.notification.request.content.title
                    content.body = "Reminder: Your plant still needs water!"
                    content.sound = .default
                    content.categoryIdentifier = "WATERING_REMINDER"
                    content.userInfo = response.notification.request.content.userInfo
                    
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

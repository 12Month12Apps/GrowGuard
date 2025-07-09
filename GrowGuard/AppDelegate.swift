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
        
        UNUserNotificationCenter.current().setNotificationCategories([wateringCategory])
        
        // Registrierung der Hintergrundaufgabe
//        BGTaskScheduler.shared.register(forTaskWithIdentifier: "pro.veit.GrowGuard.refresh", using: nil) { task in
//            self.handleAppRefresh(task: task as! BGAppRefreshTask)
//        }
        
        // Anfrage für die Berechtigung, Benachrichtigungen zu senden
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else if let error = error {
                print("Failed to request authorization for notifications: \(error.localizedDescription)")
            }
        }
        
        return true
    }
    
//    func applicationDidEnterBackground(_ application: UIApplication) {
//        // Planen einer neuen Hintergrundaufgabe, wenn die App in den Hintergrund geht
//        scheduleAppRefresh()
//    }
    
//    func scheduleAppRefresh() {
//        let request = BGAppRefreshTaskRequest(identifier: "pro.veit.GrowGuard.refresh")
//        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // 1 Tag später
//        do {
//            try BGTaskScheduler.shared.submit(request)
//        } catch {
//            print("Unable to submit task: \(error.localizedDescription)")
//        }
//    }
    
//    func handleAppRefresh(task: BGAppRefreshTask) {
//        scheduleAppRefresh() // Planen einer neuen Hintergrundaufgabe
//        
//        let queue = OperationQueue()
//        queue.maxConcurrentOperationCount = 1
//        
//        let operation = BlockOperation {
//            // Hier kommt deine Hintergrundarbeit rein
//            let ble = FlowerCareManager.shared
//            let allSavedDevices = try? self.fetchSavedDevices()
//            
//            allSavedDevices?.forEach { device in
//                // Check if we already have recent data
//                if let latestData = device.sensorData.last,
//                   Date().timeIntervalSince(latestData.date) < 24 * 60 * 60 {
//                    // Check device status even if we don't fetch new data
//                    PlantMonitorService.shared.checkDeviceStatus(device: device)
//                } else {
//                    // Fetch new data if needed
//                    ble.disconnect()
//                    Task {
//                        await self.scanAndCollectData(for: device, using: ble)
//                    }
//                }
//            }
//            
//            // Benachrichtigung senden, nachdem die Arbeit abgeschlossen ist
//            self.sendCompletionNotification()
//        }
//        
//        task.expirationHandler = {
//            queue.cancelAllOperations()
//        }
//        
//        operation.completionBlock = {
//            task.setTaskCompleted(success: !operation.isCancelled)
//        }
//        
//        queue.addOperation(operation)
//    }
    
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
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let deviceId = identifier.components(separatedBy: "-")[1]
        
        switch response.actionIdentifier {
        case "WATER_ACTION":
            // Mark plant as watered
            Task {
                if let device = try? await fetchDevices(withId: deviceId).first {
                    // You could add a "lastWatered" property to FlowerDevice model
                    // device.lastWatered = Date()
                    try? DataService.shared.saveContext()
                }
            }
        case "REMIND_LATER":
            // Schedule a reminder for 1 hour later
            if let device = try? fetchDevices(withId: deviceId).first {
                let content = response.notification.request.content
                
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
                let request = UNNotificationRequest(identifier: "reminder-later-\(deviceId)", content: content, trigger: trigger)
                
                UNUserNotificationCenter.current().add(request)
            }
        default:
            break
        }
        
        completionHandler()
    }
    
    @MainActor
    func fetchDevices(withId uuid: String) throws -> [FlowerDevice] {
        let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        do {
            let result = try DataService.shared.context.fetch(request)
            return result
        } catch {
            print(error.localizedDescription)
            throw error
        }
    }
}

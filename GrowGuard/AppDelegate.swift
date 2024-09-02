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

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Registrierung der Hintergrundaufgabe
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "pro.veit.GrowGuard.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        
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
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Planen einer neuen Hintergrundaufgabe, wenn die App in den Hintergrund geht
        scheduleAppRefresh()
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "pro.veit.GrowGuard.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60) // 1 Tag später
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Unable to submit task: \(error.localizedDescription)")
        }
    }
    
    func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh() // Planen einer neuen Hintergrundaufgabe
        
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let operation = BlockOperation {
            // Hier kommt deine Hintergrundarbeit rein
            let ble = FlowerCareManager.shared
            let allSavedDevices = try? self.fetchSavedDevices()
            
            allSavedDevices?.forEach { device in
                ble.disconnect()
                Task {
                    await self.scanAndCollectData(for: device, using: ble)
                }
            }
            
            // Benachrichtigung senden, nachdem die Arbeit abgeschlossen ist
            self.sendCompletionNotification()
        }
        
        task.expirationHandler = {
            queue.cancelAllOperations()
        }
        
        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
        }
        
        queue.addOperation(operation)
    }
    
    // Ergänze diese Methoden entsprechend dem Aufbau deiner App
    @MainActor
    func fetchSavedDevices() throws -> [FlowerDevice] {
        let fetchDescriptor = FetchDescriptor<FlowerDevice>()

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
            return result
        } catch {
            print(error.localizedDescription)
            throw error
        }
    }
    
    func scanAndCollectData(for device: FlowerDevice, using ble: FlowerCareManager) async {
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?

            ble.startScanning(device: device)

            subscription = ble.sensorDataPublisher.sink { data in
                device.sensorData.append(data)
                subscription?.cancel()
                continuation.resume()
            }
        }
    }
    
    // Methode zum Senden einer lokalen Benachrichtigung
    func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Datenaktualisierung abgeschlossen"
        content.body = "Die Sensorendaten wurden erfolgreich aktualisiert."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
}

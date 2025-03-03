//
//  GrowGuardApp.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI
import SwiftData
import AppIntents

@main
struct GrowGuardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var showOnboarding = false
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FlowerDevice.self,
            SensorData.self,
            OptimalRange.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            if showOnboarding {
                OnbordingView()
            } else {
                ContentView()
            }
        }
        .modelContainer(sharedModelContainer)
    }
    
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: MyAppIntent(),
                phrases: ["Do something with my app"]
            )
        ]
    }
}

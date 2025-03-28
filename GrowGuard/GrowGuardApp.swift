//
//  GrowGuardApp.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI
import SwiftData
import AppIntents

enum UserDefaultsKeys: String {
    case showOnboarding = "veit.pro.showOnboarding"
}

@main
struct GrowGuardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
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
            Group {
                MainNavigationView()
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

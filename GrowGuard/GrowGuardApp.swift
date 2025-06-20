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

    var body: some Scene {
        WindowGroup {
            Group {
                MainNavigationView()
            }
        }
        .modelContainer(DataService.sharedModelContainer)
        
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

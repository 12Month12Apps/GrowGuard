//
//  DataService.swift
//  GrowGuard
//
//  Created by Veit Progl on 05.06.24.
//

import Foundation
import SwiftData

class DataService {
    static var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FlowerDevice.self
        ])
        
        let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isRunningTests)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}

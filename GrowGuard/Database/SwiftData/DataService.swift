//
//  DataService.swift
//  GrowGuard
//
//  Created by Veit Progl on 05.06.24.
//

import Foundation
import SQLite3
import SwiftData

class DataService {
    @MainActor
    static var sharedModelContainer: ModelContainer = {
        do {
            return try setupModelContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    static func setupModelContainer(for versionedSchema: VersionedSchema.Type = SchemaLatest.self, url: URL? = nil, rollback: Bool = false) throws -> ModelContainer {
        do {
            let schema = Schema(versionedSchema: versionedSchema)
            
            var config: ModelConfiguration
            if let url = url {
                config = ModelConfiguration(schema: schema, url: url)
            } else {
                config = ModelConfiguration(schema: schema)
            }
            
            let container = try ModelContainer(
                for: schema,
                migrationPlan: rollback ? RollbackMigrationPlan.self : MigrationPlan.self,
                configurations: [config]
            )
            
            return container
        } catch {
            throw ModelError.setup(error: error)
        }
    }

    enum ModelError: LocalizedError {
        case setup(error: Error)
    }
    
    // Hinweis: Für SensorData oder weitere Modelle kann analog vorgegangen werden,
    // indem entsprechende Structs definiert und SQL-Queries angepasst werden.
}

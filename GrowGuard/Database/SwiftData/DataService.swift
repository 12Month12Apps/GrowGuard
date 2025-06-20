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
    
    struct LegacyFlowerDevice {
        let uuid: String
        let name: String
        // ggf. weitere Felder
    }
    
    static func migrateLegacyStoreIfNeeded(at url: URL) -> [LegacyFlowerDevice] {
        var result: [LegacyFlowerDevice] = []
        var db: OpaquePointer? = nil
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }
            let query = "SELECT ZUUID, ZNAME FROM ZFLOWERDEVICE" // evtl. Spaltennamen/Z-Tabelle anpassen!
            var stmt: OpaquePointer? = nil
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let uuidCStr = sqlite3_column_text(stmt, 0),
                       let nameCStr = sqlite3_column_text(stmt, 1) {
                        let uuid = String(cString: uuidCStr)
                        let name = String(cString: nameCStr)
                        result.append(LegacyFlowerDevice(uuid: uuid, name: name))
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
        return result
    }
    
    // Hinweis: Für SensorData oder weitere Modelle kann analog vorgegangen werden,
    // indem entsprechende Structs definiert und SQL-Queries angepasst werden.
}

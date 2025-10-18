//
//  FlowerSearch.swift
//  GrowGuard
//
//  Created by veitprogl on 25.05.25.
//

import GRDB
import Foundation

struct FlowerSearch {
    func seach(flower: String) async throws -> [Species] {
        let dbQueue = try databaseQueue()
        do {
            return try await dbQueue.read { db in
                let request = SQLRequest<Species>(
                    sql: """
                        SELECT DISTINCT
                            flowers.id,
                            flowers.scientific_name,
                            flowers.url_image,
                            families.name AS family_name,
                            CAST(ROUND(water_intensity.plant_factor_min * 100.0, 0) AS INTEGER) AS min_moisture,
                            CAST(ROUND(water_intensity.plant_factor_max * 100.0, 0) AS INTEGER) AS max_moisture,
                            GROUP_CONCAT(DISTINCT common_names.name, '|') AS common_names
                        FROM flowers
                        LEFT JOIN families ON families.id = flowers.family_id
                        LEFT JOIN water_categories ON water_categories.id = flowers.water_category_id
                        LEFT JOIN water_intensity ON water_intensity.id = water_categories.intensity_id
                        LEFT JOIN flower_common_names ON flower_common_names.flower_id = flowers.id
                        LEFT JOIN common_names ON common_names.id = flower_common_names.common_name_id
                        WHERE flowers.scientific_name LIKE :search
                           OR common_names.name LIKE :search
                        GROUP BY flowers.id
                        ORDER BY flowers.scientific_name
                        LIMIT 10
                    """,
                    arguments: ["search": "%\(flower)%"]
                )
                
                return try request.fetchAll(db)
            }
        } catch {
            print("Error reading from database: \(error)")
            
            throw error
        }
    }
    
    func seachFamiles() async throws {
        let dbQueue = try databaseQueue()
        do {
            try await dbQueue.read { db in
                let families = try Row
                    .fetchAll(db, sql: "SELECT name FROM families WHERE name IS NOT NULL ORDER BY name")
                    .compactMap { $0["name"] as? String }
                print(families)
            }
        } catch {
            print("Error reading from database: \(error)")
            
            throw error
        }
    }
}

private extension FlowerSearch {
    func databaseQueue() throws -> DatabaseQueue {
        let dbURL = try writableDatabaseURL()
        var dbConfig = Configuration()
        dbConfig.journalMode = .wal
        
        // The database lives in Application Support so SQLite can create WAL files freely.
        return try DatabaseQueue(path: dbURL.path, configuration: dbConfig)
    }
    
    func writableDatabaseURL() throws -> URL {
        guard let bundledURL = Bundle.main.url(forResource: "flower", withExtension: "db") else {
            fatalError("DB not found in bundle")
        }
        
        let fileManager = FileManager.default
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let databaseDirectory = supportDirectory.appendingPathComponent("Database", isDirectory: true)
        let writableURL = databaseDirectory.appendingPathComponent("flower.db", isDirectory: false)
        
        if !fileManager.fileExists(atPath: databaseDirectory.path) {
            try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }
        
        if !fileManager.fileExists(atPath: writableURL.path) {
            try fileManager.copyItem(at: bundledURL, to: writableURL)
        }
        
        return writableURL
    }
}

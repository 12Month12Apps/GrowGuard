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
        guard let dbURL = Bundle.main.url(forResource: "flower", withExtension: "db") else {
            fatalError("DB not found in bundle")
        }
        
        var dbConfig = Configuration()
        dbConfig.readonly = true
        
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: dbConfig)
        do {
            return try await dbQueue.read { db in
                let foundSpecies = try Species
                    .filter(Species.Columns.scientificName.like("%\(flower)%"))
                    .limit(10)
                    .fetchAll(db)
                                
                return foundSpecies
            }
        } catch {
            print("Error reading from database: \(error)")
            
            throw error
        }
    }
    
    func seachFamiles() async throws {
        guard let dbURL = Bundle.main.url(forResource: "flower", withExtension: "db") else {
            fatalError("DB not found in bundle")
        }
        
        var dbConfig = Configuration()
        dbConfig.readonly = true
        
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: dbConfig)
        do {
//            try await dbQueue.read { db in
//                let families = try String.fetchAll(db, sql: "SELECT DISTINCT family FROM species")
//                print(families)
//            }
            try await dbQueue.read { db in
                let families = try Row
                    .fetchAll(db, sql: "SELECT DISTINCT family FROM species WHERE family IS NOT NULL")
                    .compactMap { $0["family"] as? String }
                print(families)
            }
        } catch {
            print("Error reading from database: \(error)")
            
            throw error
        }
    }
}

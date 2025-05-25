//
//  FlowerSearch.swift
//  GrowGuard
//
//  Created by veitprogl on 25.05.25.
//

import GRDB
import Foundation

struct FlowerSearch {
    func seach() {
        Task {
            guard let dbURL = Bundle.main.url(forResource: "flower", withExtension: "db") else {
                fatalError("DB not found in bundle")
            }
            
            var dbConfig = Configuration()
            dbConfig.readonly = true
            
            let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: dbConfig)
            do {
                try dbQueue.read { db in
                    let player = try Species.find(db, id: 1)
                    
                    let bestPlayers = try Species
                        .limit(10)
                        .fetchAll(db)
                    
                    print("Best players: \(bestPlayers)")
                }
            } catch {
                print("Error reading from database: \(error)")
            }
        }
    }
}

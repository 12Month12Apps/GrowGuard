//
//  SchemaLatest.swift
//  GrowGuard
//
//  Created by veitprogl on 19.06.25.
//

import Foundation
import SwiftData

typealias SchemaLatest = SchemaV2

// MARK: Models

typealias FlowerDevice = SchemaLatest.FlowerDevice
typealias OptimalRange = SchemaLatest.OptimalRange
typealias PotSize = SchemaLatest.PotSize


enum MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }
    
    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }
    
    // MARK: Migration Stages
    
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let devices = try context.fetch(FetchDescriptor<SchemaV2.FlowerDevice>())
            
            for device in devices {
                device.potSize = SchemaV2.PotSize(width: 0, height: 0, volume: 0, device: device)
            }
            
            try context.save()
        }
    )
}

enum RollbackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV2.self, SchemaV1.self]
    }
    
    static var stages: [MigrationStage] {
        [migrateV2toV1]
    }
    
    // MARK: Migration Stages
    
    static let migrateV2toV1 = MigrationStage.custom(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV1.self,
        willMigrate: nil,
        didMigrate: nil
    )
}

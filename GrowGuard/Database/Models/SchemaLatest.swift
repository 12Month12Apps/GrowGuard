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
//        []
    }
    
    // MARK: Migration Stages
    
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            // Alle FlowerDevices aus V1 abfragen
            let oldDevices = try context.fetch(FetchDescriptor<SchemaV1.FlowerDevice>())
            for old in oldDevices {
                // Neues Device in V2 anlegen und Felder übertragen
                let newDevice = SchemaV2.FlowerDevice(
                    name: old.name,
                    uuid: old.uuid
                )
                newDevice.added = old.added
                newDevice.lastUpdate = old.lastUpdate
                newDevice.sensorData = old.sensorData
                newDevice.optimalRange = SchemaV2.OptimalRange(
                    minTemperature: old.optimalRange.minTemperature,
                    minBrightness: old.optimalRange.minBrightness,
                    minMoisture: old.optimalRange.minMoisture,
                    minConductivity: old.optimalRange.minConductivity,
                    maxTemperature: old.optimalRange.maxTemperature,
                    maxBrightness: old.optimalRange.maxBrightness,
                    maxMoisture: old.optimalRange.maxMoisture,
                    maxConductivity: old.optimalRange.maxConductivity
                )
                newDevice.battery = old.battery
                newDevice.firmware = old.firmware
                newDevice.isSensor = old.isSensor

                // Neues Device speichern
                context.insert(newDevice)
            }
        },
        didMigrate: nil
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


//
//  Item.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import Foundation
import SwiftData
import CoreBluetooth

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    
    static var models: [any PersistentModel.Type] {
        [OptimalRange.self, PotSize.self, FlowerDevice.self, PotSize.self]
    }
}

extension SchemaV2 {
    @Model
    class OptimalRange {
        var minTemperature: Double
        var minBrightness: UInt32
        var minMoisture: UInt8
        var minConductivity: UInt16
        
        var maxTemperature: Double
        var maxBrightness: UInt32
        var maxMoisture: UInt8
        var maxConductivity: UInt16
        
        init(minTemperature: Double, minBrightness: UInt32, minMoisture: UInt8, minConductivity: UInt16,
             maxTemperature: Double, maxBrightness: UInt32, maxMoisture: UInt8, maxConductivity: UInt16) {
            self.minTemperature = minTemperature
            self.minBrightness = minBrightness
            self.minMoisture = minMoisture
            self.minConductivity = minConductivity
            self.maxTemperature = maxTemperature
            self.maxBrightness = maxBrightness
            self.maxMoisture = maxMoisture
            self.maxConductivity = maxConductivity
        }
    }
    
    @Model
    class PotSize {
        var width: Double
        var height: Double
        var volume: Double
        var device: FlowerDevice?
        
        init(width: Double, height: Double, volume: Double, device: FlowerDevice?) {
            self.width = width
            self.height = height
            self.volume = volume
        }
    }
    
    @Model
    final class FlowerDevice {
        var added: Date
        var lastUpdate: Date
        @Attribute(.unique) var uuid: String
        var name: String
        @Relationship(deleteRule: .nullify, inverse: \SensorData.device) var sensorData: [SensorData]
        var optimalRange: OptimalRange
        var battery: Int = 0
        var firmware: String = ""
        var isSensor = false
        var potSize: PotSize = PotSize(width: 0, height: 0, volume: 0, device: nil)
        
        init(added: Date, lastUpdate: Date, peripheral: CBPeripheral) {
            self.added = added
            self.lastUpdate = lastUpdate
            self.uuid = peripheral.identifier.uuidString
            self.name = peripheral.name ?? ""
            self.sensorData = []
            self.optimalRange = OptimalRange(minTemperature: 0, minBrightness: 0, minMoisture: 70, minConductivity: 0, maxTemperature: 0, maxBrightness: 0, maxMoisture: 0, maxConductivity: 0)
        }
        
        init(name: String, uuid: String) {
            self.added = Date()
            self.lastUpdate = Date()
            self.uuid = uuid
            self.name = name
            self.sensorData = []
            self.optimalRange = OptimalRange(minTemperature: 0, minBrightness: 0, minMoisture: 70, minConductivity: 0, maxTemperature: 0, maxBrightness: 0, maxMoisture: 0, maxConductivity: 0)
        }
    }
}

//
//  Item.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import Foundation
import SwiftData
import CoreBluetooth

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
final class FlowerDevice {
    var added: Date
    var lastUpdate: Date
    var uuid: String
    var name: String
    var sensorData: [SensorData]
    var optimalRange: OptimalRange
    
    init(added: Date, lastUpdate: Date, peripheral: CBPeripheral) {
        self.added = added
        self.lastUpdate = lastUpdate
        self.uuid = peripheral.identifier.uuidString
        self.name = peripheral.name ?? ""
        self.sensorData = []
        self.optimalRange = OptimalRange(minTemperature: 0, minBrightness: 0, minMoisture: 0, minConductivity: 0, maxTemperature: 0, maxBrightness: 0, maxMoisture: 0, maxConductivity: 0)
    }
}

//
//  SensorData.swift
//  GrowGuard
//
//  Created by Veit Progl on 23.06.24.
//
import SwiftData
import Foundation

@Model
class SensorData {
    var temperature: Double
    var brightness: UInt32
    var moisture: UInt8
    var conductivity: UInt16
    var date: Date
    
    init(temperature: Double, brightness: UInt32, moisture: UInt8, conductivity: UInt16, date: Date) {
        self.temperature = temperature
        self.brightness = brightness
        self.moisture = moisture
        self.conductivity = conductivity
        self.date = date
    }
}

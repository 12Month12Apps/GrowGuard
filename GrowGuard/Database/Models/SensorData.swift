//
//  SensorData.swift
//  GrowGuard
//
//  Created by Veit Progl on 23.06.24.
//
import Foundation

class SensorDataTemp {
    var temperature: Double
    var brightness: UInt32
    var moisture: UInt8
    var conductivity: UInt16
    var date: Date
    var device: FlowerDevice?
    
    init(temperature: Double, brightness: UInt32, moisture: UInt8, conductivity: UInt16, date: Date, device: FlowerDevice?) {
        self.temperature = temperature
        self.brightness = brightness
        self.moisture = moisture
        self.conductivity = conductivity
        self.date = date
        self.device = device
    }
}

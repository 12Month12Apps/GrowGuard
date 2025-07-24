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
    var device: String?
    
    init(temperature: Double, brightness: UInt32, moisture: UInt8, conductivity: UInt16, date: Date, deviceUUID: String?) {
        self.temperature = temperature
        self.brightness = brightness
        self.moisture = moisture
        self.conductivity = conductivity
        self.date = date
        self.device = deviceUUID
    }
}

extension SensorData {
    func toTemp() -> SensorDataTemp? {
        // Ensure we're executing on the correct context queue
        guard let context = managedObjectContext else {
            print("SensorData.toTemp(): No managed object context - cannot create temp object")
            return nil
        }
        
        var result: SensorDataTemp?
        
        // Perform all Core Data operations on the context's queue
        context.performAndWait {
            // Ensure we have a valid device relationship with UUID
            guard let device = self.device,
                  let deviceUUID = device.uuid,
                  !deviceUUID.isEmpty else {
                print("SensorData.toTemp(): Missing device relationship or device UUID - cannot create temp object")
                return
            }
            
            // Validate numeric ranges to prevent crashes
            let safeBrightness = max(0, UInt32(self.brightness))
            let safeMoisture = max(0, min(255, UInt8(self.moisture)))
            let safeConductivity = max(0, UInt16(self.conductivity))
            
            result = SensorDataTemp(
                temperature: self.temperature,
                brightness: safeBrightness,
                moisture: safeMoisture,
                conductivity: safeConductivity,
                date: self.date ?? Date(),
                deviceUUID: deviceUUID
            )
        }
        
        return result
    }
}

extension SensorDataTemp {
    func toDTO() -> SensorDataDTO? {
        guard let deviceUUID = device, !deviceUUID.isEmpty else {
            print("SensorDataTemp.toDTO(): Missing or empty deviceUUID - cannot create DTO")
            return nil
        }
        
        // Validate numeric ranges to prevent overflow crashes
        let safeBrightness = max(Int32.min, min(Int32.max, Int32(brightness)))
        let safeMoisture = max(Int16.min, min(Int16.max, Int16(moisture)))
        let safeConductivity = max(Int16.min, min(Int16.max, Int16(conductivity)))
        
        return SensorDataDTO(
            temperature: temperature,
            brightness: safeBrightness,
            moisture: safeMoisture,
            conductivity: safeConductivity,
            date: date,
            deviceUUID: deviceUUID
        )
    }
}

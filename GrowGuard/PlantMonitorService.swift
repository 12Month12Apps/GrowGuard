//
//  ContentView.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.02.25.
//

import Foundation
import CoreBluetooth
import Combine
import NotificationCenter
import CoreData

class PlantMonitorService {
    static let shared = PlantMonitorService()
    private let repositoryManager = RepositoryManager.shared
    
    // Calculate drying rate and predict next watering date
    func predictNextWatering(for device: FlowerDeviceDTO) async throws -> Date? {
        // Get recent sensor data using repository
        let sortedData = try await repositoryManager.sensorDataRepository.getRecentSensorData(for: device.uuid, limit: 10)
        // Need at least 3 data points for a reasonable prediction
        guard sortedData.count >= 3 else { return nil }

        // Get last 10 readings or whatever is available
        let recentReadings = Array(sortedData.suffix(min(10, sortedData.count)))
        
        // Calculate average moisture loss per day
        var moistureLossRate: Double = 0
        var previousReading: SensorDataDTO? = nil
        
        for reading in recentReadings {
            if let previous = previousReading {
                let timeDiffInDays = reading.date.timeIntervalSince(previous.date) / (24 * 60 * 60)
                let moistureDiff = Double(previous.moisture) - Double(reading.moisture)
                
                // Only consider readings where moisture decreased
                if moistureDiff > 0 && timeDiffInDays > 0 {
                    // Moisture points lost per day
                    let rate = moistureDiff / timeDiffInDays
                    moistureLossRate += rate
                }
            }
            previousReading = reading
        }
        
        // Calculate average (avoid division by zero)
        let dataPointCount = recentReadings.count - 1
        if dataPointCount > 0 {
            moistureLossRate /= Double(dataPointCount)
        }
        
        // Predict days until minimum moisture threshold is reached
        if moistureLossRate > 0, let latestReading = recentReadings.last {
            let currentMoisture = Double(latestReading.moisture)
            guard let optimalRange = device.optimalRange else { return nil }
            let minMoisture = Double(optimalRange.minMoisture)
            let daysUntilWatering = (currentMoisture - minMoisture) / moistureLossRate
            
            let secondsUntilWatering = daysUntilWatering * 24 * 60 * 60
            return Date(timeIntervalSinceNow: secondsUntilWatering)
        }
        
        return nil
    }
    
    // Modify your existing checkDeviceStatus method to include prediction
    func checkDeviceStatus(device: FlowerDeviceDTO) async throws {
        let sortedData = try await repositoryManager.sensorDataRepository.getRecentSensorData(for: device.uuid, limit: 10)
        guard let latestData = sortedData.last else { return }
        guard let optimalRange = device.optimalRange else { return }
        
        // Check if moisture level is below minimum threshold
        if latestData.moisture < optimalRange.minMoisture {
            scheduleWateringReminder(for: device)
        } else {
            // Predict and schedule future notification if not urgent
            try await schedulePreemptiveWateringReminder(for: device)
        }
    }
    
    // New method to schedule predictive reminders
    private func schedulePreemptiveWateringReminder(for device: FlowerDeviceDTO) async throws {
        guard let nextWateringDate = try await predictNextWatering(for: device) else { return }
        
        // Only schedule if prediction is within next week (avoid inaccurate long-term predictions)
        let oneWeekFromNow = Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        guard nextWateringDate < oneWeekFromNow else { return }
        
        // Schedule a notification one day before predicted watering need
        let notificationDate = nextWateringDate.addingTimeInterval(-24 * 60 * 60)
        
        // Only schedule if notification would be in the future
        guard notificationDate > Date() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "\(device.name) Will Need Water Soon"
        content.body = "Based on current moisture trends, your plant will need watering tomorrow."
        content.sound = .default
        content.categoryIdentifier = "WATERING_REMINDER"
        
        // Create date components for the trigger
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: notificationDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        // Create a unique identifier for each notification
        let identifier = "watering-prediction-\(device.uuid)-\(Date().timeIntervalSince1970)"
        
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling prediction notification: \(error)")
            }
        }
    }

    // Add this method to your PlantMonitorService
    func validateSensorData(_ data: SensorDataTemp, deviceUUID: String) async throws -> SensorDataDTO? {
        var validatedData = data
        
       // Define reasonable sensor ranges
       let validMoistureRange = 0...100
       let validTemperatureRange = -10...60
       let validBrightnessRange = 0...100000
       
       // Check if values are in valid ranges
       if !validMoistureRange.contains(Int(data.moisture)) {
           validatedData.moisture = UInt8(max(validMoistureRange.lowerBound, min(Int(data.moisture), validMoistureRange.upperBound)))
       }
       
       if !validTemperatureRange.contains(Int(data.temperature)) {
           validatedData.temperature = Double(max(validTemperatureRange.lowerBound, min(Int(data.temperature), validTemperatureRange.upperBound)))
       }
       
       if !validBrightnessRange.contains(Int(data.brightness)) {
           validatedData.brightness = UInt32(max(validBrightnessRange.lowerBound, min(Int(data.brightness), validBrightnessRange.upperBound)))
       }
        
        print(validatedData.moisture, validatedData.brightness, validatedData.temperature)
        
        let sensorDataDTO = SensorDataDTO(
            temperature: validatedData.temperature,
            brightness: Int32(validatedData.brightness),
            moisture: Int16(validatedData.moisture),
            conductivity: Int16(validatedData.conductivity),
            date: validatedData.date,
            deviceUUID: deviceUUID
        )
        
        try await repositoryManager.sensorDataRepository.saveSensorData(sensorDataDTO)
        return sensorDataDTO
    }
    
    // Add this method to your PlantMonitorService
    func validateHistoricSensorData(_ data: HistoricalSensorData, deviceUUID: String) async throws -> SensorDataDTO? {
        var validatedData = data
        
       // Define reasonable sensor ranges
       let validMoistureRange = 0...100
       let validTemperatureRange = -10...60
       let validBrightnessRange = 0...100000
       
       // Check if values are in valid ranges
       if !validMoistureRange.contains(Int(data.moisture)) {
           validatedData.moisture = UInt8(max(validMoistureRange.lowerBound, min(Int(data.moisture), validMoistureRange.upperBound)))
       }
       
       if !validTemperatureRange.contains(Int(data.temperature)) {
           validatedData.temperature = Double(max(validTemperatureRange.lowerBound, min(Int(data.temperature), validTemperatureRange.upperBound)))
       }
       
       if !validBrightnessRange.contains(Int(data.brightness)) {
           validatedData.brightness = UInt32(max(validBrightnessRange.lowerBound, min(Int(data.brightness), validBrightnessRange.upperBound)))
       }
        
        print(validatedData.moisture, validatedData.brightness, validatedData.temperature)
        
        let sensorDataDTO = SensorDataDTO(
            temperature: validatedData.temperature,
            brightness: Int32(validatedData.brightness),
            moisture: Int16(validatedData.moisture),
            conductivity: Int16(validatedData.conductivity),
            date: validatedData.date,
            deviceUUID: deviceUUID
        )
        
        try await repositoryManager.sensorDataRepository.saveSensorData(sensorDataDTO)
        return sensorDataDTO
    }
    
    private func scheduleWateringReminder(for device: FlowerDeviceDTO) {
        let content = UNMutableNotificationContent()
        content.title = "Water Your \(device.name)"
        content.body = "Moisture level is below optimal range. Time to water your plant!"
        content.sound = .default
        content.categoryIdentifier = "WATERING_REMINDER"
        
        // Create a unique identifier for each notification
        let identifier = "watering-\(device.uuid)-\(Date().timeIntervalSince1970)"
        
        // Create immediate trigger
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            }
        }
    }
}

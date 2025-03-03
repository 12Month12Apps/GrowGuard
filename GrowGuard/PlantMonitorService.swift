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

class PlantMonitorService {
    static let shared = PlantMonitorService()
    
    // Calculate drying rate and predict next watering date
    func predictNextWatering(for device: FlowerDevice) -> Date? {
        // Need at least 3 data points for a reasonable prediction
        guard device.sensorData.count >= 3 else { return nil }
        
        // Sort by date to ensure chronological order
        let sortedData = device.sensorData.sorted { $0.date < $1.date }
        
        // Get last 10 readings or whatever is available
        let recentReadings = Array(sortedData.suffix(min(10, sortedData.count)))
        
        // Calculate average moisture loss per day
        var moistureLossRate: Double = 0
        var previousReading: SensorData? = nil
        
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
            let minMoisture = Double(device.optimalRange.minMoisture)
            let daysUntilWatering = (currentMoisture - minMoisture) / moistureLossRate
            
            // If prediction is reasonably in the future (not past or immediate)
//            if daysUntilWatering > 0.5 {
                let secondsUntilWatering = daysUntilWatering * 24 * 60 * 60
                return Date(timeIntervalSinceNow: secondsUntilWatering)
//            }
        }
        
        return nil
    }
    
    // Modify your existing checkDeviceStatus method to include prediction
    func checkDeviceStatus(device: FlowerDevice) {
        guard let latestData = device.sensorData.last else { return }
        let minMoisture = device.optimalRange.minMoisture
        
        // Check if moisture level is below minimum threshold
        if latestData.moisture < minMoisture {
            scheduleWateringReminder(for: device)
        } else {
            // Predict and schedule future notification if not urgent
            schedulePreemptiveWateringReminder(for: device)
        }
    }
    
    // New method to schedule predictive reminders
    private func schedulePreemptiveWateringReminder(for device: FlowerDevice) {
        guard let nextWateringDate = predictNextWatering(for: device) else { return }
        
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
    func validateSensorData(_ data: SensorData) -> SensorData? {
        var isValid = true
        var validatedData = data
        
       // Define reasonable sensor ranges
       let validMoistureRange = 0...100
       let validTemperatureRange = -10...60
       let validBrightnessRange = 0...100000
       
       // Check if values are in valid ranges
       if !validMoistureRange.contains(Int(data.moisture)) {
           isValid = false
           // Option 1: Return nil to reject entirely
           // Option 2: Clamp to valid range
           validatedData.moisture = UInt8(max(validMoistureRange.lowerBound, min(Int(data.moisture), validMoistureRange.upperBound)))
       }
       
       if !validTemperatureRange.contains(Int(data.temperature)) {
           isValid = false
           validatedData.temperature = Double(max(validTemperatureRange.lowerBound, min(Int(data.temperature), validTemperatureRange.upperBound)))
       }
       
       if !validBrightnessRange.contains(Int(data.brightness)) {
           isValid = false
           validatedData.brightness = UInt32(max(validBrightnessRange.lowerBound, min(Int(data.brightness), validBrightnessRange.upperBound)))
       }
       
//        // Advanced: Check for sudden jumps from previous readings
//        if let lastReading = getLastReading(for: data.deviceUUID) {
//            let maxTemperatureJump = 10.0 // 10 degrees max change between readings
//            if abs(data.temperature - lastReading.temperature) > maxTemperatureJump {
//                isValid = false
//                // Either reject or smooth the value
//            }
//            
//            // Similar checks for other sensors
//        }
//        
//        // Option 1: Return nil if any value was invalid
       return isValid ? validatedData : nil
//        
//        // Option 2: Return corrected values
        // return validatedData
    }
    
    private func scheduleWateringReminder(for device: FlowerDevice) {
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

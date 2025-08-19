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
import UserNotifications

// MARK: - Supporting Types

struct WateringPrediction {
    let deviceUUID: String
    let predictedDate: Date
    let confidence: Double // 0.0 to 1.0
    let currentMoisture: Double
    let targetMoisture: Double
    let dryingRatePerDay: Double
    let basedOnDataPoints: Int
    let lastWateringEvent: Date?
    
    var daysUntilWatering: Double {
        return max(0, predictedDate.timeIntervalSinceNow / (24 * 60 * 60))
    }
    
    var isUrgent: Bool {
        return daysUntilWatering < 1.0
    }
    
    var confidenceLevel: String {
        switch confidence {
        case 0.8...1.0: return "High"
        case 0.5..<0.8: return "Medium"
        default: return "Low"
        }
    }
}

struct WateringEventDTO: Identifiable, Hashable {
    let id: String
    let deviceUUID: String
    let wateringDate: Date
    let waterAmount: Double?
    let source: WateringSource
    let notes: String?
    
    init(
        id: String = UUID().uuidString,
        deviceUUID: String,
        wateringDate: Date = Date(),
        waterAmount: Double? = nil,
        source: WateringSource = .manual,
        notes: String? = nil
    ) {
        self.id = id
        self.deviceUUID = deviceUUID
        self.wateringDate = wateringDate
        self.waterAmount = waterAmount
        self.source = source
        self.notes = notes
    }
}

enum WateringSource: String, CaseIterable {
    case manual = "manual"
    case notification = "notification"
    case automatic = "automatic"
    case estimated = "estimated"
}

enum NotificationType {
    case immediate(device: FlowerDeviceDTO)
    case predictive(device: FlowerDeviceDTO, wateringDate: Date)
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

class PlantMonitorService {
    static let shared = PlantMonitorService()
    private let repositoryManager = RepositoryManager.shared
    // Internal services - integrated into this class
    
    /// Gets watering prediction using the advanced prediction algorithm
    func predictNextWatering(for device: FlowerDeviceDTO) async throws -> WateringPrediction? {
        // Get the most recent sensor data - try both sources to ensure we have the latest
        let recentSensorData = try await repositoryManager.sensorDataRepository.getRecentSensorData(for: device.uuid, limit: 50)
        
        // Also get today's data to ensure we have the absolute latest reading
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let todaysData = try await repositoryManager.sensorDataRepository.getSensorDataInDateRange(
            for: device.uuid,
            startDate: startOfDay,
            endDate: now
        )
        
        // Combine and deduplicate data, prioritizing today's data
        var allData = recentSensorData
        for todayReading in todaysData {
            // Only add if not already present in recent data
            if !recentSensorData.contains(where: { abs($0.date.timeIntervalSince(todayReading.date)) < 60 }) {
                allData.append(todayReading)
            }
        }
        
        // Sort by date to ensure correct order (oldest to newest)
        let sensorData = allData.sorted { $0.date < $1.date }
        let wateringEvents = await detectWateringEvents(for: device.uuid)
        
        guard sensorData.count >= 5 else {
            print("⚠️ PlantMonitorService: Insufficient data for prediction (need 5+, have \(sensorData.count))")
            return nil
        }
        
        guard let optimalRange = device.optimalRange else {
            print("⚠️ PlantMonitorService: No optimal range set for device")
            return nil
        }
        
        // Debug logging for moisture discrepancy
        if let latestData = sensorData.last {
            print("🔍 PlantMonitorService: Latest sensor data from prediction: \(latestData.moisture)% at \(latestData.date)")
        }
        if sensorData.count >= 2 {
            let secondLatest = sensorData[sensorData.count - 2]
            print("🔍 PlantMonitorService: Second latest sensor data: \(secondLatest.moisture)% at \(secondLatest.date)")
        }
        
        return try await generatePrediction(
            sensorData: sensorData,
            wateringEvents: wateringEvents,
            optimalRange: optimalRange,
            deviceUUID: device.uuid
        )
    }
    
    /// Checks device status and schedules appropriate notifications
    func checkDeviceStatus(device: FlowerDeviceDTO) async throws {
        let sortedData = try await repositoryManager.sensorDataRepository.getRecentSensorData(for: device.uuid, limit: 10)
        guard let latestData = sortedData.last else {
            print("⚠️ PlantMonitorService: No sensor data available for device \(device.name)")
            return
        }
        guard let optimalRange = device.optimalRange else {
            print("⚠️ PlantMonitorService: No optimal range set for device \(device.name)")
            return
        }
        
        let currentMoisture = latestData.moisture
        let minMoisture = optimalRange.minMoisture
        let maxMoisture = optimalRange.maxMoisture
        
        print("📊 PlantMonitorService: Checking \(device.name)")
        print("   Current moisture: \(currentMoisture)%")
        print("   Optimal range: \(minMoisture)% - \(maxMoisture)%")
        print("   Min threshold (watering needed below): \(minMoisture)%")
        
        // Check if immediate watering is needed (only if below minimum threshold)
        if currentMoisture < minMoisture {
            print("🚨 PlantMonitorService: Immediate watering needed for \(device.name)")
            print("   Reason: Current \(currentMoisture)% is below minimum threshold \(minMoisture)%")
            await scheduleImmediateNotification(for: device)
        } else if currentMoisture >= minMoisture && currentMoisture <= maxMoisture {
            print("✅ PlantMonitorService: \(device.name) is within optimal range (\(minMoisture)%-\(maxMoisture)%)")
            // Plant is within optimal range - no immediate watering needed, but check predictions
            do {
                if let prediction = try await predictNextWatering(for: device) {
                    await handlePredictiveNotification(device: device, prediction: prediction)
                } else {
                    print("📈 PlantMonitorService: Could not generate prediction for \(device.name)")
                }
            } catch {
                print("❌ PlantMonitorService: Prediction failed for \(device.name): \(error)")
            }
        } else {
            // Plant is above optimal range - no watering needed
            print("💧 PlantMonitorService: \(device.name) is above optimal range (\(currentMoisture)% > \(maxMoisture)%) - no watering needed")
            // Cancel any existing notifications since plant is well-watered
            await cancelNotifications(for: device.uuid)
        }
    }
    
    /// Handles predictive notification scheduling based on prediction confidence and timing
    private func handlePredictiveNotification(device: FlowerDeviceDTO, prediction: WateringPrediction) async {
        let daysUntilWatering = prediction.daysUntilWatering
        let confidence = prediction.confidence
        
        print("📈 PlantMonitorService: Prediction for \(device.name) - \(daysUntilWatering.rounded(toPlaces: 1)) days, \(confidence.rounded(toPlaces: 2)) confidence")
        
        // Only schedule notifications for predictions within reasonable timeframe and confidence
        guard daysUntilWatering <= 7 && confidence >= 0.4 else {
            print("⚠️ PlantMonitorService: Skipping notification - prediction too far out or low confidence")
            return
        }
        
        // Schedule predictive notification
        await schedulePredictiveNotification(for: device, wateringDate: prediction.predictedDate)
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
       // Define realistic sensor ranges for FlowerCare devices
       let validMoistureRange = 0...100
       let validTemperatureRange = -20.0...70.0  // More realistic temperature range
       let validBrightnessRange = 0...100000     // Allow up to 100k lux for extreme sunlight
       let validConductivityRange = 0...10000    // Extended range for various soil types
       
       // Check for invalid values and REJECT the entire entry if any value is invalid
       if !validMoistureRange.contains(Int(data.moisture)) ||
          !validTemperatureRange.contains(data.temperature) ||
          !validBrightnessRange.contains(Int(data.brightness)) ||
          !validConductivityRange.contains(Int(data.conductivity)) {
           
           print("🚨 REJECTING invalid historic data - temp=\(data.temperature)°C, moisture=\(data.moisture)%, conductivity=\(data.conductivity)µS/cm, brightness=\(data.brightness)lx")
           return nil // Don't save invalid data at all
       }
        
        print("✅ Valid data:", data.moisture, data.brightness, data.temperature)
        
        let sensorDataDTO = SensorDataDTO(
            temperature: data.temperature,
            brightness: Int32(data.brightness),
            moisture: Int16(data.moisture),
            conductivity: Int16(data.conductivity),
            date: data.date,
            deviceUUID: deviceUUID
        )
        
        try await repositoryManager.sensorDataRepository.saveSensorData(sensorDataDTO)
        return sensorDataDTO
    }
    
    /// Clean invalid sensor data from the database
    /// Removes entries with impossible values like moisture > 100%, negative conductivity, extreme temperatures, etc.
    /// Returns the number of entries deleted
    func cleanupInvalidSensorData() async throws -> Int {
        let deletedCount = try await repositoryManager.sensorDataRepository.deleteInvalidSensorData()
        
        // Post notification to refresh UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseCleanupCompleted"), object: deletedCount)
        }
        
        return deletedCount
    }
    
    /// Get statistics about invalid data in the database without deleting it
    func getInvalidDataStatistics() async throws -> (totalEntries: Int, invalidEntries: Int) {
        // This could be optimized by adding a count-only method to the repository
        let allData = try await repositoryManager.sensorDataRepository.getAllSensorData()
        let totalEntries = allData.count
        
        let invalidEntries = allData.filter { data in
            data.moisture < 0 || data.moisture > 100 ||
            data.temperature < -30 || data.temperature > 80 ||
            data.conductivity < 0 || data.conductivity > 10000 ||
            data.brightness < 0 || data.brightness > 100000
        }.count
        
        return (totalEntries: totalEntries, invalidEntries: invalidEntries)
    }
    
    /// Records a watering event (when user waters plant or marks as watered)
    func recordWateringEvent(for deviceUUID: String, source: WateringSource = .manual, waterAmount: Double? = nil, notes: String? = nil) async {
        let wateringEvent = WateringEventDTO(
            deviceUUID: deviceUUID,
            wateringDate: Date(),
            waterAmount: waterAmount,
            source: source,
            notes: notes
        )
        
        // TODO: Save to WateringEventRepository when implemented
        print("💧 PlantMonitorService: Recorded watering event for device \(deviceUUID) (\(source.rawValue))")
        
        // Cancel any pending notifications for this device since it was just watered
        await cancelNotifications(for: deviceUUID)
    }
    
    /// Schedules daily check for all devices (to be called from background tasks)
    func performDailyDeviceCheck() async {
        do {
            let allDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
            let sensorDevices = allDevices.filter { $0.isSensor }
            
            print("🔄 PlantMonitorService: Performing daily check for \(sensorDevices.count) devices")
            
            for device in sensorDevices {
                do {
                    try await checkDeviceStatus(device: device)
                } catch {
                    print("❌ PlantMonitorService: Failed to check device \(device.name): \(error)")
                }
            }
        } catch {
            print("❌ PlantMonitorService: Failed to get devices for daily check: \(error)")
        }
    }
    
    // MARK: - Prediction Methods
    
    private func detectWateringEvents(for deviceUUID: String) async -> [WateringEventDTO] {
        do {
            let sensorData = try await repositoryManager.sensorDataRepository.getRecentSensorData(for: deviceUUID, limit: 100)
            if sensorData.count <= 2 { return [] }
            
            var detectedEvents: [WateringEventDTO] = []
            
            for i in 1..<sensorData.count {
                let current = sensorData[i]
                let previous = sensorData[i-1]
                
                // Look for significant moisture increases (>15% in <6 hours)
                let moistureIncrease = Double(current.moisture - previous.moisture)
                let timeInterval = current.date.timeIntervalSince(previous.date) / 3600 // hours
                
                if moistureIncrease > 15 && timeInterval < 6 {
                    let wateringEvent = WateringEventDTO(
                        deviceUUID: deviceUUID,
                        wateringDate: current.date,
                        source: .estimated,
                        notes: "Detected from \(moistureIncrease.rounded(toPlaces: 1))% moisture increase"
                    )
                    detectedEvents.append(wateringEvent)
                }
            }
            
            print("🔍 PlantMonitorService: Detected \(detectedEvents.count) potential watering events")
            return detectedEvents
        } catch {
            print("❌ PlantMonitorService: Failed to detect watering events: \(error)")
            return []
        }
    }
    
    private func generatePrediction(
        sensorData: [SensorDataDTO],
        wateringEvents: [WateringEventDTO],
        optimalRange: OptimalRangeDTO,
        deviceUUID: String
    ) async throws -> WateringPrediction {
        
        let currentMoisture = Double(sensorData.last?.moisture ?? 0)
        let minMoisture = Double(optimalRange.minMoisture)
        let maxMoisture = Double(optimalRange.maxMoisture)
        
        // Calculate drying rate considering watering events
        let dryingRate = calculateAdjustedDryingRate(sensorData: sensorData, wateringEvents: wateringEvents)
        
        // Calculate days until watering needed
        let daysUntilWatering: Double
        if currentMoisture > maxMoisture {
            // Plant is above optimal range - calculate when it will reach the maximum of optimal range
            daysUntilWatering = (currentMoisture - maxMoisture) / dryingRate
            print("🌿 PlantMonitorService: Plant is above optimal range, will reach max range in \(daysUntilWatering.rounded(toPlaces: 1)) days")
        } else {
            // Plant is within or below optimal range - calculate when it will reach minimum
            daysUntilWatering = max(0, (currentMoisture - minMoisture) / dryingRate)
        }
        let predictedDate = Date().addingTimeInterval(daysUntilWatering * 24 * 60 * 60)
        
        // Calculate confidence based on data quality
        let confidence = calculatePredictionConfidence(
            sensorData: sensorData,
            wateringEvents: wateringEvents,
            dryingRate: dryingRate
        )
        
        // Determine target moisture based on current state
        let targetMoisture = currentMoisture > maxMoisture ? maxMoisture : minMoisture
        
        print("🎯 PlantMonitorService: Prediction target logic")
        print("   Current: \(currentMoisture)% | Min: \(minMoisture)% | Max: \(maxMoisture)%")
        print("   Target set to: \(targetMoisture)% (using \(currentMoisture > maxMoisture ? "maxMoisture" : "minMoisture"))")
        print("   Days until watering: \(daysUntilWatering.rounded(toPlaces: 1))")
        print("   Drying rate: \(dryingRate.rounded(toPlaces: 1))%/day")
        
        return WateringPrediction(
            deviceUUID: deviceUUID,
            predictedDate: predictedDate,
            confidence: confidence,
            currentMoisture: currentMoisture,
            targetMoisture: targetMoisture,
            dryingRatePerDay: dryingRate,
            basedOnDataPoints: sensorData.count,
            lastWateringEvent: wateringEvents.first?.wateringDate
        )
    }
    
    private func calculateAdjustedDryingRate(sensorData: [SensorDataDTO], wateringEvents: [WateringEventDTO]) -> Double {
        var totalLoss: Double = 0
        var validIntervals = 0
        
        let sortedData = sensorData.sorted { $0.date < $1.date }
        let sortedEvents = wateringEvents.sorted { $0.wateringDate < $1.wateringDate }
        
        for i in 1..<sortedData.count {
            let current = sortedData[i]
            let previous = sortedData[i-1]
            
            // Skip intervals that contain watering events
            let hasWateringBetween = sortedEvents.contains { event in
                event.wateringDate > previous.date && event.wateringDate <= current.date
            }
            
            if !hasWateringBetween && current.moisture < previous.moisture {
                let timeDiffInDays = current.date.timeIntervalSince(previous.date) / (24 * 60 * 60)
                let moistureLoss = Double(previous.moisture - current.moisture)
                
                // Only consider intervals longer than 1 hour and shorter than 3 days to avoid extreme rates
                if timeDiffInDays > (1.0 / 24.0) && timeDiffInDays < 3 {
                    let dailyRate = moistureLoss / timeDiffInDays
                    // Cap individual rates to reasonable values (max 20% per day for a single interval)
                    let cappedRate = min(dailyRate, 20.0)
                    totalLoss += cappedRate
                    validIntervals += 1
                    
                    print("🔍 PlantMonitorService: Drying interval - \(moistureLoss.rounded(toPlaces: 1))% over \(timeDiffInDays.rounded(toPlaces: 2)) days = \(cappedRate.rounded(toPlaces: 1))%/day")
                } else if timeDiffInDays <= (1.0 / 24.0) {
                    print("⚠️ PlantMonitorService: Skipping very short interval (\(timeDiffInDays.rounded(toPlaces: 3)) days)")
                }
            }
        }
        
        let averageDryingRate = validIntervals > 0 ? totalLoss / Double(validIntervals) : 2.0
        let seasonalMultiplier = getSeasonalDryingMultiplier()
        
        let finalRate = max(0.5, min(10.0, averageDryingRate * seasonalMultiplier))
        print("📊 PlantMonitorService: Calculated drying rate - Valid intervals: \(validIntervals), Average: \(averageDryingRate.rounded(toPlaces: 1))%/day, Seasonal multiplier: \(seasonalMultiplier), Final: \(finalRate.rounded(toPlaces: 1))%/day")
        
        return finalRate
    }
    
    private func calculatePredictionConfidence(
        sensorData: [SensorDataDTO],
        wateringEvents: [WateringEventDTO],
        dryingRate: Double
    ) -> Double {
        var confidence: Double = 0.5
        
        if sensorData.count > 20 {
            confidence += 0.2
        } else if sensorData.count > 10 {
            confidence += 0.1
        }
        
        if !wateringEvents.isEmpty {
            confidence += 0.2
        }
        
        if dryingRate > 0.5 && dryingRate < 10 {
            confidence += 0.2
        } else {
            confidence -= 0.1
        }
        
        if let lastReading = sensorData.last,
           Date().timeIntervalSince(lastReading.date) < 24 * 60 * 60 {
            confidence += 0.1
        }
        
        return max(0.1, min(1.0, confidence))
    }
    
    private func getSeasonalDryingMultiplier() -> Double {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: Date())
        
        switch month {
        case 6, 7, 8: return 1.3  // Summer
        case 12, 1, 2: return 0.8  // Winter
        default: return 1.0  // Spring/Fall
        }
    }
    
    // MARK: - Notification Methods
    
    private func scheduleImmediateNotification(for device: FlowerDeviceDTO) async {
        await cancelNotifications(for: device.uuid)
        
        let content = UNMutableNotificationContent()
        content.title = "💧 Water Your \(device.name)"
        content.body = "Moisture level is below optimal range. Your plant needs water now!"
        content.sound = .default
        content.categoryIdentifier = "WATERING_REMINDER"
        
        // Configure as time-sensitive (urgent) notification
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0 // Highest relevance
        
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "immediate"
        ]
        
        let identifier = "watering-immediate-\(device.uuid)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("📱 PlantMonitorService: Scheduled URGENT (time-sensitive) immediate notification for \(device.name)")
        } catch {
            print("❌ PlantMonitorService: Failed to schedule immediate notification: \(error)")
        }
    }
    
    private func schedulePredictiveNotification(for device: FlowerDeviceDTO, wateringDate: Date) async {
        await cancelNotifications(for: device.uuid)
        
        let notificationDate = wateringDate.addingTimeInterval(-2 * 60 * 60) // 2 hours before
        
        guard notificationDate > Date() else {
            print("⚠️ PlantMonitorService: Skipping predictive notification - would be in the past")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "🌱 \(device.name) Will Need Water Soon"
        content.body = "Based on current trends, your plant will need watering in about 2 hours."
        content.sound = .default
        content.categoryIdentifier = "WATERING_REMINDER"
        
        // Configure as active notification (less urgent than immediate)
        content.interruptionLevel = .active
        content.relevanceScore = 0.7 // High relevance but not maximum
        
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "predictive"
        ]
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let identifier = "watering-predictive-\(device.uuid)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("📱 PlantMonitorService: Scheduled ACTIVE priority predictive notification for \(device.name)")
        } catch {
            print("❌ PlantMonitorService: Failed to schedule predictive notification: \(error)")
        }
    }
    
    private func cancelNotifications(for deviceUUID: String) async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        
        let identifiersToRemove = pendingRequests
            .filter { $0.identifier.contains(deviceUUID) }
            .map { $0.identifier }
        
        center.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        
        print("🗑️ PlantMonitorService: Cancelled \(identifiersToRemove.count) notifications for device \(deviceUUID)")
    }
}

//
//  MoistureAnomalyService.swift
//  GrowGuard
//
//  Created by Claude on 20.08.25.
//

import Foundation

// MARK: - Data Models

struct MoistureAnomaly {
    let type: MoistureAnomalyType
    let startDate: Date
    let endDate: Date?
    let severity: Double // 0.0 - 1.0
    let impactOnDrying: Double // Multiplier for drying rate
    let description: String
    
    init(type: MoistureAnomalyType, startDate: Date, endDate: Date? = nil, severity: Double, impactOnDrying: Double) {
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.severity = max(0.0, min(1.0, severity))
        self.impactOnDrying = max(0.1, min(3.0, impactOnDrying))
        self.description = type.description
    }
}

enum MoistureAnomalyType {
    case rapidDrying(rate: Double)           // Much faster than normal
    case slowDrying(rate: Double)            // Much slower than normal  
    case plateauPeriod(duration: Double)     // Stable moisture for extended time
    case unexpectedIncrease(amount: Int16)   // Moisture went up (rain/watering)
    case dramaticDrop(amount: Int16)         // Sudden big moisture loss
    case irregularPattern(variance: Double)  // Chaotic up/down pattern
    
    var description: String {
        switch self {
        case .rapidDrying(let rate):
            return "Rapid drying detected (\(rate.rounded(toPlaces: 1))%/day)"
        case .slowDrying(let rate):
            return "Slow drying period (\(rate.rounded(toPlaces: 1))%/day)"
        case .plateauPeriod(let duration):
            return "Extended stable period (\(duration.rounded(toPlaces: 1)) days)"
        case .unexpectedIncrease(let amount):
            return "Unexpected moisture increase (+\(amount)%)"
        case .dramaticDrop(let amount):
            return "Dramatic moisture drop (-\(amount)%)"
        case .irregularPattern(let variance):
            return "Irregular moisture pattern (variance: \(variance.rounded(toPlaces: 1)))"
        }
    }
}

struct MoistureBaseline {
    let averageDryingRate: Double
    let normalDryingRateRange: ClosedRange<Double>
    let averagePlateauDuration: Double
    let typicalVariability: Double
    let dataPoints: Int
    
    var isReliable: Bool {
        return dataPoints >= 10 && averageDryingRate > 0.1
    }
}

struct AnomalyAdjustment {
    let adjustedDryingRate: Double
    let confidenceMultiplier: Double
    let appliedAnomalies: [MoistureAnomaly]
    let explanation: String
}

// MARK: - Service Implementation

class MoistureAnomalyService {
    static let shared = MoistureAnomalyService()
    private let repositoryManager = RepositoryManager.shared
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Detects moisture anomalies for a device over the specified lookback period
    func detectAnomalies(
        for deviceUUID: String,
        lookbackDays: Int = 14
    ) async throws -> [MoistureAnomaly] {
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60)
        let moistureData = try await repositoryManager.sensorDataRepository
            .getSensorDataInDateRange(for: deviceUUID, startDate: startDate, endDate: endDate)
        
        return detectAnomalies(from: moistureData)
    }
    
    /// Calculates adjusted drying rate based on detected anomalies
    func calculateAdjustedDryingRate(
        baseDryingRate: Double,
        anomalies: [MoistureAnomaly]
    ) -> AnomalyAdjustment {
        var adjustedRate = baseDryingRate
        var confidenceReduction = 0.0
        var appliedAnomalies: [MoistureAnomaly] = []
        var explanationParts: [String] = []
        
        // Apply recent anomaly impacts (last 7 days get full weight)
        for anomaly in anomalies {
            let daysAgo = Date().timeIntervalSince(anomaly.startDate) / (24 * 60 * 60)
            let recencyWeight = max(0.1, 1.0 - (daysAgo / 7.0))
            
            if recencyWeight > 0.2 { // Only apply significant recent anomalies
                let impactMultiplier = 1.0 + (anomaly.impactOnDrying - 1.0) * recencyWeight * anomaly.severity
                adjustedRate *= impactMultiplier
                
                confidenceReduction += anomaly.severity * 0.15 * recencyWeight
                appliedAnomalies.append(anomaly)
                
                let impact = impactMultiplier > 1.0 ? "increased" : "decreased"
                explanationParts.append("\(anomaly.description) - drying rate \(impact) by \((impactMultiplier - 1.0) * 100)%")
            }
        }
        
        // Bound the rate to reasonable values
        adjustedRate = max(0.2, min(12.0, adjustedRate))
        let finalConfidence = max(0.1, 1.0 - confidenceReduction)
        
        let explanation = appliedAnomalies.isEmpty ? 
            "No recent anomalies detected - using baseline drying rate" :
            "Applied \(appliedAnomalies.count) anomal\(appliedAnomalies.count == 1 ? "y" : "ies"): " + explanationParts.joined(separator: "; ")
        
        return AnomalyAdjustment(
            adjustedDryingRate: adjustedRate,
            confidenceMultiplier: finalConfidence,
            appliedAnomalies: appliedAnomalies,
            explanation: explanation
        )
    }
    
    // MARK: - Internal Detection Methods
    
    func detectAnomalies(from data: [SensorDataDTO]) -> [MoistureAnomaly] {
        guard data.count > 5 else { return [] }
        
        var anomalies: [MoistureAnomaly] = []
        
        // Calculate baseline behavior
        let baseline = calculateMoistureBaseline(from: data)
        
        // Only proceed if we have reliable baseline data
        guard baseline.isReliable else {
            print("⚠️ MoistureAnomalyService: Insufficient data for reliable anomaly detection")
            return []
        }
        
        // Detect different types of anomalies
        anomalies.append(contentsOf: detectRapidDryingEvents(from: data, baseline: baseline))
        anomalies.append(contentsOf: detectSlowDryingEvents(from: data, baseline: baseline))
        anomalies.append(contentsOf: detectPlateauPeriods(from: data, baseline: baseline))
        anomalies.append(contentsOf: detectUnexpectedMoistureChanges(from: data))
        anomalies.append(contentsOf: detectIrregularPatterns(from: data, baseline: baseline))
        
        // Sort by recency (most recent first)
        return anomalies.sorted { $0.startDate > $1.startDate }
    }
    
    func calculateMoistureBaseline(from data: [SensorDataDTO]) -> MoistureBaseline {
        var dailyRates: [Double] = []
        var plateauDurations: [Double] = []
        var dailyChanges: [Double] = []
        
        // Analyze day-to-day moisture changes
        for i in 1..<data.count {
            let current = data[i]
            let previous = data[i-1]
            
            let timeDiff = current.date.timeIntervalSince(previous.date) / (24 * 60 * 60)
            let moistureChange = Double(previous.moisture - current.moisture) // Positive = drying
            
            if timeDiff > 0.5 && timeDiff < 2.0 { // Reasonable time window
                let dailyRate = moistureChange / timeDiff
                if dailyRate > 0 { // Only count actual drying
                    dailyRates.append(dailyRate)
                }
                dailyChanges.append(moistureChange)
            }
        }
        
        // Find plateau periods (consecutive readings with <2% change)
        var currentPlateauDuration = 0.0
        for i in 1..<data.count {
            let moistureChange = abs(data[i].moisture - data[i-1].moisture)
            let timeDiff = data[i].date.timeIntervalSince(data[i-1].date) / (24 * 60 * 60)
            
            if moistureChange <= 2 {
                currentPlateauDuration += timeDiff
            } else {
                if currentPlateauDuration > 1.0 { // At least 1 day plateau
                    plateauDurations.append(currentPlateauDuration)
                }
                currentPlateauDuration = 0.0
            }
        }
        
        let avgDryingRate = dailyRates.isEmpty ? 2.0 : dailyRates.reduce(0, +) / Double(dailyRates.count)
        let stdDev = dailyRates.isEmpty ? 1.0 : sqrt(dailyRates.map { pow($0 - avgDryingRate, 2) }.reduce(0, +) / Double(dailyRates.count))
        let avgPlateauDuration = plateauDurations.isEmpty ? 2.0 : plateauDurations.reduce(0, +) / Double(plateauDurations.count)
        
        return MoistureBaseline(
            averageDryingRate: avgDryingRate,
            normalDryingRateRange: max(0.5, avgDryingRate - stdDev)...min(10.0, avgDryingRate + stdDev),
            averagePlateauDuration: avgPlateauDuration,
            typicalVariability: stdDev,
            dataPoints: dailyRates.count
        )
    }
    
    private func detectRapidDryingEvents(from data: [SensorDataDTO], baseline: MoistureBaseline) -> [MoistureAnomaly] {
        var anomalies: [MoistureAnomaly] = []
        
        for i in 1..<data.count {
            let current = data[i]
            let previous = data[i-1]
            
            let timeDiff = current.date.timeIntervalSince(previous.date) / (24 * 60 * 60)
            let moistureLoss = Double(previous.moisture - current.moisture)
            
            if timeDiff > 0.5 && moistureLoss > 0 {
                let dryingRate = moistureLoss / timeDiff
                
                // Anomaly if rate is 50% higher than normal upper bound
                if dryingRate > baseline.normalDryingRateRange.upperBound * 1.5 {
                    let severity = min(1.0, (dryingRate - baseline.averageDryingRate) / baseline.averageDryingRate)
                    
                    anomalies.append(MoistureAnomaly(
                        type: .rapidDrying(rate: dryingRate),
                        startDate: previous.date,
                        endDate: current.date,
                        severity: severity,
                        impactOnDrying: 1.0 + severity * 0.5 // Increase drying rate prediction
                    ))
                }
            }
        }
        
        return anomalies
    }
    
    private func detectSlowDryingEvents(from data: [SensorDataDTO], baseline: MoistureBaseline) -> [MoistureAnomaly] {
        var anomalies: [MoistureAnomaly] = []
        var slowPeriodStart: Date?
        var slowPeriodData: [SensorDataDTO] = []
        
        for i in 1..<data.count {
            let current = data[i]
            let previous = data[i-1]
            
            let timeDiff = current.date.timeIntervalSince(previous.date) / (24 * 60 * 60)
            let moistureChange = Double(previous.moisture - current.moisture)
            
            if timeDiff > 0.5 {
                let dryingRate = max(0, moistureChange / timeDiff)
                
                // If significantly slower than normal
                if dryingRate < baseline.normalDryingRateRange.lowerBound * 0.5 {
                    if slowPeriodStart == nil {
                        slowPeriodStart = previous.date
                        slowPeriodData = [previous]
                    }
                    slowPeriodData.append(current)
                } else {
                    // End of slow period
                    if let startDate = slowPeriodStart, slowPeriodData.count > 2 {
                        let avgSlowRate = calculateAverageRate(slowPeriodData)
                        let severity = min(1.0, (baseline.averageDryingRate - avgSlowRate) / baseline.averageDryingRate)
                        
                        if severity > 0.3 { // Only report significant slow periods
                            anomalies.append(MoistureAnomaly(
                                type: .slowDrying(rate: avgSlowRate),
                                startDate: startDate,
                                endDate: current.date,
                                severity: severity,
                                impactOnDrying: max(0.3, 1.0 - severity * 0.7) // Reduce drying rate prediction
                            ))
                        }
                    }
                    slowPeriodStart = nil
                    slowPeriodData = []
                }
            }
        }
        
        return anomalies
    }
    
    private func detectPlateauPeriods(from data: [SensorDataDTO], baseline: MoistureBaseline) -> [MoistureAnomaly] {
        var anomalies: [MoistureAnomaly] = []
        var plateauStart: Date?
        
        for i in 1..<data.count {
            let current = data[i]
            let previous = data[i-1]
            
            let moistureChange = abs(current.moisture - previous.moisture)
            
            if moistureChange <= 2 { // Stable moisture (±2%)
                if plateauStart == nil {
                    plateauStart = previous.date
                }
            } else {
                // End of plateau
                if let startDate = plateauStart {
                    let plateauDuration = current.date.timeIntervalSince(startDate) / (24 * 60 * 60)
                    
                    // Only report plateaus significantly longer than normal
                    if plateauDuration > baseline.averagePlateauDuration * 1.5 && plateauDuration > 3.0 {
                        let severity = min(1.0, plateauDuration / 7.0) // Normalize to week
                        
                        anomalies.append(MoistureAnomaly(
                            type: .plateauPeriod(duration: plateauDuration),
                            startDate: startDate,
                            endDate: current.date,
                            severity: severity,
                            impactOnDrying: max(0.2, 1.0 - (severity * 0.5)) // Reduce future drying predictions
                        ))
                    }
                }
                plateauStart = nil
            }
        }
        
        return anomalies
    }
    
    private func detectUnexpectedMoistureChanges(from data: [SensorDataDTO]) -> [MoistureAnomaly] {
        var anomalies: [MoistureAnomaly] = []
        
        for i in 1..<data.count {
            let current = data[i]
            let previous = data[i-1]
            
            let moistureIncrease = current.moisture - previous.moisture
            let moistureDecrease = previous.moisture - current.moisture
            let timeInterval = current.date.timeIntervalSince(previous.date) / 3600 // hours
            
            // Detect moisture increases that aren't obvious watering (rain events)
            if moistureIncrease > 5 && moistureIncrease < 20 && timeInterval > 1 && timeInterval < 48 {
                let severity = Double(moistureIncrease) / 20.0
                
                anomalies.append(MoistureAnomaly(
                    type: .unexpectedIncrease(amount: moistureIncrease),
                    startDate: previous.date,
                    endDate: current.date,
                    severity: severity,
                    impactOnDrying: 0.5 // Significantly reduce drying rate temporarily
                ))
            }
            
            // Detect dramatic drops (unusual drying events)
            if moistureDecrease > 10 && timeInterval < 24 {
                let severity = Double(moistureDecrease) / 20.0
                
                anomalies.append(MoistureAnomaly(
                    type: .dramaticDrop(amount: moistureDecrease),
                    startDate: previous.date,
                    endDate: current.date,
                    severity: severity,
                    impactOnDrying: 1.5 + severity * 0.5 // Increase drying rate temporarily
                ))
            }
        }
        
        return anomalies
    }
    
    private func detectIrregularPatterns(from data: [SensorDataDTO], baseline: MoistureBaseline) -> [MoistureAnomaly] {
        var anomalies: [MoistureAnomaly] = []
        
        // Look for periods with high variance in moisture changes
        let windowSize = min(7, data.count / 2) // 7-day window or half the data
        guard windowSize >= 3 else { return [] }
        
        for i in windowSize..<data.count {
            let windowData = Array(data[(i-windowSize)..<i])
            let variance = calculateMoistureVariance(windowData)
            
            // If variance is much higher than baseline
            if variance > baseline.typicalVariability * 3.0 && variance > 5.0 {
                let severity = min(1.0, variance / (baseline.typicalVariability * 5.0))
                
                anomalies.append(MoistureAnomaly(
                    type: .irregularPattern(variance: variance),
                    startDate: windowData.first?.date ?? Date(),
                    endDate: windowData.last?.date,
                    severity: severity,
                    impactOnDrying: 1.0 // Keep normal rate but reduce confidence
                ))
            }
        }
        
        return anomalies
    }
    
    // MARK: - Helper Methods
    
    private func calculateAverageRate(_ data: [SensorDataDTO]) -> Double {
        guard data.count > 1 else { return 0.0 }
        
        var totalRate = 0.0
        var validIntervals = 0
        
        for i in 1..<data.count {
            let timeDiff = data[i].date.timeIntervalSince(data[i-1].date) / (24 * 60 * 60)
            let moistureChange = Double(data[i-1].moisture - data[i].moisture)
            
            if timeDiff > 0.1 {
                totalRate += max(0, moistureChange / timeDiff)
                validIntervals += 1
            }
        }
        
        return validIntervals > 0 ? totalRate / Double(validIntervals) : 0.0
    }
    
    private func calculateMoistureVariance(_ data: [SensorDataDTO]) -> Double {
        guard data.count > 1 else { return 0.0 }
        
        let changes = (1..<data.count).map { i in
            Double(abs(data[i].moisture - data[i-1].moisture))
        }
        
        let mean = changes.reduce(0, +) / Double(changes.count)
        let variance = changes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(changes.count)
        
        return sqrt(variance) // Return standard deviation
    }
}

// MARK: - Extensions

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
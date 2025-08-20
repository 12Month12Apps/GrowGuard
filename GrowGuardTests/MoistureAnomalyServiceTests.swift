//
//  MoistureAnomalyServiceTests.swift
//  GrowGuardTests
//
//  Created by Claude on 20.08.25.
//

import XCTest
@testable import GrowGuard

final class MoistureAnomalyServiceTests: XCTestCase {
    
    var service: MoistureAnomalyService!
    
    override func setUpWithError() throws {
        service = MoistureAnomalyService.shared
    }
    
    override func tearDownWithError() throws {
        service = nil
    }
    
    // MARK: - Baseline Calculation Tests
    
    func testCalculateMoistureBaseline_WithNormalDryingPattern() throws {
        // Given: Normal drying pattern over 10 days
        let testData = createNormalDryingPattern(
            startMoisture: 80,
            endMoisture: 40,
            days: 10,
            dryingRate: 4.0 // 4% per day
        )
        
        // When
        let baseline = service.calculateMoistureBaseline(from: testData)
        
        // Then
        XCTAssertTrue(baseline.isReliable, "Baseline should be reliable with sufficient data")
        XCTAssertEqual(baseline.averageDryingRate, 4.0, accuracy: 0.5, "Should detect 4%/day drying rate")
        XCTAssertTrue(baseline.normalDryingRateRange.contains(4.0), "Normal range should contain the average rate")
        XCTAssertGreaterThan(baseline.dataPoints, 5, "Should have sufficient data points")
    }
    
    func testCalculateMoistureBaseline_WithInsufficientData() throws {
        // Given: Very little data
        let testData = createTestData(moistureValues: [80, 78], intervalHours: 24)
        
        // When
        let baseline = service.calculateMoistureBaseline(from: testData)
        
        // Then
        XCTAssertFalse(baseline.isReliable, "Baseline should not be reliable with insufficient data")
        XCTAssertLessThan(baseline.dataPoints, 10, "Should have few data points")
    }
    
    // MARK: - Rapid Drying Detection Tests
    
    func testDetectRapidDryingEvents() throws {
        // Given: Normal pattern followed by rapid drying
        let normalData = createNormalDryingPattern(startMoisture: 80, endMoisture: 60, days: 5, dryingRate: 4.0)
        let rapidData = createRapidDryingPattern(startMoisture: 60, endMoisture: 30, days: 2, dryingRate: 15.0)
        let testData = normalData + rapidData
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        let rapidDryingAnomalies = anomalies.filter {
            if case .rapidDrying(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(rapidDryingAnomalies.count, 0, "Should detect rapid drying anomaly")
        
        let firstAnomaly = rapidDryingAnomalies.first!
        XCTAssertGreaterThan(firstAnomaly.severity, 0.5, "Should have high severity for rapid drying")
        XCTAssertGreaterThan(firstAnomaly.impactOnDrying, 1.0, "Should increase drying rate prediction")
    }
    
    // MARK: - Slow Drying Detection Tests
    
    func testDetectSlowDryingEvents() throws {
        // Given: Normal pattern followed by very slow drying
        let normalData = createNormalDryingPattern(startMoisture: 80, endMoisture: 60, days: 5, dryingRate: 4.0)
        let slowData = createSlowDryingPattern(startMoisture: 60, endMoisture: 55, days: 5, dryingRate: 1.0)
        let testData = normalData + slowData
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        let slowDryingAnomalies = anomalies.filter {
            if case .slowDrying(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(slowDryingAnomalies.count, 0, "Should detect slow drying anomaly")
        
        let firstAnomaly = slowDryingAnomalies.first!
        XCTAssertGreaterThan(firstAnomaly.severity, 0.3, "Should have meaningful severity for slow drying")
        XCTAssertLessThan(firstAnomaly.impactOnDrying, 1.0, "Should decrease drying rate prediction")
    }
    
    // MARK: - Plateau Detection Tests
    
    func testDetectPlateauPeriods() throws {
        // Given: Normal drying followed by extended plateau
        let normalData = createNormalDryingPattern(startMoisture: 80, endMoisture: 50, days: 5, dryingRate: 6.0)
        let plateauData = createPlateauPattern(moisture: 50, days: 5)
        let testData = normalData + plateauData
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        let plateauAnomalies = anomalies.filter {
            if case .plateauPeriod(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(plateauAnomalies.count, 0, "Should detect plateau anomaly")
        
        let firstAnomaly = plateauAnomalies.first!
        XCTAssertLessThan(firstAnomaly.impactOnDrying, 1.0, "Plateau should reduce future drying predictions")
    }
    
    // MARK: - Unexpected Moisture Change Tests
    
    func testDetectUnexpectedMoistureIncrease() throws {
        // Given: Normal drying with sudden moisture increase (rain event)
        let normalData = createNormalDryingPattern(startMoisture: 80, endMoisture: 40, days: 8, dryingRate: 5.0)
        let rainData = createRainEvent(fromMoisture: 40, toMoisture: 55, hours: 6)
        let testData = normalData + rainData
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        let unexpectedIncreaseAnomalies = anomalies.filter {
            if case .unexpectedIncrease(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(unexpectedIncreaseAnomalies.count, 0, "Should detect unexpected moisture increase")
        
        let rainAnomaly = unexpectedIncreaseAnomalies.first!
        XCTAssertLessThan(rainAnomaly.impactOnDrying, 1.0, "Rain should reduce drying rate temporarily")
    }
    
    func testDetectDramaticMoistureDrop() throws {
        // Given: Sudden dramatic moisture loss
        let baseData = createTestData(moistureValues: [80, 79, 78], intervalHours: 24)
        let dropData = createTestData(moistureValues: [78, 60], intervalHours: 12) // 18% drop in 12 hours
        let testData = baseData + Array(dropData.dropFirst()) // Avoid duplicate
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        let dramaticDropAnomalies = anomalies.filter {
            if case .dramaticDrop(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(dramaticDropAnomalies.count, 0, "Should detect dramatic moisture drop")
        
        let dropAnomaly = dramaticDropAnomalies.first!
        XCTAssertGreaterThan(dropAnomaly.impactOnDrying, 1.0, "Dramatic drop should increase drying rate prediction")
    }
    
    // MARK: - Irregular Pattern Detection Tests
    
    func testDetectIrregularPatterns() throws {
        // Given: Highly variable moisture pattern
        let irregularData = createIrregularPattern(
            baseMoisture: 60,
            days: 7,
            variance: 10 // High variance
        )
        
        // When
        let anomalies = service.detectAnomalies(from: irregularData)
        
        // Then
        let irregularAnomalies = anomalies.filter {
            if case .irregularPattern(_) = $0.type { return true }
            return false
        }
        
        XCTAssertGreaterThan(irregularAnomalies.count, 0, "Should detect irregular patterns")
    }
    
    // MARK: - Adjustment Calculation Tests
    
    func testCalculateAdjustedDryingRate_NoAnomalies() throws {
        // Given: No anomalies
        let baseDryingRate = 3.0
        let anomalies: [MoistureAnomaly] = []
        
        // When
        let adjustment = service.calculateAdjustedDryingRate(
            baseDryingRate: baseDryingRate,
            anomalies: anomalies
        )
        
        // Then
        XCTAssertEqual(adjustment.adjustedDryingRate, baseDryingRate, accuracy: 0.01, "Rate should remain unchanged with no anomalies")
        XCTAssertEqual(adjustment.confidenceMultiplier, 1.0, accuracy: 0.01, "Confidence should remain high with no anomalies")
        XCTAssertTrue(adjustment.appliedAnomalies.isEmpty, "No anomalies should be applied")
    }
    
    func testCalculateAdjustedDryingRate_RecentRapidDrying() throws {
        // Given: Recent rapid drying anomaly
        let baseDryingRate = 3.0
        let recentAnomaly = MoistureAnomaly(
            type: .rapidDrying(rate: 10.0),
            startDate: Date().addingTimeInterval(-2 * 24 * 60 * 60), // 2 days ago
            severity: 0.8,
            impactOnDrying: 1.5
        )
        
        // When
        let adjustment = service.calculateAdjustedDryingRate(
            baseDryingRate: baseDryingRate,
            anomalies: [recentAnomaly]
        )
        
        // Then
        XCTAssertGreaterThan(adjustment.adjustedDryingRate, baseDryingRate, "Rate should increase for recent rapid drying")
        XCTAssertLessThan(adjustment.confidenceMultiplier, 1.0, "Confidence should decrease due to anomaly")
        XCTAssertEqual(adjustment.appliedAnomalies.count, 1, "Should apply the recent anomaly")
    }
    
    func testCalculateAdjustedDryingRate_OldAnomaly() throws {
        // Given: Old anomaly (should have minimal impact)
        let baseDryingRate = 3.0
        let oldAnomaly = MoistureAnomaly(
            type: .rapidDrying(rate: 10.0),
            startDate: Date().addingTimeInterval(-10 * 24 * 60 * 60), // 10 days ago
            severity: 0.8,
            impactOnDrying: 1.5
        )
        
        // When
        let adjustment = service.calculateAdjustedDryingRate(
            baseDryingRate: baseDryingRate,
            anomalies: [oldAnomaly]
        )
        
        // Then
        XCTAssertEqual(adjustment.adjustedDryingRate, baseDryingRate, accuracy: 0.1, "Old anomaly should have minimal impact")
        XCTAssertTrue(adjustment.appliedAnomalies.isEmpty, "Old anomaly should not be applied")
    }
    
    // MARK: - Edge Cases Tests
    
    func testDetectAnomalies_EmptyData() throws {
        // Given: Empty data
        let testData: [SensorDataDTO] = []
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        XCTAssertTrue(anomalies.isEmpty, "Should return no anomalies for empty data")
    }
    
    func testDetectAnomalies_InsufficientData() throws {
        // Given: Very little data
        let testData = createTestData(moistureValues: [80, 75, 70], intervalHours: 24)
        
        // When
        let anomalies = service.detectAnomalies(from: testData)
        
        // Then
        XCTAssertTrue(anomalies.isEmpty, "Should return no anomalies for insufficient data")
    }
    
    func testAnomalyModel_SeverityBounds() throws {
        // Given: Anomaly with extreme severity values
        let highSeverityAnomaly = MoistureAnomaly(
            type: .rapidDrying(rate: 20.0),
            startDate: Date(),
            severity: 5.0, // Above max
            impactOnDrying: 1.5
        )
        
        let lowSeverityAnomaly = MoistureAnomaly(
            type: .slowDrying(rate: 0.5),
            startDate: Date(),
            severity: -1.0, // Below min
            impactOnDrying: 0.5
        )
        
        // Then: Severity should be bounded
        XCTAssertLessThanOrEqual(highSeverityAnomaly.severity, 1.0, "Severity should be capped at 1.0")
        XCTAssertGreaterThanOrEqual(lowSeverityAnomaly.severity, 0.0, "Severity should be minimum 0.0")
    }
    
    func testAnomalyModel_ImpactBounds() throws {
        // Given: Anomaly with extreme impact values
        let highImpactAnomaly = MoistureAnomaly(
            type: .rapidDrying(rate: 20.0),
            startDate: Date(),
            severity: 0.8,
            impactOnDrying: 10.0 // Very high
        )
        
        let lowImpactAnomaly = MoistureAnomaly(
            type: .slowDrying(rate: 0.1),
            startDate: Date(),
            severity: 0.8,
            impactOnDrying: 0.01 // Very low
        )
        
        // Then: Impact should be bounded
        XCTAssertLessThanOrEqual(highImpactAnomaly.impactOnDrying, 3.0, "Impact should be capped at 3.0")
        XCTAssertGreaterThanOrEqual(lowImpactAnomaly.impactOnDrying, 0.1, "Impact should be minimum 0.1")
    }
    
    // MARK: - Performance Tests
    
    func testDetectAnomalies_Performance() throws {
        // Given: Large dataset (2 months of hourly data)
        let largeDataset = createNormalDryingPattern(
            startMoisture: 80,
            endMoisture: 20,
            days: 60,
            dryingRate: 1.0,
            intervalHours: 1 // Hourly readings
        )
        
        // When: Measure performance
        measure {
            _ = service.detectAnomalies(from: largeDataset)
        }
        
        // Then: Should complete within reasonable time (measured by XCTest)
    }
    
    // MARK: - Helper Methods for Test Data Creation
    
    private func createTestData(moistureValues: [Int16], intervalHours: Double = 24) -> [SensorDataDTO] {
        var data: [SensorDataDTO] = []
        let startDate = Date().addingTimeInterval(-Double(moistureValues.count) * intervalHours * 3600)
        
        for (index, moisture) in moistureValues.enumerated() {
            let date = startDate.addingTimeInterval(Double(index) * intervalHours * 3600)
            data.append(createSensorData(moisture: moisture, date: date))
        }
        
        return data
    }
    
    private func createNormalDryingPattern(startMoisture: Int16, endMoisture: Int16, days: Int, dryingRate: Double, intervalHours: Double = 24) -> [SensorDataDTO] {
        var data: [SensorDataDTO] = []
        let startDate = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let totalIntervals = Int(Double(days * 24) / intervalHours)
        let moistureDecrement = Double(startMoisture - endMoisture) / Double(totalIntervals)
        
        for i in 0...totalIntervals {
            let date = startDate.addingTimeInterval(Double(i) * intervalHours * 3600)
            let moisture = Int16(Double(startMoisture) - (Double(i) * moistureDecrement))
            data.append(createSensorData(moisture: max(endMoisture, moisture), date: date))
        }
        
        return data
    }
    
    private func createRapidDryingPattern(startMoisture: Int16, endMoisture: Int16, days: Int, dryingRate: Double) -> [SensorDataDTO] {
        return createNormalDryingPattern(
            startMoisture: startMoisture,
            endMoisture: endMoisture,
            days: days,
            dryingRate: dryingRate,
            intervalHours: 6 // More frequent readings for rapid drying
        )
    }
    
    private func createSlowDryingPattern(startMoisture: Int16, endMoisture: Int16, days: Int, dryingRate: Double) -> [SensorDataDTO] {
        return createNormalDryingPattern(
            startMoisture: startMoisture,
            endMoisture: endMoisture,
            days: days,
            dryingRate: dryingRate,
            intervalHours: 24
        )
    }
    
    private func createPlateauPattern(moisture: Int16, days: Int) -> [SensorDataDTO] {
        var data: [SensorDataDTO] = []
        let startDate = Date()
        
        for i in 0..<(days * 24) { // Hourly readings
            let date = startDate.addingTimeInterval(Double(i) * 3600)
            // Add small random variation (±1%) to simulate real sensor readings
            let variation = Int16.random(in: -1...1)
            data.append(createSensorData(moisture: moisture + variation, date: date))
        }
        
        return data
    }
    
    private func createRainEvent(fromMoisture: Int16, toMoisture: Int16, hours: Int) -> [SensorDataDTO] {
        var data: [SensorDataDTO] = []
        let startDate = Date()
        let moistureIncrease = toMoisture - fromMoisture
        
        for i in 0...hours {
            let date = startDate.addingTimeInterval(Double(i) * 3600)
            let progress = Double(i) / Double(hours)
            let currentMoisture = fromMoisture + Int16(Double(moistureIncrease) * progress)
            data.append(createSensorData(moisture: currentMoisture, date: date))
        }
        
        return data
    }
    
    private func createIrregularPattern(baseMoisture: Int16, days: Int, variance: Int16) -> [SensorDataDTO] {
        var data: [SensorDataDTO] = []
        let startDate = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        
        for i in 0..<(days * 6) { // Every 4 hours
            let date = startDate.addingTimeInterval(Double(i) * 4 * 3600)
            let randomVariation = Int16.random(in: -variance...variance)
            let moisture = max(Int16(10), min(Int16(100), baseMoisture + randomVariation))
            data.append(createSensorData(moisture: moisture, date: date))
        }
        
        return data
    }
    
    private func createSensorData(moisture: Int16, date: Date) -> SensorDataDTO {
        return SensorDataDTO(
            temperature: 22.0,
            brightness: 5000,
            moisture: moisture,
            conductivity: 500,
            date: date,
            deviceUUID: "test-device-uuid"
        )
    }
}
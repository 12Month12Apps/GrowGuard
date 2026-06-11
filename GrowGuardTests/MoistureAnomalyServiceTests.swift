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
    //
    // Note on test data: the service analyzes consecutive readings within
    // 0.5–2 day windows and requires >= 10 valid drying intervals for a
    // reliable baseline, so all detection tests use one chronological daily
    // series (a normal phase long enough for the baseline, then the anomaly).

    func testDetectRapidDryingEvents() throws {
        // Given: 12 days of normal drying (4%/day), then 2 days at 15%/day
        let testData = makeDailySeries(
            [90, 86, 82, 78, 74, 70, 66, 62, 58, 54, 50, 46, 42] + [27, 12]
        )

        // When
        let anomalies = service.detectAnomalies(from: testData)

        // Then
        let rapidDryingAnomalies = anomalies.filter {
            if case .rapidDrying(_) = $0.type { return true }
            return false
        }

        XCTAssertGreaterThan(rapidDryingAnomalies.count, 0, "Should detect rapid drying anomaly")

        let firstAnomaly = try XCTUnwrap(rapidDryingAnomalies.first)
        XCTAssertGreaterThan(firstAnomaly.severity, 0.5, "Should have high severity for rapid drying")
        XCTAssertGreaterThan(firstAnomaly.impactOnDrying, 1.0, "Should increase drying rate prediction")
    }

    // MARK: - Slow Drying Detection Tests

    func testDetectSlowDryingEvents() throws {
        // Given: 12 days of normal drying (5%/day), 4 days at 1%/day,
        // then one normal day to close the slow period
        let testData = makeDailySeries(
            [90, 85, 80, 75, 70, 65, 60, 55, 50, 45, 40, 35, 30] + [29, 28, 27, 26] + [21]
        )

        // When
        let anomalies = service.detectAnomalies(from: testData)

        // Then
        let slowDryingAnomalies = anomalies.filter {
            if case .slowDrying(_) = $0.type { return true }
            return false
        }

        XCTAssertGreaterThan(slowDryingAnomalies.count, 0, "Should detect slow drying anomaly")

        let firstAnomaly = try XCTUnwrap(slowDryingAnomalies.first)
        XCTAssertGreaterThan(firstAnomaly.severity, 0.3, "Should have meaningful severity for slow drying")
        XCTAssertLessThan(firstAnomaly.impactOnDrying, 1.0, "Should decrease drying rate prediction")
    }

    // MARK: - Plateau Detection Tests

    func testDetectPlateauPeriods() throws {
        // Given: normal drying with a short 2-day plateau (sets the baseline
        // plateau duration), then a 5-day plateau that is anomalously long,
        // closed by a normal drying day
        let testData = makeDailySeries(
            [90, 86, 82, 78, 74, 70]        // 5 days normal
            + [70, 70]                       // short baseline plateau
            + [66, 62, 58, 54, 50, 46, 42]   // 7 days normal
            + [42, 42, 42, 42, 42]           // extended plateau
            + [38]                           // closing drying day
        )

        // When
        let anomalies = service.detectAnomalies(from: testData)

        // Then
        let plateauAnomalies = anomalies.filter {
            if case .plateauPeriod(_) = $0.type { return true }
            return false
        }

        XCTAssertGreaterThan(plateauAnomalies.count, 0, "Should detect plateau anomaly")

        let firstAnomaly = try XCTUnwrap(plateauAnomalies.first)
        XCTAssertLessThan(firstAnomaly.impactOnDrying, 1.0, "Plateau should reduce future drying predictions")
    }

    // MARK: - Unexpected Moisture Change Tests

    func testDetectUnexpectedMoistureIncrease() throws {
        // Given: 12 days of normal drying, then +10% within 6 hours (rain)
        let rainDate = Date()
        var testData = makeDailySeries(
            [90, 86, 82, 78, 74, 70, 66, 62, 58, 54, 50, 46, 42],
            endingAt: rainDate.addingTimeInterval(-6 * 3600)
        )
        testData.append(createSensorData(moisture: 52, date: rainDate))

        // When
        let anomalies = service.detectAnomalies(from: testData)

        // Then
        let unexpectedIncreaseAnomalies = anomalies.filter {
            if case .unexpectedIncrease(_) = $0.type { return true }
            return false
        }

        XCTAssertGreaterThan(unexpectedIncreaseAnomalies.count, 0, "Should detect unexpected moisture increase")

        let rainAnomaly = try XCTUnwrap(unexpectedIncreaseAnomalies.first)
        XCTAssertLessThan(rainAnomaly.impactOnDrying, 1.0, "Rain should reduce drying rate temporarily")
    }

    func testDetectDramaticMoistureDrop() throws {
        // Given: 12 days of normal drying, then a 15% drop within 12 hours
        let dropDate = Date()
        var testData = makeDailySeries(
            [90, 86, 82, 78, 74, 70, 66, 62, 58, 54, 50, 46, 42],
            endingAt: dropDate.addingTimeInterval(-12 * 3600)
        )
        testData.append(createSensorData(moisture: 27, date: dropDate))

        // When
        let anomalies = service.detectAnomalies(from: testData)

        // Then
        let dramaticDropAnomalies = anomalies.filter {
            if case .dramaticDrop(_) = $0.type { return true }
            return false
        }

        XCTAssertGreaterThan(dramaticDropAnomalies.count, 0, "Should detect dramatic moisture drop")

        let dropAnomaly = try XCTUnwrap(dramaticDropAnomalies.first)
        XCTAssertGreaterThan(dropAnomaly.impactOnDrying, 1.0, "Dramatic drop should increase drying rate prediction")
    }

    // MARK: - Irregular Pattern Detection Tests

    func testDetectIrregularPatterns() throws {
        // Given: a long stable drying phase (keeps the baseline variability
        // low), then chaotic readings with large up-swings and small drying
        // steps so the windowed variance exceeds the baseline by far
        let testData = makeDailySeries(
            [95, 91, 87, 83, 79, 75, 71, 67, 63, 59, 55, 51, 47, 43, 39, 35, 31, 27, 23, 19, 15]
            + [35, 33, 58, 57, 87, 84]
        )

        // When
        let anomalies = service.detectAnomalies(from: testData)

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
    
    /// Builds one chronological series with daily readings, ending at `endingAt`.
    /// All detection tests use this so consecutive readings stay within the
    /// service's 0.5–2 day analysis windows.
    private func makeDailySeries(_ moistureValues: [Int16], endingAt end: Date = Date()) -> [SensorDataDTO] {
        moistureValues.enumerated().map { index, moisture in
            let daysBack = Double(moistureValues.count - 1 - index)
            return createSensorData(moisture: moisture, date: end.addingTimeInterval(-daysBack * 24 * 3600))
        }
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
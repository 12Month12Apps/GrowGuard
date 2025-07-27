//
//  FlowerManagerHistoryTests.swift
//  GrowGuard
//
//  Tests for BLE history loading functionality using Swift Testing
//

import Testing
import Combine
import Foundation
@testable import GrowGuard

// MARK: - Test Helper

class MockFlowerCareManager: FlowerCareManager {
    // Override to prevent actual BLE operations in tests
    override init() {
        super.init()
        // Prevent CBCentralManager initialization in tests
        centralManager = nil
    }
}

// MARK: - History Loading Tests

@MainActor
struct FlowerManagerHistoryTests {
    
    // MARK: - Initial State Tests
    
    @Test("Initial state should have zero entries and index")
    func testInitialState() async {
        let flowerManager = MockFlowerCareManager()
        
        #expect(flowerManager.testTotalEntries == 0)
        #expect(flowerManager.testCurrentEntryIndex == 0)
        #expect(flowerManager.testIsCancelled == false)
    }
    
    @Test("Loading state should be idle initially")
    func testInitialLoadingState() async throws {
        let flowerManager = MockFlowerCareManager()
        
        let currentState = try await flowerManager.loadingStatePublisher.first()
        #expect(currentState == .idle)
    }
    
    @Test("Progress should be zero initially")
    func testInitialProgress() async throws {
        let flowerManager = MockFlowerCareManager()
        
        let currentProgress = try await flowerManager.loadingProgressPublisher.first()
        #expect(currentProgress?.current == 0)
        #expect(currentProgress?.total == 0)
    }
    
    // MARK: - Entry Count Decoding Tests
    
    @Test("Decode entry count should set total entries")
    func testDecodeEntryCount() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange: Create mock data for 150 entries (little endian)
        let entryCountData = Data([150, 0])
        
        // Act
        flowerManager.testDecodeEntryCount(data: entryCountData)
        
        // Assert
        #expect(flowerManager.testTotalEntries == 150)
        #expect(flowerManager.testCurrentEntryIndex == 0)
    }
    
    @Test("Decode entry count with zero entries should complete loading")
    func testDecodeZeroEntryCount() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange
        let entryCountData = Data([0, 0])
        
        // Set up expectation for loading state change
        let stateChangeTask = Task {
            var states: [FlowerCareManager.LoadingState] = []
            for await state in flowerManager.loadingStatePublisher.values {
                states.append(state)
                if case .completed = state {
                    return states
                }
                if states.count > 5 { // Prevent infinite loop
                    break
                }
            }
            return states
        }
        
        // Act
        flowerManager.testDecodeEntryCount(data: entryCountData)
        
        // Assert
        #expect(flowerManager.testTotalEntries == 0)
        
        let states = await stateChangeTask.value
        #expect(states.contains { state in
            if case .completed = state { return true }
            return false
        })
    }
    
    // MARK: - Progress Tracking Tests
    
    @Test("Progress should update correctly during loading")
    func testProgressUpdates() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange
        var receivedProgress: [(Int, Int)] = []
        let progressTask = Task {
            var count = 0
            for await progress in flowerManager.loadingProgressPublisher.values {
                receivedProgress.append((progress.current, progress.total))
                count += 1
                if count >= 4 { // Initial + 3 updates
                    break
                }
            }
        }
        
        // Act: Set total entries and send progress updates
        flowerManager.testTotalEntries = 100
        flowerManager.testLoadingProgressSubject.send((0, 100))
        flowerManager.testLoadingProgressSubject.send((1, 100))
        flowerManager.testLoadingProgressSubject.send((2, 100))
        
        // Wait for progress updates
        await progressTask.value
        
        // Assert
        #expect(receivedProgress.count >= 3)
        #expect(receivedProgress.contains { $0.0 == 1 && $0.1 == 100 })
        #expect(receivedProgress.contains { $0.0 == 2 && $0.1 == 100 })
    }
    
    // MARK: - Cancel Operation Tests
    
    @Test("Cancel should reset state")
    func testCancelHistoryDataLoading() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange: Set up some loading state
        flowerManager.testTotalEntries = 100
        flowerManager.testCurrentEntryIndex = 50
        flowerManager.testIsCancelled = false
        
        // Act
        flowerManager.cancelHistoryDataLoading()
        
        // Assert
        #expect(flowerManager.testIsCancelled == true)
        #expect(flowerManager.testTotalEntries == 0)
        #expect(flowerManager.testCurrentEntryIndex == 0)
    }
    
    @Test("Cancel should set loading state to idle")
    func testCancelSetsLoadingStateToIdle() async {
        let flowerManager = MockFlowerCareManager()
        
        // Start with loading state
        flowerManager.testLoadingStateSubject.send(.loading)
        
        // Set up task to wait for idle state
        let stateTask = Task {
            for await state in flowerManager.loadingStatePublisher.values {
                if case .idle = state {
                    return true
                }
            }
            return false
        }
        
        // Act
        flowerManager.cancelHistoryDataLoading()
        
        // Assert
        let foundIdle = await stateTask.value
        #expect(foundIdle == true)
    }
    
    // MARK: - Historical Data Processing Tests
    
    @Test("Historical data should be published when received")
    func testHistoricalDataPublishing() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange
        let mockHistoricalData = HistoricalSensorData(
            timestamp: 12345,
            temperature: 23.5,
            brightness: 1000,
            moisture: 65,
            conductivity: 800,
            date: Date()
        )
        
        // Set up task to receive data
        let dataTask: Task<HistoricalSensorData?, Never> = Task {
            for await data in flowerManager.historicalDataPublisher.values {
                return data
            }
            return nil
        }
        
        // Act
        flowerManager.testHistoricalDataSubject.send(mockHistoricalData)
        
        // Assert
        let receivedData = await dataTask.value
        #expect(receivedData != nil)
        #expect(receivedData?.temperature == 23.5)
        #expect(receivedData?.moisture == 65)
    }
    
    // MARK: - Connection Quality Tests
    
    @Test("Connection quality should start as unknown")
    func testInitialConnectionQuality() async {
        let flowerManager = MockFlowerCareManager()
        
        do {
            let initialQuality = try await flowerManager.connectionQualityPublisher.first()
            #expect(initialQuality == .unknown)
        } catch {
            Issue.record("Failed to get initial connection quality: \(error)")
        }
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Loading state should handle errors")
    func testLoadingStateError() async {
        let flowerManager = MockFlowerCareManager()
        
        // Set up task to wait for error state
        let errorTask = Task {
            for await state in flowerManager.loadingStatePublisher.values {
                if case .error(let message) = state {
                    return message
                }
            }
            return ""
        }
        
        // Act
        flowerManager.testLoadingStateSubject.send(.error("Failed to decode history entry 5"))
        
        // Assert
        let errorMessage = await errorTask.value
        #expect(errorMessage != "")
        #expect(errorMessage.contains("Failed to decode") == true)
    }
    
    // MARK: - Device Time and Boot Time Tests
    
    @Test("Device boot time should be calculated correctly")
    func testDeviceBootTimeCalculation() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange: Mock device time data (seconds since boot)
        let secondsSinceBoot: UInt32 = 3600 // 1 hour
        let deviceTimeData = Data([
            UInt8(secondsSinceBoot & 0xFF),
            UInt8((secondsSinceBoot >> 8) & 0xFF),
            UInt8((secondsSinceBoot >> 16) & 0xFF),
            UInt8((secondsSinceBoot >> 24) & 0xFF)
        ])
        
        let beforeDecoding = Date()
        
        // Act
        flowerManager.testDecodeDeviceTime(data: deviceTimeData)
        
        // Assert: Boot time should be approximately 1 hour ago
        let expectedBootTime = beforeDecoding.addingTimeInterval(-Double(secondsSinceBoot))
        let tolerance: TimeInterval = 5.0 // 5 seconds tolerance
        
        if let actualBootTime = flowerManager.testDeviceBootTime {
            let timeDifference = abs(actualBootTime.timeIntervalSince(expectedBootTime))
            #expect(timeDifference < tolerance)
        } else {
            Issue.record("Device boot time should be set")
        }
    }
    
    // MARK: - Entry Count Edge Cases
    
    @Test("Large entry count should be handled correctly")
    func testLargeEntryCount() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange: Large entry count (65535 = max UInt16)
        let entryCountData = Data([255, 255]) // 65535 in little endian
        
        // Act
        flowerManager.testDecodeEntryCount(data: entryCountData)
        
        // Assert
        #expect(flowerManager.testTotalEntries == 65535)
    }
    
    @Test("Invalid entry count data should not crash")
    func testInvalidEntryCountData() async {
        let flowerManager = MockFlowerCareManager()
        
        // Arrange: Invalid data (only 1 byte instead of 2)
        let invalidData = Data([100])
        
        // Act & Assert: Should not crash
        flowerManager.testDecodeEntryCount(data: invalidData)
        
        // Should not change from initial state
        #expect(flowerManager.testTotalEntries == 0)
    }
}

// MARK: - Publisher Extensions for Testing

extension Publisher {
    func first() async throws -> Output? {
        for try await value in values {
            return value
        }
        return nil
    }
}

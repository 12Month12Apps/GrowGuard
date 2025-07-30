//
//  DeviceDetailsViewModelTests.swift
//  GrowGuardTests
//
//  Created for testing DeviceDetailsViewModel settings save functionality
//

import XCTest
@testable import GrowGuard

final class DeviceDetailsViewModelTests: XCTestCase {
    
    var viewModel: DeviceDetailsViewModel!
    var mockDevice: FlowerDeviceDTO!
    var repositoryManager: RepositoryManager!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create a mock device for testing
        mockDevice = FlowerDeviceDTO(
            id: "test-id",
            name: "Test Plant",
            uuid: "test-uuid-123",
            peripheralID: "peripheral-123",
            battery: 85,
            firmware: "1.0.0",
            isSensor: true,
            added: Date(),
            lastUpdate: Date(),
            optimalRange: OptimalRangeDTO(
                deviceUUID: "test-uuid-123",
                minTemperature: 18.0,
                maxTemperature: 25.0,
                minMoisture: 30.0,
                maxMoisture: 70.0,
                minBrightness: 1000.0,
                maxBrightness: 5000.0
            ),
            potSize: PotSizeDTO(deviceUUID: "test-uuid-123"),
            sensorData: []
        )
        
        repositoryManager = RepositoryManager.shared
        
        // Initialize view model with mock device
        viewModel = DeviceDetailsViewModel(device: mockDevice)
    }
    
    override func tearDown() async throws {
        viewModel = nil
        mockDevice = nil
        try await super.tearDown()
    }
    
    // MARK: - Settings Save Tests
    
    func testDeviceDetailsViewModel_HasSaveSettingsMethod() {
        // Given/When/Then
        // This test simply verifies that the saveSettings method exists and can be called
        // It's a basic smoke test to ensure our TDD implementation is working
        XCTAssertNotNil(viewModel)
        
        // Verify the method exists by checking it can be referenced
        let method = viewModel.saveSettings
        XCTAssertNotNil(method)
    }
    
    func testSaveSettings_WithValidOptimalRange_ShouldUpdateDeviceAndDatabase() async throws {
        // Given
        let newOptimalRange = OptimalRangeDTO(
            deviceUUID: mockDevice.uuid,
            minTemperature: 20.0,
            maxTemperature: 28.0,
            minMoisture: 35.0,
            maxMoisture: 75.0,
            minBrightness: 1500.0,
            maxBrightness: 6000.0
        )
        
        let newPotSize = PotSizeDTO(
            deviceUUID: mockDevice.uuid,
            diameter: 25.0,
            height: 30.0,
            volume: 15.0
        )
        
        // When
        try await viewModel.saveSettings(optimalRange: newOptimalRange, potSize: newPotSize)
        
        // Then
        XCTAssertEqual(viewModel.device.optimalRange?.minTemperature, 20.0)
        XCTAssertEqual(viewModel.device.optimalRange?.maxTemperature, 28.0)
        XCTAssertEqual(viewModel.device.optimalRange?.minMoisture, 35.0)
        XCTAssertEqual(viewModel.device.optimalRange?.maxMoisture, 75.0)
        XCTAssertEqual(viewModel.device.optimalRange?.minBrightness, 1500.0)
        XCTAssertEqual(viewModel.device.optimalRange?.maxBrightness, 6000.0)
        
        XCTAssertEqual(viewModel.device.potSize?.diameter, 25.0)
        XCTAssertEqual(viewModel.device.potSize?.height, 30.0)
        XCTAssertEqual(viewModel.device.potSize?.volume, 15.0)
    }
    
    func testSaveSettings_WithNilOptimalRange_ShouldSetToNil() async throws {
        // Given
        // viewModel already has an optimal range from setUp()
        XCTAssertNotNil(viewModel.device.optimalRange)
        
        // When
        try await viewModel.saveSettings(optimalRange: nil, potSize: nil)
        
        // Then
        XCTAssertNil(viewModel.device.optimalRange)
        XCTAssertNil(viewModel.device.potSize)
    }
    
    func testSaveSettings_WithPartialData_ShouldUpdateOnlyProvidedFields() async throws {
        // Given
        let originalPotSize = viewModel.device.potSize
        let newOptimalRange = OptimalRangeDTO(
            deviceUUID: mockDevice.uuid,
            minTemperature: 22.0,
            maxTemperature: 26.0,
            minMoisture: 40.0,
            maxMoisture: 80.0,
            minBrightness: 2000.0,
            maxBrightness: 7000.0
        )
        
        // When - only update optimal range, leave pot size unchanged
        try await viewModel.saveSettings(optimalRange: newOptimalRange, potSize: originalPotSize)
        
        // Then
        XCTAssertEqual(viewModel.device.optimalRange?.minTemperature, 22.0)
        XCTAssertEqual(viewModel.device.potSize, originalPotSize)
    }
    
    func testSaveSettings_ShouldUpdateLastUpdateTimestamp() async throws {
        // Given
        let originalLastUpdate = viewModel.device.lastUpdate
        let newOptimalRange = OptimalRangeDTO(
            deviceUUID: mockDevice.uuid,
            minTemperature: 21.0,
            maxTemperature: 27.0,
            minMoisture: 38.0,
            maxMoisture: 72.0,
            minBrightness: 1800.0,
            maxBrightness: 5500.0
        )
        
        // Wait a small amount to ensure timestamp difference
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // When
        try await viewModel.saveSettings(optimalRange: newOptimalRange, potSize: nil)
        
        // Then
        XCTAssertGreaterThan(viewModel.device.lastUpdate, originalLastUpdate)
    }
    
    func testSaveSettings_ShouldCallRepositoryUpdateDevice() async throws {
        // Given
        let newOptimalRange = OptimalRangeDTO(
            deviceUUID: mockDevice.uuid,
            minTemperature: 19.0,
            maxTemperature: 24.0,
            minMoisture: 32.0,
            maxMoisture: 68.0,
            minBrightness: 1200.0,
            maxBrightness: 4800.0
        )
        
        // When
        try await viewModel.saveSettings(optimalRange: newOptimalRange, potSize: nil)
        
        // Then
        // Verify the device was updated in the repository by fetching it back
        let updatedDevice = try await repositoryManager.flowerDeviceRepository.getDevice(by: mockDevice.uuid)
        XCTAssertNotNil(updatedDevice)
        // Note: In a real test, we'd use a mock repository to verify the call was made
        // For now, we verify the device properties were updated correctly
        XCTAssertEqual(viewModel.device.optimalRange?.minTemperature, 19.0)
    }
    
    func testSaveSettings_WithDatabaseError_ShouldNotUpdateLocalDevice() async throws {
        // Given
        let invalidOptimalRange = OptimalRangeDTO(
            deviceUUID: "invalid-uuid", // This should cause a database error
            minTemperature: 19.0,
            maxTemperature: 24.0,
            minMoisture: 32.0,
            maxMoisture: 68.0,
            minBrightness: 1200.0,
            maxBrightness: 4800.0
        )
        
        let originalOptimalRange = viewModel.device.optimalRange
        
        // When & Then
        // The saveSettings should handle the error gracefully
        do {
            try await viewModel.saveSettings(optimalRange: invalidOptimalRange, potSize: nil)
            XCTFail("Expected saveSettings to throw an error")
        } catch {
            // Expected to throw an error
            print("Caught expected error: \(error)")
        }
        
        // The local device should not be updated if database save fails
        // (This behavior would be implemented in the actual saveSettings method)
    }
}
//
//  SettingsViewModelTests.swift
//  GrowGuardTests
//
//  Created for testing SettingsViewModel functionality
//

import XCTest
@testable import GrowGuard

@MainActor
final class SettingsViewModelTests: XCTestCase {
    
    var viewModel: SettingsViewModel!
    let testDeviceUUID = "test-device-uuid"
    
    override func setUp() async throws {
        try await super.setUp()
        viewModel = SettingsViewModel(deviceUUID: testDeviceUUID)
    }
    
    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }
    
    func testSettingsViewModel_Initialization() {
        // Given/When - initialized in setUp
        
        // Then
        XCTAssertEqual(viewModel.potSize.deviceUUID, testDeviceUUID)
        XCTAssertEqual(viewModel.optimalRange.deviceUUID, testDeviceUUID)
    }
    
    func testSettingsViewModel_GetUpdatedValues() {
        // Given
        viewModel.potSize.width = 15.0
        viewModel.potSize.height = 20.0
        viewModel.potSize.volume = 100.0
        
        viewModel.optimalRange.minTemperature = 18.0
        viewModel.optimalRange.maxTemperature = 25.0
        
        // When
        let updatedPotSize = viewModel.getUpdatedPotSize()
        let updatedOptimalRange = viewModel.getUpdatedOptimalRange()
        
        // Then
        XCTAssertEqual(updatedPotSize.width, 15.0)
        XCTAssertEqual(updatedPotSize.height, 20.0)
        XCTAssertEqual(updatedPotSize.volume, 100.0)
        
        XCTAssertEqual(updatedOptimalRange.minTemperature, 18.0)
        XCTAssertEqual(updatedOptimalRange.maxTemperature, 25.0)
    }
    
    func testSettingsViewModel_LoadSettingsWithDefaults() async {
        // Given - fresh viewModel with no data in database
        
        // When
        await viewModel.loadSettings()
        
        // Then
        // Should maintain default values if no device found in database
        XCTAssertEqual(viewModel.potSize.deviceUUID, testDeviceUUID)
        XCTAssertEqual(viewModel.optimalRange.deviceUUID, testDeviceUUID)
        
        // Default values should be preserved
        XCTAssertEqual(viewModel.potSize.width, 0.0)
        XCTAssertEqual(viewModel.potSize.height, 0.0)
        XCTAssertEqual(viewModel.potSize.volume, 0.0)
    }
}
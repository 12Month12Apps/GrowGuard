//
//  AddDeviceViewModelTests.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Testing
@testable import GrowGuard
import CoreBluetooth

protocol CBPeripheralProtocol {
    var identifier: UUID { get }
}

//class AddDeviceViewModelTests {
//    var viewModel: AddDeviceViewModel!
//
//    @MainActor
//    func setupMockedDataService() {
//        
//        let mock = CBPeripheral()
//        
//        let device1 = FlowerDevice(added: Date(), lastUpdate: Date(), peripheral: CBPeripheralMock1)
//        let device2 = FlowerDevice(added: Date(), lastUpdate: Date(), peripheral: CBPeripheralMock2)
//
//        DataService.sharedModelContainer.mainContext.insert(device1)
//        DataService.sharedModelContainer.mainContext.insert(device2)
//
//        do {
//            try DataService.sharedModelContainer.mainContext.save()
//        } catch {
//            print(error.localizedDescription)
//        }
//    }
//
//    @Test("Test tapOnDevice with new device")
//    func testTapOnDeviceAddsNewDevice() async {
//        // Arrange
//        setupMockedDataService()
//        viewModel = AddDeviceViewModel()
//
//        let newPeripheral = CBPeripheralMock(id: "3") // Mock a new peripheral
//        
//        // Act
//        await viewModel.tapOnDevice(peripheral: newPeripheral)
//
//        // Assert
//        #expect(viewModel.devices.count == 1) // New device should be added
//        #expect(viewModel.devices[0].identifier.uuidString == "3") // Check the identifier
//        #expect(viewModel.allSavedDevices.count == 3) // Now there should be 3 saved devices
//    }
//
//    @Test("Test tapOnDevice with existing device")
//    func testTapOnDeviceDoesNotAddExistingDevice() async {
//        // Arrange
//        setupMockedDataService()
//        viewModel = AddDeviceViewModel()
//
//        let existingPeripheral = CBPeripheralMock(id: "1") // Mock an existing peripheral
//        
//        // Act
//        await viewModel.tapOnDevice(peripheral: existingPeripheral)
//
//        // Assert
//        #expect(viewModel.devices.count == 0) // Existing device should not be added
//        #expect(viewModel.allSavedDevices.count == 2) // Should still have 2 saved devices
//    }
//
//    @Test("Test fetchSavedDevices")
//    func testFetchSavedDevices() async {
//        // Arrange
//        setupMockedDataService()
//        viewModel = AddDeviceViewModel()
//        
//        // Act
//        await viewModel.fetchSavedDevices()
//
//        // Assert
//        #expect(viewModel.allSavedDevices.count == 2) // Should retrieve the 2 mocked devices
//    }
//}

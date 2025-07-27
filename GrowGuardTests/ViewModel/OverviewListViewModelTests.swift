//
//  OverviewListViewModelTests.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Testing
@testable import GrowGuard

class OverviewListViewModelTests {
    
    var viewModel: OverviewListViewModel!
    let context = DataService.shared.context

    @MainActor
    func setupMockedDataService() {
        let device1 = FlowerDevice(context: context)
        device1.name = "Rose"
        device1.uuid = "1"
        
        let device2 = FlowerDevice(context: context)
        device2.name = "Tulip"
        device2.uuid = "2"
        
        DataService.shared.context.insert(device1)
        DataService.shared.context.insert(device2)

        do {
            try DataService.shared.context.save()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    @Test("Test fetchSavedDevices with successful fetch")
    func testFetchSavedDevicesSuccess() async {
        await setupMockedDataService()
        
        viewModel = OverviewListViewModel()
        
        await viewModel.fetchSavedDevices()
        
        #expect(viewModel.allSavedDevices.count == 2)
        #expect(viewModel.allSavedDevices[0].uuid == "1")
        #expect(viewModel.allSavedDevices[0].name == "Rose")
        #expect(viewModel.allSavedDevices[1].uuid == "2")
        #expect(viewModel.allSavedDevices[1].name == "Tulip")
    }

    @Test("Test fetchSavedDevices with zero entries")
    func testFetchSavedDevicesZero() async {
        viewModel = OverviewListViewModel()
        
        await viewModel.fetchSavedDevices()
        
        #expect(viewModel.allSavedDevices.isEmpty)
    }
}

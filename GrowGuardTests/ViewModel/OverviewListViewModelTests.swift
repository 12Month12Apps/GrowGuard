//
//  OverviewListViewModelTests.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Testing
import CoreData
@testable import GrowGuard

/// These tests run against the shared DataService Core Data store, so they
/// are serialized and each test clears existing FlowerDevice rows first —
/// otherwise leftovers from earlier runs (the store persists on the
/// simulator) make counts unpredictable.
@Suite(.serialized)
class OverviewListViewModelTests {

    var viewModel: OverviewListViewModel!
    let context = DataService.shared.context

    @MainActor
    private func deleteAllDevices() throws {
        let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "FlowerDevice")
        let devices = try context.fetch(request)
        for case let device as NSManagedObject in devices {
            context.delete(device)
        }
        try context.save()
    }

    @MainActor
    private func insertTestDevices() throws {
        let device1 = FlowerDevice(context: context)
        device1.name = "Rose"
        device1.uuid = "1"
        device1.added = Date()
        device1.lastUpdate = Date()

        let device2 = FlowerDevice(context: context)
        device2.name = "Tulip"
        device2.uuid = "2"
        device2.added = Date()
        device2.lastUpdate = Date()

        try context.save()
    }

    @Test("Test fetchSavedDevices with successful fetch")
    func testFetchSavedDevicesSuccess() async throws {
        try await deleteAllDevices()
        try await insertTestDevices()

        viewModel = OverviewListViewModel()

        await viewModel.fetchSavedDevices()

        #expect(viewModel.allSavedDevices.count == 2)

        let rose = viewModel.allSavedDevices.first { $0.uuid == "1" }
        let tulip = viewModel.allSavedDevices.first { $0.uuid == "2" }
        #expect(rose?.name == "Rose")
        #expect(tulip?.name == "Tulip")
    }

    @Test("Test fetchSavedDevices with zero entries")
    func testFetchSavedDevicesZero() async throws {
        try await deleteAllDevices()

        viewModel = OverviewListViewModel()

        await viewModel.fetchSavedDevices()

        #expect(viewModel.allSavedDevices.isEmpty)
    }
}

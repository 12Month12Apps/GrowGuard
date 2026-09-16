//
//  NavigationServiceTests.swift
//  GrowGuard
//
//  Covers the per-tab navigation paths and the stable route identity that the
//  navigation restructure relies on. `NavigationService.shared` is a singleton,
//  so the suite is serialized and each test resets the paths first.
//

import Testing
import Foundation
@testable import GrowGuard

@Suite(.serialized)
class NavigationServiceTests {

    private let service = NavigationService.shared

    init() {
        service.overviewPath = []
        service.addDevicePath = []
        service.selectedTab = .overview
    }

    private func makeDevice(uuid: String, name: String = "Plant", battery: Int16 = 0) -> FlowerDeviceDTO {
        FlowerDeviceDTO(name: name, uuid: uuid, battery: battery)
    }

    // MARK: Overview tab

    @Test("showDeviceDetail pushes exactly one route onto the overview path")
    func showDeviceDetailPushesOne() {
        service.showDeviceDetail(makeDevice(uuid: "abc"))
        #expect(service.overviewPath.count == 1)
        #expect(service.overviewPath == [.deviceDetail(makeDevice(uuid: "abc"))])
    }

    @Test("Device detail route identity ignores mutable fields (stable while data loads)")
    func routeStableAcrossMutation() {
        // Same device UUID, different volatile fields (name/battery stand in for
        // the sensorData that grows while history loads).
        let early = OverviewRoute.deviceDetail(makeDevice(uuid: "abc", name: "A", battery: 10))
        let loaded = OverviewRoute.deviceDetail(makeDevice(uuid: "abc", name: "B", battery: 90))
        #expect(early == loaded)
        #expect(early.hashValue == loaded.hashValue)
    }

    @Test("Device detail routes differ when the device UUID differs")
    func routeDistinctByUUID() {
        let first = OverviewRoute.deviceDetail(makeDevice(uuid: "abc"))
        let second = OverviewRoute.deviceDetail(makeDevice(uuid: "xyz"))
        #expect(first != second)
    }

    // MARK: Add Device tab

    @Test("Add Device routes push onto the add-device path only")
    func addDeviceRoutesPush() {
        let device = DiscoveredDevice(id: UUID(), name: "Sensor")
        service.showSensorDetails(device: device, suggestedName: "Plant 1")
        service.showAddWithoutSensor()
        service.showSpeciesDetails(VMSpecies(name: "Rose", id: 1))
        #expect(service.addDevicePath.count == 3)
        #expect(service.overviewPath.isEmpty)
    }

    // MARK: Cross-tab

    @Test("finishAddingDevice switches to overview with one detail and clears add path")
    func finishAddingDevice() {
        service.addDevicePath = [.withoutSensor]
        service.selectedTab = .addDevice

        service.finishAddingDevice(makeDevice(uuid: "xyz"))

        #expect(service.selectedTab == .overview)
        #expect(service.overviewPath == [.deviceDetail(makeDevice(uuid: "xyz"))])
        #expect(service.addDevicePath.isEmpty)
    }

    @Test("popToRoot clears both tab paths")
    func popToRootClearsBoth() {
        service.showDeviceDetail(makeDevice(uuid: "abc"))
        service.showAddWithoutSensor()

        service.popToRoot()

        #expect(service.overviewPath.isEmpty)
        #expect(service.addDevicePath.isEmpty)
    }
}

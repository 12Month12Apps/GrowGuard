//
//  BridgeDeviceDiscoveryTests.swift
//  GrowGuardTests
//
//  Confirms the bridge-backed Add Device discovery translates a scan into a
//  DiscoveredDevice — isolating discovery logic from the live socket.
//

#if DEBUG
import XCTest
import CoreBluetooth
@testable import GrowGuard

final class BridgeDeviceDiscoveryTests: XCTestCase {

    private static let simID = "FACE0001-0000-0000-0000-00000000FACE"

    func testReadyTriggersScanAndReportsPoweredOn() {
        let channel = FakeBridgeChannel()
        let discovery = BridgeDeviceDiscovery(channel: channel)
        var state: CBManagerState?
        discovery.onState = { state = $0 }

        discovery.start() // FakeBridgeChannel.connect() fires onReady synchronously

        XCTAssertEqual(state, .poweredOn)
        XCTAssertEqual(channel.sent, [.scan])
    }

    func testDiscoveredSurfacesDevice() {
        let channel = FakeBridgeChannel()
        let discovery = BridgeDeviceDiscovery(channel: channel)
        var found: DiscoveredDevice?
        discovery.onFound = { found = $0 }
        discovery.start()

        channel.inject(.discovered(id: Self.simID, name: "Flower care", services: ["fe95"], rssi: -50))

        XCTAssertEqual(found?.name, "Flower care")
        XCTAssertEqual(found?.id.uuidString, Self.simID)
    }
}
#endif

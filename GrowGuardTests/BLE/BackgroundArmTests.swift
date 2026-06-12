//
//  BackgroundArmTests.swift
//  GrowGuardTests
//
//  Background-arm path of ConnectionPoolManager (spec
//  2026-06-12-background-ble-design.md): pending connects without
//  watchdog/retry, persisted across pool instances, armed publisher.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
struct BackgroundArmTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundArmTests-\(UUID().uuidString)")!

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeSensor() -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        central.register(sensor)
        return sensor
    }

    /// Lets the pool's Task-hopped delegate callbacks run
    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    @Test("armBackgroundConnect issues a connect and emits on the armed publisher")
    func armedConnectEmits() async {
        let pool = makePool()
        let sensor = makeSensor()
        var emitted: [String] = []
        let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
        defer { sub.cancel() }

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()

        #expect(central.connectRequests == [sensor.identifier])
        #expect(emitted == [sensor.identifier.uuidString])
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("Armed connect has no watchdog and no retry burn: stays pending and completes late")
    func armedConnectSurvivesLongPending() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        var emitted: [String] = []
        let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
        defer { sub.cancel() }

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()
        // Far past the 10 s foreground watchdog and all retry backoffs
        scheduler.advance(by: 120)
        await pump()

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        if case .error = connection.connectionState {
            Issue.record("Armed connect must never produce an error state")
        }
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests.count == 1, "No retry storm for armed connects")

        // The pending connect completes much later — wake event fires
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        #expect(emitted == [sensor.identifier.uuidString])
    }

    @Test("disarm removes the device and persists")
    func disarmPersists() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()
        pool.disarmBackgroundConnect(for: sensor.identifier.uuidString)

        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        let secondPool = makePool()
        #expect(!secondPool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("Armed set survives pool recreation (state-restoration relaunch)")
    func armedSetPersistsAcrossPoolInstances() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()

        let relaunchedPool = makePool()
        #expect(relaunchedPool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("didFailToConnect for an armed device burns no retries and stays armed")
    func armedFailToConnectStaysArmed() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()

        // Simulate iOS reporting a transient connect failure 3x
        for _ in 0..<3 {
            central.centralDelegate?.central(central, didFailToConnect: sensor, error: nil)
            await pump()
            scheduler.advance(by: 30)
            await pump()
        }

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        if case .error = connection.connectionState {
            Issue.record("Armed connect failure must not surface as error state")
        }
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("poweredOn re-issues pending connects for persisted armed devices")
    func poweredOnRearmsPersistedDevices() async {
        let sensor = makeSensor()
        defaults.set([sensor.identifier.uuidString], forKey: "ble_background_armed_devices")
        central.state = .poweredOff

        let pool = makePool()
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests.isEmpty)

        central.simulateStateChange(to: .poweredOn)
        await pump()

        #expect(central.connectRequests == [sensor.identifier])
    }

    @Test("willRestoreState emits wake for already-connected armed devices")
    func restoreEmitsForConnectedArmedDevice() async {
        let sensor = makeSensor()
        defaults.set([sensor.identifier.uuidString], forKey: "ble_background_armed_devices")
        sensor.state = .connected

        let pool = makePool()
        var emitted: [String] = []
        let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
        defer { sub.cancel() }

        central.centralDelegate?.central(central, willRestoreState: [sensor])
        await pump()

        #expect(emitted == [sensor.identifier.uuidString])
    }
}

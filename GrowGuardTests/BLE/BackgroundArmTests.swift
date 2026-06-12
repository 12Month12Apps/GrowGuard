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
}

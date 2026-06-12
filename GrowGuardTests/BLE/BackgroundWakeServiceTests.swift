//
//  BackgroundWakeServiceTests.swift
//  GrowGuardTests
//
//  Wake orchestration: armed connect completes → auth → live read →
//  save → status check → disconnect → disarm. Never re-arms.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
import UIKit
@testable import GrowGuard

@MainActor
struct BackgroundWakeServiceTests {

    final class Recorder {
        var saved: [(uuid: String, source: SensorDataSource)] = []
        var statusChecks: [String] = []
        var began = 0
        var ended = 0
    }

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundWakeServiceTests-\(UUID().uuidString)")!
    let recorder = Recorder()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeService(pool: ConnectionPoolManager,
                             deviceUUIDs: [String],
                             saveSucceeds: Bool = true) -> BackgroundBLEWakeService {
        let recorder = self.recorder
        let service = BackgroundBLEWakeService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveSample: { _, uuid, source in
                recorder.saved.append((uuid, source))
                return saveSucceeds
            },
            runStatusCheck: { uuid in recorder.statusChecks.append(uuid) },
            beginBackgroundTask: { recorder.began += 1; return UIBackgroundTaskIdentifier(rawValue: 7) },
            endBackgroundTask: { _ in recorder.ended += 1 }
        )
        service.start()
        return service
    }

    private func makeSensor() -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        central.register(sensor)
        return sensor
    }

    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    /// Pump + advance in small slices so scheduler work and main-actor
    /// Tasks interleave like in production
    private func settle(seconds: TimeInterval) async {
        let slices = max(1, Int(seconds / 0.1))
        for _ in 0..<slices {
            await pump()
            scheduler.advance(by: 0.1)
        }
        await pump()
    }

    @Test("Wake read happy path: save, status check, disconnect, disarm, bg-task bracket")
    func wakeReadHappyPath() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.map(\.uuid) == [sensor.identifier.uuidString])
        #expect(recorder.saved.map(\.source) == [.backgroundPush])
        #expect(recorder.statusChecks == [sensor.identifier.uuidString])
        #expect(recorder.began == 1)
        #expect(recorder.ended == 1)
        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(sensor.state == .disconnected, "Wake handler must disconnect to save sensor battery")
    }

    @Test("Disconnect before data ends the read cleanly and disarms (no re-arm)")
    func disconnectBeforeDataFinishesRead() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundTask)
        await pump()
        // Pending connect completes, then the sensor drops immediately
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        central.simulateDisconnect(of: sensor.identifier, error: nil)
        await settle(seconds: 1.0)

        #expect(recorder.saved.isEmpty)
        #expect(recorder.began == 1)
        #expect(recorder.ended == 1)
        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests.count == 1, "Wake handler must not re-arm")
    }
}

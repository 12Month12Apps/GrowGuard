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
@Suite(.serialized)
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
    let tracker = BackgroundTaskTracker(
        defaults: UserDefaults(suiteName: "BackgroundWakeServiceTests-tracker-\(UUID().uuidString)")!
    )
    /// Per-test center: lifecycle posts must not leak into parallel tests
    let notificationCenter = NotificationCenter()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeService(pool: ConnectionPoolManager,
                             deviceUUIDs: [String],
                             saveSucceeds: Bool = true,
                             duringSave: @escaping () async -> Void = {}) -> BackgroundBLEWakeService {
        let recorder = self.recorder
        let service = BackgroundBLEWakeService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveSample: { _, uuid, source in
                await duringSave()
                recorder.saved.append((uuid, source))
                return saveSucceeds
            },
            runStatusCheck: { uuid in recorder.statusChecks.append(uuid) },
            beginBackgroundTask: { recorder.began += 1; return UIBackgroundTaskIdentifier(rawValue: 7) },
            endBackgroundTask: { _ in recorder.ended += 1 },
            notificationCenter: notificationCenter,
            tracker: tracker
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
        await drainMainActor()
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

        let armed = await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        #expect(armed == 1)

        #expect(recorder.saved.map(\.uuid) == [sensor.identifier.uuidString])
        #expect(recorder.saved.map(\.source) == [.backgroundPush])
        #expect(recorder.statusChecks == [sensor.identifier.uuidString])
        #expect(recorder.began == 1)
        #expect(recorder.ended == 1)
        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(sensor.state == .disconnected, "Wake handler must disconnect to save sensor battery")

        let entry = tracker.executionHistory.first
        #expect(entry?.type == .bleWake)
        #expect(entry?.trigger == .silentPush, "The debug history must say a push caused this read")
        #expect(entry?.success == true)
        #expect(tracker.wakeReadSuccessCount == 1)
    }

    @Test("didEnterBackground notification arms pending connects (SwiftUI lifecycle: app-delegate callback is never called)")
    func enterBackgroundNotificationArms() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        _ = service // observer registered via start() in makeService

        notificationCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await pump()

        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests == [sensor.identifier])

        await settle(seconds: 2.0)
        #expect(recorder.saved.map(\.source) == [.backgroundTask])
        #expect(tracker.executionHistory.first?.trigger == .enterBackground)
    }

    @Test("A disconnect while the sample is being saved does not turn a saved read into a failure")
    func disconnectDuringSaveKeepsSavedOutcome() async {
        let pool = makePool()
        let sensor = makeSensor()
        let central = self.central
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString]) {
            // Sensor drops the link after sending data, before persistence finishes
            central.simulateDisconnect(of: sensor.identifier, error: nil)
            await drainMainActor()
        }

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.map(\.uuid) == [sensor.identifier.uuidString])
        #expect(recorder.statusChecks == [sensor.identifier.uuidString])
        #expect(recorder.ended == 1)
        #expect(tracker.executionHistory.map(\.detail) == [WakeReadOutcome.saved.rawValue])
        #expect(tracker.wakeReadSuccessCount == 1)
        #expect(tracker.wakeReadFailureCount == 0)
    }

    @Test("Wake read with a rejected sample is recorded as a failure")
    func rejectedSampleRecordedAsFailure() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString], saveSucceeds: false)

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        #expect(recorder.statusChecks.isEmpty)
        #expect(tracker.executionHistory.first?.detail == WakeReadOutcome.sampleRejected.rawValue)
        #expect(tracker.wakeReadFailureCount == 1)
    }

    @Test("Disconnect before data ends the read cleanly and disarms (no re-arm)")
    func disconnectBeforeDataFinishesRead() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(trigger: .refreshTask)
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

        let entry = tracker.executionHistory.first
        #expect(entry?.type == .bleWake)
        #expect(entry?.trigger == .refreshTask)
        #expect(entry?.success == false, "Failed wake reads must be visible, not silently dropped")
        #expect(entry?.detail == WakeReadOutcome.disconnected.rawValue)
        #expect(tracker.wakeReadFailureCount == 1)
    }
}

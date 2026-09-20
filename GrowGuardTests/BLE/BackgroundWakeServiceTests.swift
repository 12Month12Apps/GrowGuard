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
        var failedContacts: [String] = []
        var began = 0
        var ended = 0
    }

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundWakeServiceTests-\(UUID().uuidString)")!
    let recorder = Recorder()
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
            recordFailedContact: { uuid in recorder.failedContacts.append(uuid) },
            beginBackgroundTask: { recorder.began += 1; return UIBackgroundTaskIdentifier(rawValue: 7) },
            endBackgroundTask: { _ in recorder.ended += 1 },
            notificationCenter: notificationCenter
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

    @Test("A pending connect that never completed counts one failed contact on the next armAll")
    func stillArmedCountsFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        // The connect request is issued and iOS holds it open; the sensor
        // never advertises, so no callback ever arrives. That — and only that
        // — is the dead-sensor signature.
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts.isEmpty, "First trigger: nothing to judge yet")
        #expect(central.connectRequests == [sensor.identifier], "Precondition: the app did try")

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts == [sensor.identifier.uuidString])
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString), "Re-armed as before")
    }

    @Test("A device the app could not even ask for (not in the retrieve cache) is not a failed contact")
    func notInRetrieveCacheIsNotAFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.peripheralsAreInRetrieveCache = false   // no peripheral, so no connect is issued
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await pump()
        await service.armAll(source: .backgroundPush)
        await pump()

        #expect(central.connectRequests.isEmpty, "Precondition: the app never issued a connect")
        #expect(recorder.failedContacts.isEmpty,
                "Staying armed without a connect says nothing about the sensor")
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("Bluetooth being off is not a failed contact")
    func bluetoothOffIsNotAFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        central.simulateStateChange(to: .poweredOff)
        await pump()

        await service.armAll(source: .backgroundPush)
        await pump()
        await service.armAll(source: .backgroundPush)
        await pump()

        #expect(central.connectRequests.isEmpty, "Precondition: the radio was off, no connect issued")
        #expect(recorder.failedContacts.isEmpty, "The radio was off — the sensor was never asked")
    }

    /// iOS drops every pending connect when the central leaves `.poweredOn`.
    /// If the pool keeps remembering that it issued one, the next trigger reads
    /// a connect that no longer exists and blames the sensor for the radio.
    @Test("A Bluetooth power cycle is not a failed contact")
    func bluetoothPowerCycleIsNotAFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        let uuid = sensor.identifier.uuidString
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [uuid])

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(central.connectRequests == [sensor.identifier], "Precondition: a connect was issued")

        central.simulateStateChange(to: .poweredOff)
        await pump()

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts.isEmpty,
                "The radio went down — the pending connect died with it, not with the sensor")

        // Radio back: the pool re-arms from the armed set and re-issues, so a
        // genuinely silent sensor is counted again on the next trigger
        central.simulateStateChange(to: .poweredOn)
        await pump()
        #expect(pool.hasPendingBackgroundConnect(uuid), "poweredOn re-issues the connect")

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts == [uuid])
    }

    @Test("A wake already in progress is not counted as a failed contact")
    func wakeInProgressIsNotCountedAsFailure() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await pump()
        // Pending connect completes: the read is now open (no disconnect, no
        // timeout), so the device is still armed *and* has an active read
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString),
                "Precondition: the armed flag survives the connect completion")

        await service.armAll(source: .backgroundPush)
        await pump()

        #expect(recorder.failedContacts.isEmpty, "A wake in progress is not a failed contact")
    }

    @Test("A wake read that ends without data counts one failed contact")
    func failedWakeReadCountsFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundTask)
        await pump()
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        central.simulateDisconnect(of: sensor.identifier, error: nil)
        await settle(seconds: 1.0)

        #expect(recorder.failedContacts == [sensor.identifier.uuidString])
    }

    @Test("A successful wake read records no failed contact")
    func successfulWakeReadNoFailure() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.count == 1)
        #expect(recorder.failedContacts.isEmpty)
    }
}

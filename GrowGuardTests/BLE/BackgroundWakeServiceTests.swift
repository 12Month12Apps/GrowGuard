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
        var historySaved = 0
        /// Order of history writes and the end of the background task
        var events: [String] = []
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
                             historyBoundary: Date? = nil,
                             duringSave: @escaping () async -> Void = {
                                 // Default: nothing happens while the sample is saved
                             }) -> BackgroundBLEWakeService {
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
            endBackgroundTask: { _ in
                recorder.ended += 1
                recorder.events.append("end")
            },
            notificationCenter: notificationCenter,
            tracker: tracker,
            loadHistoryBoundary: { _ in historyBoundary },
            saveHistoricalEntry: { _, _ in
                // Suspends like a real Core Data write: a fire-and-forget save
                // would still be pending when the background task ends
                await Task.yield()
                await Task.yield()
                recorder.historySaved += 1
                recorder.events.append("history")
            }
        )
        service.start()
        return service
    }

    private func makeSensor() -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        central.register(sensor)
        return sensor
    }

    /// Real sensor order (recording 522a3a0d): index 0 newest, one per hour
    private func newestFirstHourlyEntries(count: Int, uptime: UInt32) -> [Data] {
        (0..<count).map { index in
            FlowerCareFrames.historyEntry(timestamp: uptime - UInt32((index + 1) * 3600),
                                          temperatureX10: 200,
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
    }

    /// Decoded date of entry `index` from `newestFirstHourlyEntries`
    private func storedEntryDate(index: Int) -> Date {
        Date().addingTimeInterval(-Double((index + 1) * 3600))
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

    @Test("After the live sample, the wake read fetches only history newer than the stored entries")
    func wakeReadAppendsIncrementalHistory() async {
        let pool = makePool()
        let sensor = makeSensor()
        sensor.historyEntries = newestFirstHourlyEntries(count: 6, uptime: sensor.uptimeSeconds)
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: storedEntryDate(index: 2))

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 3.0)

        #expect(recorder.saved.map(\.source) == [.backgroundPush])
        #expect(recorder.historySaved == 2)
        #expect(sensor.servedEntryIndices == [0, 1, 2])
        #expect(recorder.events == ["history", "history", "end"],
                "iOS may suspend the app once the background task ends: the entries must be stored before that")
        #expect(tracker.executionHistory.first?.detail == "Saved · 2 history entries")
        #expect(tracker.wakeReadSuccessCount == 1)
        #expect(recorder.ended == 1)
        #expect(sensor.state == .disconnected)
    }

    @Test("Without any stored history the wake read does not start a full sync")
    func wakeReadSkipsHistoryWithoutStoredEntries() async {
        let pool = makePool()
        let sensor = makeSensor()
        sensor.historyEntries = newestFirstHourlyEntries(count: 6, uptime: sensor.uptimeSeconds)
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 3.0)

        #expect(sensor.servedEntryIndices.isEmpty)
        #expect(recorder.historySaved == 0)
        #expect(tracker.executionHistory.first?.detail == WakeReadOutcome.saved.rawValue)
    }

    @Test("A disconnect during the history phase keeps the read saved and ends the flow")
    func disconnectDuringHistoryKeepsSaved() async {
        let pool = makePool()
        let sensor = makeSensor()
        sensor.uptimeSeconds = 1_000_000 // 50 hourly entries need more than the default 100_000 s
        sensor.historyEntries = newestFirstHourlyEntries(count: 50, uptime: sensor.uptimeSeconds)
        sensor.silentEntryIndices = Set(1..<50) // sensor stalls after the first entry
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: storedEntryDate(index: 40))

        await service.armAll(trigger: .silentPush)
        for _ in 0..<50 where recorder.historySaved == 0 {
            await pump()
            scheduler.advance(by: 0.1)
        }
        #expect(recorder.historySaved == 1)

        central.simulateDisconnect(of: sensor.identifier, error: nil)
        // Longer than the 1 s clean-disconnect reconnect delay
        await settle(seconds: 2.5)

        #expect(central.connectRequests.count == 1,
                "The pool must not reconnect for a flow the wake read already ended")
        #expect(tracker.executionHistory.first?.detail == "Saved · 1 history entries")
        #expect(tracker.wakeReadFailureCount == 0)
        #expect(recorder.ended == 1)
        #expect(!pool.getConnection(for: sensor.identifier.uuidString).isHistoryFlowActive,
                "An abandoned flow would make the pool auto-reconnect in the background")
    }

    @Test("A link lost while saving leaves no stop boundary and finishes the read without waiting for the timeout")
    func disconnectDuringSaveWithHistoryBoundaryFinishesPromptly() async {
        let pool = makePool()
        let sensor = makeSensor()
        sensor.historyEntries = newestFirstHourlyEntries(count: 6, uptime: sensor.uptimeSeconds)
        let central = self.central
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: storedEntryDate(index: 2)) {
            // Sensor drops the link before the history phase can start
            central.simulateDisconnect(of: sensor.identifier, error: nil)
            await drainMainActor()
        }

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0) // well under the 9 s wake budget

        #expect(tracker.executionHistory.map(\.detail) == [WakeReadOutcome.saved.rawValue])
        #expect(recorder.ended == 1)
        #expect(sensor.servedEntryIndices.isEmpty)
        #expect(pool.getConnection(for: sensor.identifier.uuidString).historyStopBoundary == nil,
                "A stale boundary would cut the next foreground full sync short")
    }

    @Test("A wake read leaves a history flow another owner already started alone")
    func wakeReadSkipsForeignHistoryFlow() async {
        let pool = makePool()
        let sensor = makeSensor()
        sensor.historyEntries = newestFirstHourlyEntries(count: 6, uptime: sensor.uptimeSeconds)
        sensor.silentEntryIndices = Set(0..<6) // the other owner's flow stays mid-sync
        let foreignBoundary = storedEntryDate(index: 4)
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: storedEntryDate(index: 2)) {
            // A BGProcessing sync is already fetching on this pooled connection
            let connection = pool.getConnection(for: sensor.identifier.uuidString)
            connection.setHistoryStopBoundary(foreignBoundary)
            connection.startHistoryDataFlow()
            await drainMainActor()
        }

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(recorder.saved.map(\.source) == [.backgroundPush])
        #expect(recorder.historySaved == 0, "The owner of the flow stores its own entries")
        #expect(tracker.executionHistory.map(\.detail) == [WakeReadOutcome.saved.rawValue])
        #expect(connection.isHistoryFlowActive,
                "Ending someone else's flow would drop the entries it is still fetching")
        #expect(connection.historyStopBoundary == foreignBoundary,
                "The other owner's boundary must survive the wake read")
        #expect(sensor.state != .disconnected, "The other owner still needs the link")
    }

    @Test("Running out of time while the sample is being saved still counts as saved")
    func timeoutDuringSaveKeepsSavedOutcome() async {
        let pool = makePool()
        let sensor = makeSensor()
        let scheduler = self.scheduler
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString]) {
            // Persistence is slow: the 9 s wake budget runs out mid-save
            scheduler.advance(by: 10)
            await drainMainActor()
        }

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.map(\.uuid) == [sensor.identifier.uuidString])
        #expect(tracker.executionHistory.map(\.detail) == [WakeReadOutcome.saved.rawValue])
        #expect(tracker.wakeReadFailureCount == 0)
        #expect(recorder.ended == 1)
    }

    @Test("Running out of time while a rejected sample is written is not reported as saved")
    func timeoutDuringRejectedSaveIsNotSaved() async {
        let pool = makePool()
        let sensor = makeSensor()
        let scheduler = self.scheduler
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  saveSucceeds: false) {
            // The 9 s wake budget runs out before the store answers
            scheduler.advance(by: 10)
            await drainMainActor()
        }

        await service.armAll(trigger: .silentPush)
        await settle(seconds: 2.0)

        #expect(tracker.executionHistory.map(\.detail) == [WakeReadOutcome.sampleRejected.rawValue],
                "Only the store can say whether the sample was persisted")
        #expect(tracker.wakeReadSuccessCount == 0)
        #expect(recorder.ended == 1)
    }
}

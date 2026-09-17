//
//  BackgroundHistorySyncTests.swift
//  GrowGuardTests
//
//  Sequential history sync for BGProcessingTask windows: incremental sync per
//  device, expiration suspends cleanly.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
@Suite(.serialized)
struct BackgroundHistorySyncTests {

    final class Recorder {
        var savedEntries: [(deviceUUID: String, entry: HistoricalSensorData)] = []
        var done = false
    }

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundHistorySyncTests-\(UUID().uuidString)")!
    let recorder = Recorder()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeService(pool: ConnectionPoolManager,
                             deviceUUIDs: [String],
                             historyBoundary: Date? = nil) -> BackgroundHistorySyncService {
        let recorder = self.recorder
        return BackgroundHistorySyncService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveHistoricalEntry: { entry, uuid in
                recorder.savedEntries.append((uuid, entry))
            },
            loadHistoryBoundary: { _ in historyBoundary }
        )
    }

    private func makeSensor(entries: Int) -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.historyEntries = (0..<entries).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: Int16(200 + index),
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        central.register(sensor)
        return sensor
    }

    private func pump() async {
        await drainMainActor()
    }

    @Test("Syncs all history entries of a device, then completes and disconnects")
    func syncsAllEntries() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 3)
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }

        for _ in 0..<100 where !recorder.done {
            await pump()
            scheduler.advance(by: 0.5)
        }
        await pump()

        #expect(recorder.done, "syncAllDevices must complete")
        #expect(recorder.savedEntries.count == 3)
        #expect(recorder.savedEntries.allSatisfy { $0.deviceUUID == sensor.identifier.uuidString })
        #expect(sensor.state == .disconnected)
    }

    @Test("requestExpiration suspends the in-flight sync and returns")
    func expirationSuspends() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 50)
        sensor.silentEntryIndices = Set(5..<50) // sync stalls from entry 5
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }

        // Let the sync start and fetch the first few entries
        for _ in 0..<10 {
            await pump()
            scheduler.advance(by: 0.2)
        }
        #expect(!recorder.done)

        service.requestExpiration()
        await pump()

        #expect(recorder.done, "Expiration must make syncAllDevices return")
    }

    @Test("Stops at the newest stored entry instead of re-reading the whole sensor history")
    func syncStopsAtStoredHistory() async {
        let pool = makePool()
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        // Real sensor order: index 0 newest, one entry per hour
        sensor.historyEntries = (0..<6).map { index in
            FlowerCareFrames.historyEntry(timestamp: sensor.uptimeSeconds - UInt32((index + 1) * 3600),
                                          temperatureX10: 200,
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        central.register(sensor)
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: Date().addingTimeInterval(-3 * 3600))
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }

        for _ in 0..<100 where !recorder.done {
            await pump()
            scheduler.advance(by: 0.5)
        }
        await pump()

        #expect(recorder.done, "syncAllDevices must complete")
        #expect(recorder.savedEntries.count == 2)
        #expect(sensor.servedEntryIndices == [0, 1, 2])
    }

    @Test("A later window resumes a suspended incremental sync instead of cutting it short at its own saved entries")
    func resumedSyncKeepsItsBoundary() async {
        let pool = makePool()
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.uptimeSeconds = 1_000_000
        sensor.historyEntries = (0..<20).map { index in
            FlowerCareFrames.historyEntry(timestamp: sensor.uptimeSeconds - UInt32((index + 1) * 3600),
                                          temperatureX10: 200,
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        sensor.silentEntryIndices = [5] // first window stalls at entry 5
        central.register(sensor)
        let recorder = self.recorder
        let storedBoundary = Date().addingTimeInterval(-13 * 3600) // entry 12 is stored
        // Like production: the newest stored entry, including what the first window saved
        let service = BackgroundHistorySyncService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { [sensor.identifier.uuidString] },
            saveHistoricalEntry: { entry, uuid in
                recorder.savedEntries.append((uuid, entry))
            },
            loadHistoryBoundary: { _ in
                recorder.savedEntries.map(\.entry.date).max() ?? storedBoundary
            }
        )

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }
        for _ in 0..<100 where recorder.savedEntries.count < 5 {
            await pump()
            scheduler.advance(by: 0.1)
        }
        #expect(recorder.savedEntries.count == 5)

        service.requestExpiration()
        await pump()
        #expect(recorder.done)

        // Next window: the sensor answers again
        sensor.silentEntryIndices = []
        recorder.done = false
        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }
        for _ in 0..<200 where !recorder.done {
            await pump()
            scheduler.advance(by: 0.5)
        }
        await pump()

        #expect(recorder.done, "syncAllDevices must complete")
        #expect(Set(recorder.savedEntries.map(\.entry.date)).count == 12,
                "Entries 5...11 must still be fetched after the resume")
        #expect(pool.getConnection(for: sensor.identifier.uuidString).historyStopBoundary == nil)
    }

    @Test("A sync that ends without a history flow leaves no stop boundary for the next foreground full sync")
    func failedSyncClearsBoundary() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 3)
        central.connectSucceeds = false // sensor out of range: the flow never starts
        let service = makeService(pool: pool,
                                  deviceUUIDs: [sensor.identifier.uuidString],
                                  historyBoundary: Date().addingTimeInterval(-3600))
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }
        for _ in 0..<600 where !recorder.done {
            await pump()
            scheduler.advance(by: 1.0)
        }
        await pump()

        #expect(recorder.done, "syncAllDevices must complete")
        #expect(pool.getConnection(for: sensor.identifier.uuidString).historyStopBoundary == nil,
                "A stale boundary would turn the next foreground full sync incremental")
    }
}

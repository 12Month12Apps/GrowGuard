//
//  BackgroundHistorySyncTests.swift
//  GrowGuardTests
//
//  Sequential history sync for BGProcessingTask windows: full sync per
//  device, expiration suspends cleanly.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
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

    private func makeService(pool: ConnectionPoolManager, deviceUUIDs: [String]) -> BackgroundHistorySyncService {
        let recorder = self.recorder
        return BackgroundHistorySyncService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveHistoricalEntry: { entry, uuid in
                recorder.savedEntries.append((uuid, entry))
            }
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
        for _ in 0..<10 {
            await Task.yield()
        }
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
}

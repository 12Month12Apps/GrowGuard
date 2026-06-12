//
//  BLEPerformanceTests.swift
//  GrowGuardTests
//
//  Automated performance regression tests against the fake transport in
//  VIRTUAL time. Budgets derive from the protocol's own constants, never
//  from wall-clock measurements — they catch accidental traffic inflation
//  (re-fetch loops) and delay inflation (someone bumping an inter-entry
//  delay) without being flaky on CI.
//
//  Protocol cost model per entry (DeviceConnection):
//    0.02s inter-entry delay + fake response delays (2 × 0.01s)
//    + 0.05s batch pause every 150 entries
//

import Testing
import Combine
import Foundation
@testable import GrowGuard

@MainActor
struct BLEPerformanceTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central, scheduler: scheduler, now: { [scheduler] in scheduler.now })
    }

    private func makeSensor(entries: Int) -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.historyEntries = (0..<entries).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: 200,
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

    /// Drives the scheduler until the history flow started AND finished, or
    /// `limit` virtual seconds elapsed; returns the virtual completion time
    private func driveUntilComplete(connection: DeviceConnection, limit: TimeInterval) async -> TimeInterval {
        var started = connection.isHistoryLoading
        while scheduler.now < limit {
            scheduler.advance(by: 0.5)
            await pump()
            if connection.isHistoryLoading {
                started = true
            } else if started {
                break
            }
        }
        return scheduler.now
    }

    @Test("Traffic budget: N entries cost exactly N address writes, no re-fetches")
    func trafficBudget() async {
        let entryCount = 1000
        let pool = makePool()
        let sensor = makeSensor(entries: entryCount)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var received = 0
        let cancellable = connection.historicalDataPublisher.sink { _ in received += 1 }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        _ = await driveUntilComplete(connection: connection, limit: 120)

        #expect(received == entryCount)
        #expect(sensor.servedEntryIndices == Array(0..<entryCount),
                "Every entry fetched exactly once, in order")

        let historyWrites = sensor.writeLog.filter { $0.characteristic == historyControlCharacteristicUUID }
        // 0xa00000 (mode) + 0x3c (metadata) + one address write per entry
        #expect(historyWrites.count == entryCount + 2,
                "Unexpected history-control traffic: \(historyWrites.count) writes for \(entryCount) entries")
    }

    @Test("Virtual-time budget: download time scales with the protocol constants")
    func virtualTimeBudget() async {
        let entryCount = 1000
        let pool = makePool()
        let sensor = makeSensor(entries: entryCount)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        let finishedAt = await driveUntilComplete(connection: connection, limit: 120)

        #expect(!connection.isHistoryLoading, "Sync must complete inside the budget window")

        // Cost model: setup (connect/auth/history init) + per-entry costs
        // + batch pauses, with 25% headroom for scheduling slack and the
        // 0.5s drive-loop granularity
        let setupAllowance = 2.0
        let perEntry = 0.02 + 2 * 0.01
        let batchPauses = Double(entryCount / 150) * 0.05
        let budget = (setupAllowance + Double(entryCount) * perEntry + batchPauses) * 1.25

        #expect(finishedAt <= budget,
                "Sync took \(finishedAt)s virtual, budget is \(budget)s — an inter-entry delay probably grew")
    }

    @Test("Recovery budget: two mid-sync disconnects cost two reconnects and zero re-fetches")
    func recoveryBudget() async {
        let entryCount = 300
        let pool = makePool()
        let sensor = makeSensor(entries: entryCount)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 1.0)

        // Two unexpected disconnects at ~1/3 and ~2/3 of the sync
        for threshold in [100, 200] {
            var safety = 0
            while entries.count < threshold && safety < 2000 {
                scheduler.advance(by: 0.1)
                await pump()
                safety += 1
            }
            central.simulateDisconnect(of: sensor.identifier)
            await pump()
            scheduler.advance(by: 1.5) // reconnect delay + re-auth + resume
            await pump()
        }

        _ = await driveUntilComplete(connection: connection, limit: 120)

        #expect(entries.count == entryCount)
        #expect(Set(entries.map(\.timestamp)).count == entryCount, "No duplicate entries after resumes")
        #expect(central.connectRequests.count == 3, "Initial connect + exactly one reconnect per disconnect")

        // No index below a resume point may be fetched twice; only the two
        // in-flight boundary entries may legitimately repeat
        let serveCounts = Dictionary(grouping: sensor.servedEntryIndices, by: { $0 }).mapValues(\.count)
        let refetched = serveCounts.filter { $0.value > 1 }
        #expect(refetched.count <= 2, "Re-fetched more than the in-flight boundary entries: \(refetched.keys.sorted())")
        #expect(serveCounts.values.allSatisfy { $0 <= 2 })
    }
}

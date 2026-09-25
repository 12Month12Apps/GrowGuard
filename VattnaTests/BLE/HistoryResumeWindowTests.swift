//
//  HistoryResumeWindowTests.swift
//  VattnaTests
//
//  Regression tests for "history sync stuck at entry N".
//
//  FlowerCare 3.3.6 exposes an auth characteristic but never answers the
//  challenge — nothing in the app subscribes to notifications, so the response
//  can never arrive and EVERY connect ran into the 4 s auth timeout. On a weak
//  link the sensor drops the connection after a few seconds, so the sync asked
//  for its first history entry when the link was already gone: zero progress
//  per reconnect, frozen entry index, DisconnectLoopGuard aborts the sync.
//
//  These tests pin the budget that matters on real hardware: how much of a
//  short connection window is left for actual entries.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import Vattna

@MainActor
@Suite(.serialized)
struct HistoryResumeWindowTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central, scheduler: scheduler, now: { [scheduler] in scheduler.now })
    }

    /// Exactly the hardware from the field report: auth characteristic present,
    /// challenge never answered.
    private func makeSilentAuthSensor(entries: Int) -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.hasAuthCharacteristic = true
        sensor.respondsToAuth = false
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
        await drainMainActor()
    }

    private func firstEntryAddressWritten(_ sensor: FakeFlowerCarePeripheral) -> Bool {
        sensor.writeLog.contains {
            $0.characteristic == historyControlCharacteristicUUID && $0.data.first == 0xa1
        }
    }

    @Test("A silent auth characteristic must not eat the connection window")
    func firstEntryIsRequestedEarlyDespiteSilentAuth() async {
        let pool = makePool()
        let sensor = makeSilentAuthSensor(entries: 50)

        pool.connect(to: sensor.identifier.uuidString)
        await pump()

        var firstEntryRequestedAt: TimeInterval?
        while scheduler.now < 15 && firstEntryRequestedAt == nil {
            scheduler.advance(by: 0.05)
            await pump()
            if firstEntryAddressWritten(sensor) {
                firstEntryRequestedAt = scheduler.now
            }
        }

        #expect(firstEntryRequestedAt != nil, "History sync never requested a single entry")

        // A FlowerCare on a weak link holds the link only a few seconds. Setup
        // (discovery + auth + history init) must leave that window for entries.
        #expect((firstEntryRequestedAt ?? .infinity) <= 1.5,
                "First entry requested after \(firstEntryRequestedAt ?? -1)s of setup — the connection window is spent before any data is fetched")
    }

    @Test("History sync completes even when the sensor drops the link every 5 s")
    func syncSurvivesShortConnectionWindows() async {
        let entryCount = 300
        let windowLength: TimeInterval = 5.0
        let budget: TimeInterval = 200

        let pool = makePool()
        let sensor = makeSilentAuthSensor(entries: entryCount)
        let connection = pool.getConnection(for: sensor.identifier.uuidString)

        var entries: [HistoricalSensorData] = []
        let entriesCancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { entriesCancellable.cancel() }

        var loopDetected = false
        let stateCancellable = connection.connectionStatePublisher.sink { state in
            if case .error(let error) = state,
               case ConnectionError.disconnectLoopDetected = error {
                loopDetected = true
            }
        }
        defer { stateCancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()

        // The sensor drops the link `windowLength` after every connect,
        // regardless of what the app is doing — the weak-link failure mode.
        var handledConnects = 0
        var windowEnd: TimeInterval = .infinity

        while scheduler.now < budget && entries.count < entryCount {
            if central.connectRequests.count > handledConnects {
                handledConnects = central.connectRequests.count
                windowEnd = scheduler.now + windowLength
            }
            if scheduler.now >= windowEnd && sensor.state == .connected {
                windowEnd = .infinity
                central.simulateDisconnect(of: sensor.identifier,
                                           error: NSError(domain: CBErrorDomain,
                                                          code: CBError.connectionTimeout.rawValue))
                await pump()
            }
            scheduler.advance(by: 0.1)
            await pump()
        }

        #expect(!loopDetected,
                "Sync aborted with disconnectLoopDetected — no entry got through per connection window")
        #expect(entries.count == entryCount,
                "Sync stalled at \(entries.count)/\(entryCount) entries after \(scheduler.now)s virtual time")
    }
}

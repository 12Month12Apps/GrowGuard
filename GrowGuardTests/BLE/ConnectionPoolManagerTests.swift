//
//  ConnectionPoolManagerTests.swift
//  GrowGuardTests
//
//  Scenario tests for ConnectionPoolManager against the fake BLE transport
//  (BLE-Testing-Strategy.md, Phase 3). The pool hops its delegate callbacks
//  onto the main actor via Tasks, so tests pump the main actor between steps.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
struct ConnectionPoolManagerTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central, scheduler: scheduler)
    }

    private func makeSensor(entries: Int = 0) -> FakeFlowerCarePeripheral {
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

    /// Lets the pool's Task-hopped delegate callbacks run
    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    // MARK: - Tests

    @Test("getConnection returns one stable instance per device")
    func getConnectionReturnsSameInstance() {
        let pool = makePool()
        let first = pool.getConnection(for: "AAAAAAAA-0000-0000-0000-000000000001")
        let second = pool.getConnection(for: "AAAAAAAA-0000-0000-0000-000000000001")
        let other = pool.getConnection(for: "AAAAAAAA-0000-0000-0000-000000000002")

        #expect(first === second)
        #expect(first !== other)
    }

    @Test("Connect via retrieve cache reaches authenticated state")
    func connectThroughRetrieveCache() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)
        #expect(central.connectRequests == [sensor.identifier])
    }

    @Test("Unknown peripheral falls back to scanning and connects on discovery")
    func scanPathConnects() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.peripheralsAreInRetrieveCache = false

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()

        #expect(central.isScanning, "Pool should scan when the peripheral is not in the retrieve cache")

        central.simulateDiscovery(of: sensor.identifier)
        await pump()
        scheduler.advance(by: 0.2)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)
        #expect(!central.isScanning, "Scan should stop once the target device is found")
    }

    @Test("Connect requests are queued while Bluetooth is off and flushed on power-on")
    func queuedWhilePoweredOff() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.state = .poweredOff

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        #expect(central.connectRequests.isEmpty, "No connection attempt while Bluetooth is off")

        central.simulateStateChange(to: .poweredOn)
        await pump()
        await pump()
        scheduler.advance(by: 0.2)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)
    }

    @Test("Connection timeout retries and surfaces an error after max attempts")
    func timeoutRetriesThenFails() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()

        // attempt 1 timeout (10s) -> retry in 1s -> attempt 2 timeout -> retry in 2s
        // -> attempt 3 timeout -> max retries reached -> error
        for delay in [10.0, 1.0, 10.0, 2.0, 10.0, 3.0] {
            scheduler.advance(by: delay)
            await pump()
        }

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        if case .error = connection.connectionState {
            // expected
        } else {
            Issue.record("Expected error state after max retries, got \(String(describing: connection.connectionState))")
        }
        #expect(central.connectRequests.count == 3, "Should attempt exactly maxRetries connections")
    }

    @Test("Two devices get isolated connections and data streams")
    func multiDeviceIsolation() async {
        let pool = makePool()
        let sensorA = makeSensor()
        let sensorB = makeSensor()
        sensorB.liveDataFrame = FlowerCareFrames.liveSubZero

        pool.connect(to: sensorA.identifier.uuidString, autoStartHistoryFlow: false)
        pool.connect(to: sensorB.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)

        let connectionA = pool.getConnection(for: sensorA.identifier.uuidString)
        let connectionB = pool.getConnection(for: sensorB.identifier.uuidString)
        #expect(connectionA.connectionState == .authenticated)
        #expect(connectionB.connectionState == .authenticated)

        var tempsA: [Double] = []
        var tempsB: [Double] = []
        let c1 = connectionA.sensorDataPublisher.sink { tempsA.append($0.temperature) }
        let c2 = connectionB.sensorDataPublisher.sink { tempsB.append($0.temperature) }
        defer { c1.cancel(); c2.cancel() }

        connectionA.requestLiveData()
        connectionB.requestLiveData()
        scheduler.advance(by: 0.1)

        #expect(tempsA == [23.9])
        #expect(tempsB == [-1.5])
    }

    @Test("Unexpected disconnect during history triggers auto-reconnect and completes the sync")
    func autoReconnectCompletesHistory() async throws {
        let pool = makePool()
        let sensor = makeSensor(entries: 10)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 0.7) // discovery + auth + history start delay

        // Run until a few entries arrived
        var safety = 0
        while entries.count < 3 && safety < 200 {
            scheduler.advance(by: 0.05)
            safety += 1
        }
        #expect(entries.count >= 3)

        // Unexpected disconnect mid-flow
        central.simulateDisconnect(of: sensor.identifier)
        await pump()

        // Auto-reconnect waits 1.0s real time before the fast-reconnect attempt
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await pump()
        scheduler.advance(by: 1.0) // re-discovery + auth + resume delay
        await pump()
        scheduler.advance(by: 10.0) // drain remaining entries

        #expect(entries.count == 10, "History sync should complete after auto-reconnect")
        #expect(Set(entries.map(\.timestamp)).count == 10, "No duplicate entries after resume")
        #expect(!connection.isHistoryLoading)
    }
}

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
@Suite(.serialized)
struct ConnectionPoolManagerTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central, scheduler: scheduler, now: { [scheduler] in scheduler.now })
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

    /// Lets the pool's Task-hopped delegate callbacks run. Drains the main
    /// actor deterministically instead of yielding a fixed number of times.
    private func pump() async {
        await drainMainActor()
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

    @Test("Max-retries error is sticky until resetRetryCounter")
    func maxRetriesStickyUntilReset() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        for delay in [10.0, 1.0, 10.0, 2.0, 10.0, 3.0] {
            scheduler.advance(by: delay)
            await pump()
        }
        #expect(central.connectRequests.count == 3)

        // Further connect requests fail immediately without a new attempt
        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 15.0)
        await pump()
        #expect(central.connectRequests.count == 3, "No further attempts while the counter is exhausted")

        // Reset + working link -> fresh attempt succeeds
        pool.resetRetryCounter(for: sensor.identifier.uuidString)
        central.connectSucceeds = true
        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(central.connectRequests.count == 4)
        #expect(connection.connectionState == .authenticated)
    }

    @Test("Retry counter resets after a successful connection")
    func retryCounterResetsOnSuccess() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 10.0) // attempt 1 times out
        await pump()

        central.connectSucceeds = true
        scheduler.advance(by: 1.0) // retry fires -> attempt 2 succeeds
        await pump()
        scheduler.advance(by: 0.2)
        await pump()

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)
        #expect(central.connectRequests.count == 2)

        // Disconnect (no history flow -> no auto-reconnect), then fail again:
        // the counter starts fresh with the full 3 attempts
        central.simulateDisconnect(of: sensor.identifier)
        await pump()
        central.connectSucceeds = false
        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        for delay in [10.0, 1.0, 10.0, 2.0, 10.0, 3.0] {
            scheduler.advance(by: delay)
            await pump()
        }
        #expect(central.connectRequests.count == 5, "Successful connect resets the counter to allow 3 fresh attempts")
    }

    @Test("Normal disconnect without an active history flow does not auto-reconnect")
    func noAutoReconnectAfterNormalDisconnect() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)
        #expect(central.connectRequests.count == 1)

        central.simulateDisconnect(of: sensor.identifier)
        await pump()
        scheduler.advance(by: 10.0)
        await pump()

        #expect(central.connectRequests.count == 1, "No reconnect attempt after a normal disconnect")
    }

    @Test("Repeated disconnects without history progress trip the loop guard")
    func loopGuardStopsReconnectStorm() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 10)
        // Sensor never answers the metadata request -> history flow stays
        // active with zero progress on every reconnect
        sensor.suppressMetadataResponse = true

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 1.0) // discovery + auth + history start
        await pump()
        #expect(connection.shouldAutoReconnect, "History flow without metadata wants a reconnect")

        // Five disconnects with a frozen history index
        for _ in 0..<5 {
            central.simulateDisconnect(of: sensor.identifier)
            await pump()
            // reconnect delay (1s, reason .clean) + auth + history restart
            scheduler.advance(by: 1.8)
            await pump()
        }

        #expect(connection.connectionState == .error(ConnectionError.disconnectLoopDetected))
        #expect(!connection.isHistoryLoading)
        #expect(!connection.shouldAutoReconnect)

        let requestsAfterTrip = central.connectRequests.count
        scheduler.advance(by: 30.0)
        await pump()
        #expect(central.connectRequests.count == requestsAfterTrip, "No further reconnects after the guard tripped")
        #expect(requestsAfterTrip == 5, "Initial connect + four reconnects before the fifth stalled drop tripped the guard")
    }

    @Test("Dashboard live refresh starts a fresh retry budget after exhaustion")
    func dashboardRefreshResetsRetryBudget() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false

        // Exhaust the retry budget (e.g. sensor was out of range earlier)
        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        for delay in [10.0, 1.0, 10.0, 2.0, 10.0, 3.0] {
            scheduler.advance(by: delay)
            await pump()
        }
        #expect(central.connectRequests.count == 3)

        // Sensor is reachable again; the dashboard triggers its live refresh
        central.connectSucceeds = true
        let service = InitialSensorDataService(pool: pool)
        await service.requestLiveData(for: [sensor.identifier.uuidString])
        await pump()
        scheduler.advance(by: 0.2)
        await pump()

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(central.connectRequests.count == 4, "Dashboard refresh should grant a fresh connection attempt")
        #expect(connection.connectionState == .authenticated)
    }

    @Test("Sensor-initiated disconnect (CBError 7) surfaces as disconnected, not error")
    func sensorIdleDisconnectIsNotAnError() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)

        // FlowerCare sensors drop the link themselves after idle —
        // iOS reports that as CBError.peripheralDisconnected (code 7)
        let idleDisconnect = NSError(domain: CBErrorDomain,
                                     code: CBError.peripheralDisconnected.rawValue)
        central.simulateDisconnect(of: sensor.identifier, error: idleDisconnect)
        await pump()

        #expect(connection.connectionState == .disconnected)
    }

    @Test("Timeout retry keeps autoStartHistoryFlow disabled")
    func retryPreservesHistoryFlowFlag() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 5)
        central.connectSucceeds = false

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 10.0) // attempt 1 times out -> retry scheduled in 1s
        await pump()

        central.connectSucceeds = true
        scheduler.advance(by: 1.0) // retry fires -> attempt 2 succeeds
        await pump()
        scheduler.advance(by: 1.0) // auth + (potential) history start delay
        await pump()

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        #expect(connection.connectionState == .authenticated)
        #expect(!connection.isHistoryLoading, "Live-only session must not start the history flow after a retry")
    }

    /// One mid-flight history sync plus everything a test needs to poke at it.
    /// Holding this keeps the pool — and therefore its connections — alive.
    private final class MidFlightSync {
        let pool: ConnectionPoolManager
        let sensor: FakeFlowerCarePeripheral
        let connection: DeviceConnection
        private(set) var entries: [HistoricalSensorData] = []
        private var cancellable: AnyCancellable?

        init(pool: ConnectionPoolManager, sensor: FakeFlowerCarePeripheral, connection: DeviceConnection) {
            self.pool = pool
            self.sensor = sensor
            self.connection = connection
            cancellable = connection.historicalDataPublisher.sink { [weak self] entry in
                self?.entries.append(entry)
            }
        }
    }

    /// Drives a fresh pool + sensor until the history sync is mid-flight, i.e.
    /// at least `minEntries` entries have arrived. Models what the app is
    /// really doing when the user comes back to the overview during a sync.
    private func startSyncMidFlight(entryCount: Int = 10, minEntries: Int = 3) async -> MidFlightSync {
        let pool = makePool()
        let sensor = makeSensor(entries: entryCount)
        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        let sync = MidFlightSync(pool: pool, sensor: sensor, connection: connection)

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 0.7) // discovery + auth + history start delay

        var safety = 0
        while sync.entries.count < minEntries && safety < 200 {
            scheduler.advance(by: 0.05)
            safety += 1
        }
        return sync
    }

    /// Mid-sync disconnect plus the reconnect the FlowerCare forces on us
    /// constantly, then enough time for the resumed sync to drain.
    private func reconnectAndDrain(_ sync: MidFlightSync) async {
        central.simulateDisconnect(of: sync.sensor.identifier)
        await pump()
        scheduler.advance(by: 1.0) // auto-reconnect delay (clean disconnect)
        await pump()
        scheduler.advance(by: 1.0) // re-discovery + auth + resume delay
        await pump()
        scheduler.advance(by: 10.0) // drain remaining entries
    }

    @Test("Dashboard refresh leaves an active history sync untouched")
    func dashboardRefreshDoesNotBreakActiveHistorySync() async {
        let sync = await startSyncMidFlight()
        #expect(sync.entries.count >= 3, "Sync should be mid-flight before the dashboard appears")

        // User navigates back to the overview: dashboard triggers its
        // one-time live refresh for all sensors — including the syncing one
        let service = InitialSensorDataService(pool: sync.pool)
        await service.requestLiveData(for: [sync.sensor.identifier.uuidString])
        await pump()

        await reconnectAndDrain(sync)

        #expect(sync.entries.count == 10, "History sync must resume and complete despite the dashboard refresh")
        #expect(!sync.connection.isHistoryLoading)
    }

    @Test("Disabling auto-start is ignored while a history flow is active")
    func autoStartDisableIgnoredDuringActiveFlow() async {
        let sync = await startSyncMidFlight()
        #expect(sync.entries.count >= 3)

        // Live-only callers (background fetch) must not flip a running session
        sync.connection.setAutoStartHistoryFlowEnabled(false)
        #expect(sync.connection.autoStartHistoryFlowEnabled, "Disable is deferred while the flow is active")

        await reconnectAndDrain(sync)

        #expect(sync.entries.count == 10, "Sync resumes after reconnect even though a caller tried to disable auto-start")
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
        // write confirm + 0.25s read delay + read response
        scheduler.advance(by: 0.4)

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

        // Auto-reconnect fires via the scheduler (1.0s for a clean disconnect)
        scheduler.advance(by: 1.0)
        await pump()
        scheduler.advance(by: 1.0) // re-discovery + auth + resume delay
        await pump()
        scheduler.advance(by: 10.0) // drain remaining entries

        #expect(entries.count == 10, "History sync should complete after auto-reconnect")
        #expect(Set(entries.map(\.timestamp)).count == 10, "No duplicate entries after resume")
        #expect(!connection.isHistoryLoading)
    }

    // MARK: - Device events (sensor health seam)

    @Test("deviceEventsPublisher relays battery/firmware and live data tagged with the UUID")
    func deviceEventsRelayInfoAndData() async {
        let pool = makePool()
        let sensor = makeSensor()
        let uuid = sensor.identifier.uuidString
        var events: [DeviceEvent] = []
        let subscription = pool.deviceEventsPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        pool.connect(to: uuid, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.5)
        await pump()

        #expect(events.contains(.deviceInfo(uuid: uuid, info: .init(battery: 80, firmware: "3.2.9"))),
                "FakeFlowerCarePeripheral answers the firmware read with 80 % / 3.2.9")

        pool.getConnection(for: uuid).requestLiveData()
        scheduler.advance(by: 0.5)
        await pump()

        #expect(events.contains(.sensorData(uuid: uuid)))
        #expect(!events.contains(.attemptGaveUp(uuid: uuid)))
    }

    @Test("deviceEventsPublisher emits attemptGaveUp when the reconnect policy gives up")
    func deviceEventsGiveUp() async {
        let pool = makePool()
        let sensor = makeSensor()
        let uuid = sensor.identifier.uuidString
        central.connectSucceeds = false   // connect requests never complete → watchdog timeouts
        var events: [DeviceEvent] = []
        let subscription = pool.deviceEventsPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        pool.connect(to: uuid, autoStartHistoryFlow: false)
        for _ in 0..<40 {                 // 10 s timeout + backoff per attempt, 3 attempts
            await pump()
            scheduler.advance(by: 5)
        }
        await pump()

        #expect(events.filter { $0 == .attemptGaveUp(uuid: uuid) }.count == 1)
    }

    /// A history flow stalled mid-sync whose auto-reconnect fell back to
    /// scanning, so a test can end the flow while the pool is still looking
    /// for the sensor.
    /// - Returns: the pool, its connection and the connect requests so far
    private func reconnectScanForStalledFlow() async -> (pool: ConnectionPoolManager,
                                                         sensor: FakeFlowerCarePeripheral,
                                                         connection: DeviceConnection,
                                                         connectRequests: Int) {
        let pool = makePool()
        let sensor = makeSensor(entries: 50)
        sensor.silentEntryIndices = Set(3..<50) // flow stays active mid-sync
        let connection = pool.getConnection(for: sensor.identifier.uuidString)

        pool.connect(to: sensor.identifier.uuidString)
        for _ in 0..<20 {
            await pump()
            scheduler.advance(by: 0.1)
        }
        #expect(connection.isHistoryFlowActive)

        // Sensor gone from the retrieve cache: the reconnect has to scan
        central.peripheralsAreInRetrieveCache = false
        central.simulateDisconnect(of: sensor.identifier)
        for _ in 0..<25 {
            await pump()
            scheduler.advance(by: 0.1)
        }
        #expect(central.isScanning, "Fast reconnect attempts failed, the pool scans")

        return (pool, sensor, connection, central.connectRequests.count)
    }

    @Test("An auto-reconnect that fell back to scanning does not connect once the flow was ended meanwhile")
    func scanFallbackReconnectSkipsEndedFlow() async {
        let scan = await reconnectScanForStalledFlow()

        // The flow ends while scanning (e.g. the wake read finished)
        scan.connection.cleanupHistoryFlow()
        central.simulateDiscovery(of: scan.sensor.identifier)
        await pump()

        #expect(central.connectRequests.count == scan.connectRequests,
                "Nothing left to resume: waking the sensor would only drain its battery")
        #expect(!central.isScanning)
    }

    @Test("Disconnecting stops a reconnect scan that only existed to resume the ended flow")
    func disconnectStopsPendingReconnectScan() async {
        let scan = await reconnectScanForStalledFlow()

        // The wake read ends its flow and drops the device
        scan.connection.cleanupHistoryFlow()
        scan.pool.disconnect(from: scan.sensor.identifier.uuidString)
        await pump()

        #expect(!central.isScanning,
                "A scan nobody waits for keeps the radio busy until the sensor happens to advertise")

        central.simulateDiscovery(of: scan.sensor.identifier)
        await pump()
        #expect(central.connectRequests.count == scan.connectRequests)
    }
}

//
//  DeviceConnectionScenarioTests.swift
//  GrowGuardTests
//
//  Deterministic scenario tests for DeviceConnection against the scriptable
//  FakeFlowerCarePeripheral and a manually advanced TestScheduler — no real
//  Bluetooth, no real time (BLE-Testing-Strategy.md, Phase 3).
//

import Testing
import Combine
import Foundation
@testable import GrowGuard

struct DeviceConnectionScenarioTests {

    let scheduler = TestScheduler()

    private func makeSensor(entries: Int = 0,
                            hasAuth: Bool = false) -> (sensor: FakeFlowerCarePeripheral, connection: DeviceConnection) {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.hasAuthCharacteristic = hasAuth
        sensor.historyEntries = (0..<entries).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: Int16(200 + index),
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }

        let connection = DeviceConnection(deviceUUID: sensor.identifier.uuidString, scheduler: scheduler)
        connection.setPeripheral(sensor)
        return (sensor, connection)
    }

    /// Simulates the central having established the link
    private func connect(_ sensor: FakeFlowerCarePeripheral, _ connection: DeviceConnection) {
        sensor.state = .connected
        connection.handleConnected()
        scheduler.advance(by: 0.1) // service/characteristic discovery + auth round trips
    }

    // MARK: - Authentication

    @Test("Sensor without auth characteristic authenticates directly")
    func authenticatesWithoutAuthCharacteristic() {
        let (sensor, connection) = makeSensor()
        connection.setAutoStartHistoryFlowEnabled(false)

        connect(sensor, connection)

        #expect(connection.connectionState == .authenticated)
    }

    @Test("Challenge/response authentication completes")
    func authenticatesViaChallengeResponse() {
        let (sensor, connection) = makeSensor(hasAuth: true)
        connection.setAutoStartHistoryFlowEnabled(false)

        connect(sensor, connection)

        #expect(connection.connectionState == .authenticated)
        #expect(sensor.writeLog.contains { $0.characteristic == authenticationCharacteristicUUID && $0.data == Data([0x90, 0xCA, 0x85, 0xDE]) })
        #expect(sensor.writeLog.contains { $0.characteristic == authenticationCharacteristicUUID && $0.data == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) })
    }

    @Test("Silent auth characteristic falls back to authenticated after timeout")
    func authTimeoutFallsBackToAuthenticated() {
        let (sensor, connection) = makeSensor(hasAuth: true)
        connection.setAutoStartHistoryFlowEnabled(false)
        sensor.respondsToAuth = false

        connect(sensor, connection)
        #expect(connection.connectionState == .connected) // still waiting on auth

        scheduler.advance(by: 4.0) // auth timeout

        #expect(connection.connectionState == .authenticated)
    }

    // MARK: - Live Data

    @Test("Live data request publishes decoded sensor values")
    func liveDataDecodedAndPublished() {
        let (sensor, connection) = makeSensor()
        connection.setAutoStartHistoryFlowEnabled(false)
        connect(sensor, connection)

        var received: [SensorDataTemp] = []
        let cancellable = connection.sensorDataPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        connection.requestLiveData()
        scheduler.advance(by: 0.1)

        #expect(received.count == 1)
        #expect(received.first?.temperature == 23.9)
        #expect(received.first?.moisture == 51)
        #expect(sensor.writeLog.contains { $0.characteristic == deviceModeChangeCharacteristicUUID && $0.data == Data([0xA0, 0x1F]) })
    }

    @Test("Live data is blocked while history flow is active")
    func liveDataBlockedDuringHistoryFlow() {
        let (sensor, connection) = makeSensor(entries: 50)
        connect(sensor, connection)
        scheduler.advance(by: 1.2) // auto history flow start + metadata round trip

        #expect(connection.isHistoryLoading)

        connection.requestLiveData()
        #expect(!sensor.writeLog.contains { $0.data == Data([0xA0, 0x1F]) })
    }

    // MARK: - History Flow

    @Test("History happy path loads all entries and finishes")
    func historyHappyPath() {
        let (sensor, connection) = makeSensor(entries: 5)

        var entries: [HistoricalSensorData] = []
        var progress: [(Int, Int)] = []
        let c1 = connection.historicalDataPublisher.sink { entries.append($0) }
        let c2 = connection.historyProgressPublisher.sink { progress.append($0) }
        defer { c1.cancel(); c2.cancel() }

        connect(sensor, connection)
        scheduler.advance(by: 5.0)

        #expect(entries.count == 5)
        #expect(entries.map(\.timestamp) == [100, 160, 220, 280, 340])
        #expect(progress.last?.0 == 5)
        #expect(progress.last?.1 == 5)
        #expect(!connection.isHistoryLoading)
        #expect(sensor.servedEntryIndices == [0, 1, 2, 3, 4])
    }

    @Test("Empty history finishes cleanly without entries")
    func historyZeroEntries() {
        let (sensor, connection) = makeSensor(entries: 0)

        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        connect(sensor, connection)
        scheduler.advance(by: 5.0)

        #expect(entries.isEmpty)
        #expect(!connection.isHistoryLoading)
    }

    @Test("Metadata timeout aborts the flow cleanly")
    func metadataTimeoutCleansUp() {
        let (sensor, connection) = makeSensor(entries: 5)
        sensor.suppressMetadataResponse = true

        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        connect(sensor, connection)
        scheduler.advance(by: 15.0) // past the 10s metadata timeout

        #expect(entries.isEmpty)
        #expect(!connection.isHistoryLoading)
        #expect(!connection.shouldAutoReconnect)
    }

    @Test("Corrupt entry is skipped, flow still completes")
    func corruptEntrySkipped() {
        let (sensor, connection) = makeSensor(entries: 5)
        sensor.corruptEntryIndices = [2]

        var entries: [HistoricalSensorData] = []
        var progress: [(Int, Int)] = []
        let c1 = connection.historicalDataPublisher.sink { entries.append($0) }
        let c2 = connection.historyProgressPublisher.sink { progress.append($0) }
        defer { c1.cancel(); c2.cancel() }

        connect(sensor, connection)
        scheduler.advance(by: 5.0)

        #expect(entries.count == 4)
        #expect(entries.map(\.timestamp) == [100, 160, 280, 340]) // entry 2 skipped
        #expect(progress.last?.0 == 5)
        #expect(!connection.isHistoryLoading)
    }

    @Test("Disconnect mid-history resumes at the same entry without duplicates")
    func disconnectResumesAtSameEntry() {
        let (sensor, connection) = makeSensor(entries: 10)

        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        connect(sensor, connection)

        // Let the flow run until 4 entries have arrived
        var safety = 0
        while entries.count < 4 && safety < 200 {
            scheduler.advance(by: 0.05)
            safety += 1
        }
        #expect(entries.count == 4)

        // Unexpected disconnect mid-flow
        sensor.state = .disconnected
        connection.handleDisconnected(error: nil)

        #expect(connection.shouldAutoReconnect, "Should want to reconnect while history is incomplete")

        // No progress while disconnected
        scheduler.advance(by: 2.0)
        #expect(entries.count == 4)

        // Reconnect (what ConnectionPoolManager does after auto-reconnect)
        sensor.state = .connected
        connection.handleConnected()
        scheduler.advance(by: 10.0)

        #expect(entries.count == 10)
        #expect(Set(entries.map(\.timestamp)).count == 10, "No duplicate entries after resume")
        #expect(!connection.isHistoryLoading)
        #expect(!connection.shouldAutoReconnect)
    }

    @Test("Cancelling the history flow stops all further fetches")
    func cancelStopsFlow() {
        let (sensor, connection) = makeSensor(entries: 10)

        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        connect(sensor, connection)

        var safety = 0
        while entries.count < 2 && safety < 200 {
            scheduler.advance(by: 0.05)
            safety += 1
        }
        #expect(entries.count == 2)

        connection.cleanupHistoryFlow()
        let countAtCancel = entries.count

        scheduler.advance(by: 10.0)

        #expect(entries.count == countAtCancel, "No further entries after cancellation")
        #expect(!connection.isHistoryLoading)
        #expect(!connection.shouldAutoReconnect)
    }
}

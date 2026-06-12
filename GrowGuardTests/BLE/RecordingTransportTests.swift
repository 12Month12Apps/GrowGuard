//
//  RecordingTransportTests.swift
//  GrowGuardTests
//
//  Tests for the BLE recording decorators: they must be fully transparent
//  (identical behavior with and without them) and capture a faithful,
//  replayable event log of the transport traffic.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
struct RecordingTransportTests {

    let scheduler = TestScheduler()
    let fakeCentral = FakeCentral()
    let recorder: BLESessionRecorder
    let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ble-recordings-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "RecordingTransportTests-\(UUID().uuidString)")!
        recorder = BLESessionRecorder(defaults: defaults, directory: tempDirectory)
    }

    private func makePool(recordingCentral: RecordingBLECentral) -> ConnectionPoolManager {
        ConnectionPoolManager(central: recordingCentral, scheduler: scheduler)
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
        fakeCentral.register(sensor)
        return sensor
    }

    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    // MARK: - Transparency

    @Test("Recording decorator is transparent: history sync completes identically")
    func decoratorIsTransparent() async {
        recorder.isEnabled = true
        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let pool = makePool(recordingCentral: recordingCentral)
        let sensor = makeSensor(entries: 5)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 5.0)

        #expect(connection.connectionState == .authenticated)
        #expect(entries.count == 5)
        #expect(sensor.servedEntryIndices == [0, 1, 2, 3, 4])
        #expect(!connection.isHistoryLoading)
    }

    @Test("Decorator stays transparent while recording is disabled")
    func decoratorTransparentWhenDisabled() async {
        recorder.isEnabled = false
        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let pool = makePool(recordingCentral: recordingCentral)
        let sensor = makeSensor(entries: 3)

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 5.0)

        #expect(entries.count == 3)
        #expect(recorder.activeRecording(for: sensor.identifier) == nil, "No session while disabled")
        #expect(recorder.listRecordings().isEmpty)
    }

    // MARK: - Capture correctness

    @Test("Recorded session captures the full traffic sequence")
    func capturesTrafficSequence() async {
        recorder.isEnabled = true
        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let pool = makePool(recordingCentral: recordingCentral)
        let sensor = makeSensor(entries: 3)

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 5.0)

        guard let recording = recorder.activeRecording(for: sensor.identifier) else {
            Issue.record("No active recording for the device")
            return
        }

        let events = recording.events
        #expect(recording.deviceUUID == sensor.identifier.uuidString)
        #expect(events.first?.type == .connectRequested)
        #expect(events.contains { $0.type == .connected })
        #expect(events.contains { $0.type == .servicesDiscovered })

        // History mode activation and metadata request
        #expect(events.contains { $0.type == .write && $0.data == "a00000" })
        #expect(events.contains { $0.type == .write && $0.data == "3c" })

        // One address write per entry
        let addressWrites = events.filter { $0.type == .write && ($0.data?.hasPrefix("a1") ?? false) }
        #expect(addressWrites.map(\.data) == ["a10000", "a10100", "a10200"])

        // History responses are captured with payloads
        let historyValues = events.filter {
            $0.type == .valueUpdated && $0.char == historicalSensorValuesCharacteristicUUID.uuidString
        }
        #expect(historyValues.count == 4, "metadata + 3 entries")
        #expect(historyValues.allSatisfy { Data(hexEncoded: $0.data ?? "") != nil })

        // Timestamps are monotonic
        let times = events.map(\.t)
        #expect(times == times.sorted(), "Event timestamps must be monotonic")
    }

    @Test("Disconnect events carry the error and trigger a file flush")
    func disconnectFlushesToFile() async {
        recorder.isEnabled = true
        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let pool = makePool(recordingCentral: recordingCentral)
        let sensor = makeSensor()

        pool.connect(to: sensor.identifier.uuidString, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.2)

        let error = NSError(domain: CBErrorDomain, code: CBError.peripheralDisconnected.rawValue)
        fakeCentral.simulateDisconnect(of: sensor.identifier, error: error)
        await pump()

        guard let recording = recorder.activeRecording(for: sensor.identifier) else {
            Issue.record("No active recording for the device")
            return
        }
        let disconnect = recording.events.last { $0.type == .disconnected }
        #expect(disconnect?.errorDomain == CBErrorDomain)
        #expect(disconnect?.errorCode == CBError.peripheralDisconnected.rawValue)

        recorder.waitForPendingWrites()
        let files = recorder.listRecordings()
        #expect(files.count == 1, "Disconnect must flush the session to disk")

        // The flushed file is decodable and matches the in-memory session
        if let url = files.first, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try? decoder.decode(BLESessionRecording.self, from: data)
            #expect(decoded?.deviceUUID == recording.deviceUUID)
            #expect(decoded?.events.contains { $0.type == .disconnected } == true)
        } else {
            Issue.record("Flushed recording file unreadable")
        }
    }

    // MARK: - Codable round-trip

    @Test("Recording survives a JSON round-trip unchanged")
    func codableRoundTrip() throws {
        var write = BLESessionEvent(t: 0.5, type: .write)
        write.char = historyControlCharacteristicUUID.uuidString
        write.data = "a00000"
        write.withResponse = true

        var disconnected = BLESessionEvent(t: 12.75, type: .disconnected)
        disconnected.setError(NSError(domain: CBErrorDomain, code: 7))

        var stateEvent = BLESessionEvent(t: 0.0, type: .bluetoothState)
        stateEvent.state = 5

        let recording = BLESessionRecording(
            deviceUUID: UUID().uuidString,
            deviceName: "Flower care",
            appVersion: "1.2.3",
            recordedAt: Date(timeIntervalSince1970: 1_750_000_000),
            events: [stateEvent, write, disconnected]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(recording)
        let decoded = try decoder.decode(BLESessionRecording.self, from: data)

        #expect(decoded == recording)
    }

    @Test("Hex helpers round-trip arbitrary payloads")
    func hexRoundTrip() {
        let payloads: [Data] = [
            Data(),
            Data([0x00]),
            Data([0xa1, 0x00, 0xff]),
            Data((0...255).map { UInt8($0) })
        ]
        for payload in payloads {
            #expect(Data(hexEncoded: payload.hexEncodedString) == payload)
        }
        #expect(Data(hexEncoded: "abc") == nil, "Odd-length hex must fail")
        #expect(Data(hexEncoded: "zz") == nil, "Non-hex characters must fail")
    }
}

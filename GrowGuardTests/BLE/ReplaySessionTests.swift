//
//  ReplaySessionTests.swift
//  GrowGuardTests
//
//  Generic runner that turns recorded BLE sessions into regression tests.
//
//  Workflow for a new fixture: a beta tester enables "Record BLE Sessions"
//  in the debug menu, reproduces the problem, shares the
//  *.ble-session.json file. Drop it into GrowGuardTests/BLE/Recordings/,
//  add it to the test Resources phase and to `ReplayFixtures.all` with the
//  expected outcome — no new test code needed.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

// MARK: - Fixture registry

struct ReplayFixture: Sendable, CustomTestStringConvertible {
    /// Full file name in GrowGuardTests/BLE/Recordings/
    let fileName: String
    /// Expected number of published history entries (nil = don't check)
    let expectedEntries: Int?
    /// Whether the history flow is expected to finish cleanly
    let expectsCompletion: Bool

    var testDescription: String { fileName }
}

enum ReplayFixtures {
    static let all: [ReplayFixture] = [
        ReplayFixture(fileName: "history-5-entries-clean__synthetic__20260612.ble-session.json",
                      expectedEntries: 5,
                      expectsCompletion: true)
    ]

    enum FixtureError: Error {
        case notFound(String)
    }

    static func load(_ fixture: ReplayFixture) throws -> BLESessionRecording {
        let bundle = Bundle(for: BundleToken.self)
        // The Recordings folder is bundled as a folder reference, so new
        // fixtures only need a file drop + an entry in `all`
        guard let url = bundle.url(forResource: fixture.fileName, withExtension: nil, subdirectory: "Recordings") else {
            throw FixtureError.notFound(fixture.fileName)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BLESessionRecording.self, from: Data(contentsOf: url))
    }
}

/// Swift-Testing-Suites sind structs — Bundle(for:) braucht eine Klasse
private final class BundleToken {}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct ReplaySessionTests {

    private func pump() async {
        await drainMainActor()
    }

    /// Drives a pool against the replay transport until the script is
    /// exhausted or no progress happens anymore
    private func runReplay(recording: BLESessionRecording) async -> (session: ReplaySession,
                                                                     connection: DeviceConnection,
                                                                     entries: [HistoricalSensorData]) {
        let scheduler = TestScheduler()
        let session = ReplaySession(recording: recording, scheduler: scheduler)
        let central = ReplayCentral(session: session)
        let pool = ConnectionPoolManager(central: central, scheduler: scheduler)

        let connection = pool.getConnection(for: recording.deviceUUID)
        var entries: [HistoricalSensorData] = []
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        defer { cancellable.cancel() }

        session.start()
        pool.connect(to: recording.deviceUUID)

        var idleRounds = 0
        while !session.isScriptExhausted && idleRounds < 30 {
            let before = session.scriptProgress.processed
            await pump()
            scheduler.advance(by: 1.0)
            idleRounds = (session.scriptProgress.processed == before) ? idleRounds + 1 : 0
        }
        // Drain trailing inbound deliveries and timers
        await pump()
        scheduler.advance(by: 15.0)
        await pump()

        return (session, connection, entries)
    }

    @Test("Recorded sessions replay without traffic mismatches", arguments: ReplayFixtures.all)
    func replayedSessionMatches(fixture: ReplayFixture) async throws {
        let recording = try ReplayFixtures.load(fixture)
        let (session, connection, entries) = await runReplay(recording: recording)

        #expect(session.mismatches.isEmpty,
                "Traffic diverged from recording:\n\(session.mismatches.map(\.description).joined(separator: "\n"))")
        #expect(session.isScriptExhausted,
                "Replay stalled at \(session.scriptProgress.processed)/\(session.scriptProgress.total)")

        if let expected = fixture.expectedEntries {
            #expect(entries.count == expected)
        }
        if fixture.expectsCompletion {
            #expect(!connection.isHistoryLoading)
        }
    }

    @Test("Record→replay loop closes: a recorded fake session replays cleanly")
    func recordReplayRoundTrip() async throws {
        // 1. Record a session against the scriptable fake sensor
        let recordScheduler = TestScheduler()
        let fakeCentral = FakeCentral()
        let sensor = FakeFlowerCarePeripheral(scheduler: recordScheduler)
        sensor.historyEntries = (0..<5).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: Int16(200 + index),
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        fakeCentral.register(sensor)

        let recorder = BLESessionRecorder(
            defaults: UserDefaults(suiteName: "ReplayRoundTrip-\(UUID().uuidString)")!,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("replay-roundtrip-\(UUID().uuidString)", isDirectory: true)
        )
        recorder.isEnabled = true

        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let recordPool = ConnectionPoolManager(central: recordingCentral, scheduler: recordScheduler)

        recordPool.connect(to: sensor.identifier.uuidString)
        await pump()
        recordScheduler.advance(by: 10.0)

        guard let recording = recorder.activeRecording(for: sensor.identifier) else {
            Issue.record("Recording was not created")
            return
        }
        #expect(recording.events.contains { $0.type == .valueUpdated })

        // 2. Replay the recording against a FRESH pool — traffic must match
        let (session, connection, entries) = await runReplay(recording: recording)

        #expect(session.mismatches.isEmpty,
                "Round-trip mismatches:\n\(session.mismatches.map(\.description).joined(separator: "\n"))")
        #expect(session.isScriptExhausted)
        #expect(entries.count == 5)
        #expect(!connection.isHistoryLoading)

        // 3. Leave the canonical artifact in tmp for fixture (re)generation
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let artifact = FileManager.default.temporaryDirectory
            .appendingPathComponent("growguard-synthetic-fixture.ble-session.json")
        try encoder.encode(recording).write(to: artifact)
        print("FIXTURE_WRITTEN: \(artifact.path)")
    }

    @Test("Replay detects traffic divergence (corrupted outbound payload)")
    func replayDetectsDivergence() async throws {
        // Record a clean 2-entry session
        let recordScheduler = TestScheduler()
        let fakeCentral = FakeCentral()
        let sensor = FakeFlowerCarePeripheral(scheduler: recordScheduler)
        sensor.historyEntries = (0..<2).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: 200,
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        fakeCentral.register(sensor)

        let recorder = BLESessionRecorder(
            defaults: UserDefaults(suiteName: "ReplayDivergence-\(UUID().uuidString)")!,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("replay-divergence-\(UUID().uuidString)", isDirectory: true)
        )
        recorder.isEnabled = true
        let recordingCentral = RecordingBLECentral(wrapping: fakeCentral, recorder: recorder)
        let recordPool = ConnectionPoolManager(central: recordingCentral, scheduler: recordScheduler)
        recordPool.connect(to: sensor.identifier.uuidString)
        await pump()
        recordScheduler.advance(by: 10.0)

        guard var recording = recorder.activeRecording(for: sensor.identifier) else {
            Issue.record("Recording was not created")
            return
        }

        // Corrupt one expected outbound payload: the history-mode command
        guard let index = recording.events.firstIndex(where: { $0.type == .write && $0.data == "a00000" }) else {
            Issue.record("History-mode write not found in recording")
            return
        }
        recording.events[index].data = "deadbeef"

        let (session, _, _) = await runReplay(recording: recording)

        #expect(!session.mismatches.isEmpty, "Divergence must be detected")
        #expect(session.mismatches.first?.expected.contains("deadbeef") == true)
    }
}

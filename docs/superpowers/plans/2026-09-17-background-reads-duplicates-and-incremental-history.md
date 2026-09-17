# Background Reads: No Duplicate Saves, Incremental History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Background wake reads save each sample exactly once, and the plant history fills in while the app is in the background instead of only when the user opens it.

**Architecture:** (1) The plant details screen claims the live reads it starts through a small `LiveReadGate`, so it stops re-requesting and re-saving samples that background wake reads deliver over the shared pool connection. (2) `DeviceConnection` gets a one-flow *stop boundary*: the sensor serves history newest-first, so a flow can end at the first entry that is already stored. The BGProcessing history sync and the silent-push wake read both use it — the wake read appends the few entries recorded since the last sync after its live sample.

**Tech Stack:** Swift 5 / SwiftUI, iOS 18, Combine, CoreData, Swift Testing (`@Test` / `#expect`), `TestScheduler` virtual time, `FakeCentral` / `FakeFlowerCarePeripheral`.

**Spec:** No separate spec — the findings below are the design basis (debug session 2026-09-16/17, PR #12).

## Findings this plan is based on

Verified on the user's device (app container read via `xcrun devicectl`) and in code:

1. **Every background sample is stored twice.** `ZSENSORDATA` holds each `background_push` / `background_task` row a second time with source `live_user` and the identical timestamp. Cause: `DeviceDetailsViewModel` subscribes to the pool connection's `sensorDataPublisher` (`GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift:138`) and saves *every* sample as `.liveUserTriggered` (`:353`). Its `connectionStatePublisher` sink also calls `requestLiveData()` on *every* `.authenticated` (`:287-290`). Per-tab `NavigationStack`s keep the view model alive while the app is backgrounded, so a push-driven wake read is requested twice and saved twice.
2. **History never syncs in the background.** A wake read fetches only the live sample. History is only synced by `BGProcessingTask`, which iOS ran once in days (`background_last_processing_date` = 2026-09-15). Even when it runs, `BackgroundHistorySyncService` re-reads the sensor's *entire* history (9 522 entries on the user's sensor) inside a 240 s per-device cap, starting at index 0 every time, and saves without duplicate check.
3. **The sensor serves history newest-first.** Real recording `GrowGuardTests/BLE/Recordings/522a3a0d_20260612-160740.ble-session.json`: entry index 0 has timestamp 327600 s since boot, index 1 324000, index 2 320400 … — one entry per hour, index 0 newest. The device DB confirms it: history rows inserted in order carry descending dates. Therefore "everything newer than the last stored history entry" is a prefix of the index range and ends at the first known entry.
4. Decoded history dates are derived from the device clock at sync time and drift by a few seconds between syncs (same entry stored as 19:16:42 and 19:16:36). Entries are 3 600 s apart, so a 600 s tolerance identifies an already-stored entry safely.

## Global Constraints

- `GrowGuard.xcodeproj/project.pbxproj` is hand-maintained. Every new source file needs four entries: `PBXBuildFile`, `PBXFileReference`, the group's `children`, and the target's `Sources` build phase. Copy an existing sibling's lines and give the new file unique 24-character IDs.
- `GrowGuardTests/ViewModel/DeviceDetailsViewModelTests.swift` is **not** part of the test target (not in `project.pbxproj`) — do not put new tests there.
- All BLE timing goes through the injected `BLEScheduler` — never `Task.sleep` or `Timer` in `DeviceConnection` / services.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest. `@MainActor` BLE suites are `@Suite(.serialized)` and settle async state with `drainMainActor()` / `waitUntil {}` from `GrowGuardTests/BLE/FakeBLETransport.swift` — never a fixed `Task.yield()` loop.
- `HistoricalDataLoadingCompleted` (`NotificationCenter.default`, `object:` = device UUID `String`) is the existing "history flow finished" signal; observers compare the object by value.
- History stop tolerance: `600` seconds. Wake read budget stays `9.0` s (`BackgroundBLEWakeService.wakeReadTimeout`).
- Foreground "load history" in the details screen stays a **full** sync (it fills gaps older than the newest stored entry). Only background paths use the stop boundary.
- Test command used throughout (adjust `-only-testing:` per task):
  `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/<Suite>`
- Full suite before every commit that touches shared BLE code: `-only-testing:GrowGuardTests`.

---

## File Structure

| File | Responsibility |
|---|---|
| `GrowGuard/DeviceDetails/LiveReadGate.swift` (create) | Pure state machine: did the details screen ask for the sample that just arrived? |
| `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` (modify) | Claim own connects; request/save live data only through the gate. |
| `GrowGuard/Database/Repositories/SensorDataRepository.swift` + `CoreData/CoreDataSensorDataRepository.swift` (modify) | `getLatestSensorDate(for:source:)` — newest stored entry of one source. |
| `GrowGuard/BLE/DeviceConnection.swift`, `DeviceConnection+PeripheralLink.swift`, `DeviceConnection+HistoryFlow.swift` (modify) | One-flow stop boundary; completion notification also for an empty history. |
| `GrowGuard/Services/BackgroundHistorySyncService.swift` (modify) | Load the boundary per device before connecting. |
| `GrowGuard/Services/BackgroundBLEWakeService.swift` (modify) | After a saved live sample: incremental history phase within the same wake budget. |
| `GrowGuard/Services/BackgroundTaskTracker.swift` (modify) | Wake read entries report how many history entries were fetched. |
| `GrowGuardTests/LiveReadGateTests.swift` (create) | Gate unit tests. |
| `GrowGuardTests/BLE/DeviceConnectionScenarioTests.swift`, `BackgroundHistorySyncTests.swift`, `BackgroundWakeServiceTests.swift`, `GrowGuardTests/BackgroundTaskTrackerTests.swift` (modify) | Behavior tests. |
| `BLE-Reliability.md` (modify) | Document the stop boundary and the wake history phase. |

---

### Task 1: LiveReadGate

**Files:**
- Create: `GrowGuard/DeviceDetails/LiveReadGate.swift`
- Create: `GrowGuardTests/LiveReadGateTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj` (app target: anchor on `DeviceDetailsViewModel.swift`; test target: anchor on `MoistureAnomalyServiceTests.swift`)

**Interfaces:**
- Produces: `struct LiveReadGate` with `mutating func claim(at: Date)`, `mutating func connectionAuthenticated(at: Date) -> Bool`, `mutating func sampleReceived() -> Bool`, `mutating func connectionLost()`, `static let claimLifetime: TimeInterval = 60`.

- [ ] **Step 1: Write the failing tests**

`GrowGuardTests/LiveReadGateTests.swift`:

```swift
//
//  LiveReadGateTests.swift
//  GrowGuardTests
//
//  The details screen shares the pool connection with background wake
//  reads. It may only request and save the live samples it asked for.
//

import Testing
import Foundation
@testable import GrowGuard

struct LiveReadGateTests {

    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("An unclaimed connection neither requests nor saves (background wake read)")
    func unclaimedIgnoresEverything() {
        var gate = LiveReadGate()

        #expect(!gate.connectionAuthenticated(at: start))
        #expect(!gate.sampleReceived())
    }

    @Test("A claimed connect requests once on authentication and saves the one answer")
    func claimedReadRequestsAndSavesOnce() {
        var gate = LiveReadGate()
        gate.claim(at: start)

        #expect(gate.connectionAuthenticated(at: start.addingTimeInterval(2)))
        #expect(!gate.connectionAuthenticated(at: start.addingTimeInterval(3)), "No second request for the same claim")
        #expect(gate.sampleReceived())
        #expect(!gate.sampleReceived(), "A later sample belongs to someone else")
    }

    @Test("A dropped link before the answer re-requests after the pool reconnects")
    func reconnectReRequests() {
        var gate = LiveReadGate()
        gate.claim(at: start)
        #expect(gate.connectionAuthenticated(at: start.addingTimeInterval(1)))

        gate.connectionLost()

        #expect(gate.connectionAuthenticated(at: start.addingTimeInterval(5)))
        #expect(gate.sampleReceived())
    }

    @Test("A claim expires, so a much later background wake is not treated as the screen's read")
    func claimExpires() {
        var gate = LiveReadGate()
        gate.claim(at: start)

        let muchLater = start.addingTimeInterval(LiveReadGate.claimLifetime + 1)
        #expect(!gate.connectionAuthenticated(at: muchLater))
        #expect(!gate.sampleReceived())
    }

    @Test("Losing an unclaimed connection keeps the gate closed")
    func lostWithoutClaimStaysClosed() {
        var gate = LiveReadGate()

        gate.connectionLost()

        #expect(!gate.connectionAuthenticated(at: start))
    }
}
```

- [ ] **Step 2: Add both files to `project.pbxproj`**

Run (IDs are unique, prefix `56LRG`):

```bash
python3 - <<'EOF'
p = 'GrowGuard.xcodeproj/project.pbxproj'
s = open(p).read()
def after(anchor, line):
    global s
    assert s.count(anchor) == 1, anchor
    s = s.replace(anchor, anchor + line)
# App target
after('\t\t565DEC422C159BA3002D784A /* DeviceDetailsViewModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = 565DEC412C159BA3002D784A /* DeviceDetailsViewModel.swift */; };\n',
      '\t\t56LRG0012EC7000000000001 /* LiveReadGate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56LRG0002EC7000000000001 /* LiveReadGate.swift */; };\n')
after('\t\t565DEC412C159BA3002D784A /* DeviceDetailsViewModel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceDetailsViewModel.swift; sourceTree = "<group>"; };\n',
      '\t\t56LRG0002EC7000000000001 /* LiveReadGate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LiveReadGate.swift; sourceTree = "<group>"; };\n')
after('\t\t\t\t565DEC412C159BA3002D784A /* DeviceDetailsViewModel.swift */,\n',
      '\t\t\t\t56LRG0002EC7000000000001 /* LiveReadGate.swift */,\n')
after('\t\t\t\t565DEC422C159BA3002D784A /* DeviceDetailsViewModel.swift in Sources */,\n',
      '\t\t\t\t56LRG0012EC7000000000001 /* LiveReadGate.swift in Sources */,\n')
# Test target
after('\t\t56F0F7DD2E564C2800B538AF /* MoistureAnomalyServiceTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56F0F7DC2E564C2800B538AF /* MoistureAnomalyServiceTests.swift */; };\n',
      '\t\t56LRG0012EC7000000000002 /* LiveReadGateTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56LRG0002EC7000000000002 /* LiveReadGateTests.swift */; };\n')
after('\t\t56F0F7DC2E564C2800B538AF /* MoistureAnomalyServiceTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MoistureAnomalyServiceTests.swift; sourceTree = "<group>"; };\n',
      '\t\t56LRG0002EC7000000000002 /* LiveReadGateTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LiveReadGateTests.swift; sourceTree = "<group>"; };\n')
after('\t\t\t\t56F0F7DC2E564C2800B538AF /* MoistureAnomalyServiceTests.swift */,\n',
      '\t\t\t\t56LRG0002EC7000000000002 /* LiveReadGateTests.swift */,\n')
after('\t\t\t\t56F0F7DD2E564C2800B538AF /* MoistureAnomalyServiceTests.swift in Sources */,\n',
      '\t\t\t\t56LRG0012EC7000000000002 /* LiveReadGateTests.swift in Sources */,\n')
open(p, 'w').write(s)
EOF
```

Create an empty `GrowGuard/DeviceDetails/LiveReadGate.swift` containing only `import Foundation` so the project resolves.

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/LiveReadGateTests`
Expected: build FAILS with `cannot find 'LiveReadGate' in scope`.

- [ ] **Step 4: Implement the gate**

`GrowGuard/DeviceDetails/LiveReadGate.swift`:

```swift
//
//  LiveReadGate.swift
//  GrowGuard
//
//  The details screen shares its pool connection with background wake
//  reads (BackgroundBLEWakeService). Without this gate the screen answered
//  every authentication with its own live request and saved every sample
//  as "Live (User)" — background samples were requested and stored twice.
//

import Foundation

struct LiveReadGate {

    /// How long a claim stays valid. Covers the pool's connect watchdog and
    /// retry backoff; a wake read hours later must not match an old claim.
    static let claimLifetime: TimeInterval = 60

    private enum State: Equatable {
        case idle
        case awaitingAuthentication
        case awaitingSample
    }

    private var state: State = .idle
    private var claimedAt: Date?

    /// The screen started a connect and wants one live sample from it
    mutating func claim(at now: Date) {
        state = .awaitingAuthentication
        claimedAt = now
    }

    /// - Returns: true if the screen should request live data now
    mutating func connectionAuthenticated(at now: Date) -> Bool {
        guard state == .awaitingAuthentication,
              let claimedAt,
              now.timeIntervalSince(claimedAt) <= Self.claimLifetime else {
            return false
        }
        state = .awaitingSample
        return true
    }

    /// - Returns: true if this sample answers the screen's own request
    mutating func sampleReceived() -> Bool {
        guard state == .awaitingSample else { return false }
        state = .idle
        claimedAt = nil
        return true
    }

    /// The link dropped before the answer: re-request after the reconnect
    mutating func connectionLost() {
        if state == .awaitingSample {
            state = .awaitingAuthentication
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/LiveReadGateTests`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/DeviceDetails/LiveReadGate.swift GrowGuardTests/LiveReadGateTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add LiveReadGate for live reads the details screen asked for"
```

---

### Task 2: Details screen only requests and saves its own live reads

**Files:**
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` (`connectViaPool()` ~108-297)

**Interfaces:**
- Consumes: `LiveReadGate` from Task 1.
- Produces: no API change.

`DeviceDetailsViewModel` hard-wires `ConnectionPoolManager.shared`, `RepositoryManager.shared` and Live Activities, so it has no unit test harness; the decision logic is covered by Task 1 and the wiring is verified on device in Task 7.

- [ ] **Step 1: Add the gate property**

Below `private var blinkOnAuthenticationSubscription: AnyCancellable?` add:

```swift
    /// Distinguishes this screen's live reads from background wake reads
    /// on the shared pool connection
    private var liveReadGate = LiveReadGate()
```

- [ ] **Step 2: Claim in `connectViaPool()`**

Directly after the `guard let connection = deviceConnection else { … }` block add:

```swift
        // Every connect this screen starts wants one live sample
        liveReadGate.claim(at: Date())
```

- [ ] **Step 3: Save only the claimed sample**

Replace the `poolSensorDataSubscription = connection.sensorDataPublisher.sink { … }` block with:

```swift
        // Subscribe zu Sensor-Daten vom ConnectionPool
        poolSensorDataSubscription = connection.sensorDataPublisher.sink { [weak self] (data: SensorDataTemp) in
            Task { @MainActor in
                guard let self = self else { return }
                // Background wake reads share this connection and save
                // their own samples — only persist what this screen asked for
                guard self.liveReadGate.sampleReceived() else {
                    AppLogger.ble.info("📡 DeviceDetailsViewModel: Ignoring sample this screen did not request")
                    return
                }
                let success = await self.saveSensorData(data)
                if success {
                    await self.updateDeviceLastUpdate()
                }
            }
        }
```

- [ ] **Step 4: Request only for the claim; reset on link loss**

In the `poolConnectionStateSubscription` sink replace

```swift
                // Bei erfolgreicher Authentication: Fordere Live-Daten an
                if state == .authenticated {
                    AppLogger.ble.bleConnection("DeviceDetailsViewModel (Pool): Device authenticated, requesting live data")
                    connection.requestLiveData()
                }
```

with

```swift
                switch state {
                case .authenticated:
                    // Only for connects this screen started — a background
                    // wake read requests its own sample
                    if self.liveReadGate.connectionAuthenticated(at: Date()) {
                        AppLogger.ble.bleConnection("DeviceDetailsViewModel (Pool): Device authenticated, requesting live data")
                        connection.requestLiveData()
                    }
                case .disconnected, .error:
                    self.liveReadGate.connectionLost()
                default:
                    break
                }
```

- [ ] **Step 5: Build and run the full suite**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift
git commit -m "Stop the details screen from re-requesting and re-saving background samples"
```

---

### Task 3: History stop boundary in DeviceConnection

**Files:**
- Modify: `GrowGuard/BLE/DeviceConnection.swift` (history state ~117-125)
- Modify: `GrowGuard/BLE/DeviceConnection+PeripheralLink.swift` (entry branch ~304-345, zero-entries branch ~294-297)
- Modify: `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift` (`cleanupHistoryFlow()`)
- Test: `GrowGuardTests/BLE/DeviceConnectionScenarioTests.swift`

**Interfaces:**
- Produces: `DeviceConnection.setHistoryStopBoundary(_ date: Date?)`, `private(set) var historyStopBoundary: Date?`, `static let historyStopTolerance: TimeInterval = 600`. The flow posts `HistoricalDataLoadingCompleted` when it stops at the boundary **and** when the sensor reports zero entries.

- [ ] **Step 1: Write the failing tests**

In `DeviceConnectionScenarioTests`, add below `historyHappyPath()`:

```swift
    /// Real sensor order (recording 522a3a0d): index 0 is the newest entry,
    /// one entry per hour
    private func newestFirstHourlyEntries(count: Int, uptime: UInt32) -> [Data] {
        (0..<count).map { index in
            FlowerCareFrames.historyEntry(timestamp: uptime - UInt32((index + 1) * 3600),
                                          temperatureX10: 200,
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
    }

    @Test("History flow with a stop boundary ends at the first already-stored entry")
    func historyStopsAtBoundary() {
        let (sensor, connection) = makeSensor()
        sensor.historyEntries = newestFirstHourlyEntries(count: 6, uptime: sensor.uptimeSeconds)
        // Entry index 2 is the newest one already stored
        connection.setHistoryStopBoundary(Date().addingTimeInterval(-3 * 3600))

        var entries: [HistoricalSensorData] = []
        var completed = false
        let uuid = connection.deviceUUID
        let c1 = connection.historicalDataPublisher.sink { entries.append($0) }
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: nil, queue: nil
        ) { note in
            if note.object as? String == uuid { completed = true }
        }
        defer { c1.cancel(); NotificationCenter.default.removeObserver(observer) }

        connect(sensor, connection)
        scheduler.advance(by: 5.0)

        #expect(entries.count == 2)
        #expect(sensor.servedEntryIndices == [0, 1, 2])
        #expect(completed)
        #expect(!connection.isHistoryLoading)
        #expect(connection.historyStopBoundary == nil, "The boundary applies to one flow only")
    }
```

In `historyZeroEntries()` add the completion observer and expectation so it reads:

```swift
    @Test("Empty history finishes cleanly without entries")
    func historyZeroEntries() {
        let (sensor, connection) = makeSensor(entries: 0)

        var entries: [HistoricalSensorData] = []
        var completed = false
        let uuid = connection.deviceUUID
        let cancellable = connection.historicalDataPublisher.sink { entries.append($0) }
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"), object: nil, queue: nil
        ) { note in
            if note.object as? String == uuid { completed = true }
        }
        defer { cancellable.cancel(); NotificationCenter.default.removeObserver(observer) }

        connect(sensor, connection)
        scheduler.advance(by: 5.0)

        #expect(entries.isEmpty)
        #expect(!connection.isHistoryLoading)
        #expect(completed, "Waiters (wake read, background sync) must not run into their timeout")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/DeviceConnectionScenarioTests`
Expected: build FAILS with `value of type 'DeviceConnection' has no member 'setHistoryStopBoundary'`.

- [ ] **Step 3: Add the boundary state**

In `DeviceConnection.swift`, directly below `var isHistoryFlowActive: Bool = false` add:

```swift
    /// Newest history entry already stored. The sensor serves history
    /// newest-first, so the flow ends at the first entry at or before this
    /// date. nil = full sync. Cleared when the flow ends.
    private(set) var historyStopBoundary: Date?

    /// Stored and re-decoded dates of one entry drift by seconds (device
    /// clock); entries are 3600 s apart
    static let historyStopTolerance: TimeInterval = 600

    func setHistoryStopBoundary(_ date: Date?) {
        historyStopBoundary = date
    }
```

- [ ] **Step 4: Stop at the boundary and signal an empty history**

In `DeviceConnection+PeripheralLink.swift`, zero-entries branch — replace

```swift
                } else {
                    AppLogger.ble.info("ℹ️ No historical entries available for device \(self.deviceUUID)")
                    cleanupHistoryFlow()
                }
```

with

```swift
                } else {
                    AppLogger.ble.info("ℹ️ No historical entries available for device \(self.deviceUUID)")
                    NotificationCenter.default.post(name: NSNotification.Name("HistoricalDataLoadingCompleted"), object: self.deviceUUID)
                    cleanupHistoryFlow()
                }
```

In the entry branch, directly after `entryRetryCount = 0` insert:

```swift
                // Incremental sync: everything from here on is already stored
                if let boundary = historyStopBoundary,
                   historicalData.date <= boundary.addingTimeInterval(Self.historyStopTolerance) {
                    AppLogger.ble.info("⏹ History entry \(self.currentEntryIndex) is already stored for device \(self.deviceUUID) - incremental sync complete")
                    NotificationCenter.default.post(name: NSNotification.Name("HistoricalDataLoadingCompleted"), object: self.deviceUUID)
                    cleanupHistoryFlow()
                    return
                }
```

In `DeviceConnection+HistoryFlow.swift`, `cleanupHistoryFlow()`, below `deviceBootTime = nil` add:

```swift
        historyStopBoundary = nil
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/DeviceConnectionScenarioTests`
Expected: all tests pass, including `historyStopsAtBoundary` and `historyZeroEntries`.

- [ ] **Step 6: Full suite, then commit**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests`
Expected: `** TEST SUCCEEDED **`.

```bash
git add GrowGuard/BLE/DeviceConnection.swift GrowGuard/BLE/DeviceConnection+PeripheralLink.swift GrowGuard/BLE/DeviceConnection+HistoryFlow.swift GrowGuardTests/BLE/DeviceConnectionScenarioTests.swift
git commit -m "Let a history flow stop at the newest already-stored entry"
```

---

### Task 4: Newest stored history date + incremental BGProcessing sync

**Files:**
- Modify: `GrowGuard/Database/Repositories/SensorDataRepository.swift`
- Modify: `GrowGuard/Database/Repositories/CoreData/CoreDataSensorDataRepository.swift`
- Modify: `GrowGuard/Services/BackgroundHistorySyncService.swift`
- Test: `GrowGuardTests/BLE/BackgroundHistorySyncTests.swift`

**Interfaces:**
- Consumes: `DeviceConnection.setHistoryStopBoundary(_:)` (Task 3).
- Produces: `SensorDataRepository.getLatestSensorDate(for deviceUUID: String, source: SensorDataSource) async throws -> Date?`; `BackgroundHistorySyncService.init(…, loadHistoryBoundary: ((String) async -> Date?)? = nil)`.

The CoreData repository has no test harness in this project; it is exercised by the default closures and verified on device in Task 7.

- [ ] **Step 1: Write the failing test**

In `BackgroundHistorySyncTests`, change `makeService` to:

```swift
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
```

Add the test:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundHistorySyncTests`
Expected: build FAILS with `extra argument 'loadHistoryBoundary' in call`.

- [ ] **Step 3: Repository query**

`SensorDataRepository.swift` — add to the protocol:

```swift
    /// Date of the newest stored entry of one source, nil if there is none
    func getLatestSensorDate(for deviceUUID: String, source: SensorDataSource) async throws -> Date?
```

`CoreDataSensorDataRepository.swift` — add below `getRecentSensorData`:

```swift
    func getLatestSensorDate(for deviceUUID: String, source: SensorDataSource) async throws -> Date? {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = NSFetchRequest<SensorData>(entityName: "SensorData")
                    request.predicate = NSPredicate(format: "device.uuid == %@ AND source == %@", deviceUUID, source.rawValue)
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                    request.fetchLimit = 1
                    let newest = try self.context.fetch(request).first
                    continuation.resume(returning: newest?.date)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
```

If the build reports another type conforming to `SensorDataRepository`, add the same method there.

- [ ] **Step 4: Use the boundary in the background sync**

In `BackgroundHistorySyncService`:

Add the dependency below `saveHistoricalEntry`:

```swift
    /// Newest stored history date per device; nil = full sync
    private let loadHistoryBoundary: (String) async -> Date?
```

Extend `init` with `loadHistoryBoundary: ((String) async -> Date?)? = nil` as the last parameter and assign:

```swift
        self.loadHistoryBoundary = loadHistoryBoundary ?? { uuid in
            try? await RepositoryManager.shared.sensorDataRepository.getLatestSensorDate(for: uuid, source: .historyLoading)
        }
```

At the top of `syncDevice(_:)`, before `await withCheckedContinuation`, add:

```swift
        // Only fetch what was recorded since the last sync — a full read of
        // a year of hourly entries never fits a background window
        let boundary = await loadHistoryBoundary(deviceUUID)
        pool.getConnection(for: deviceUUID).setHistoryStopBoundary(boundary)
```

Update the file header comment "Runs full history syncs" to "Runs incremental history syncs (entries newer than the newest stored one)".

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundHistorySyncTests`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/Database/Repositories/SensorDataRepository.swift GrowGuard/Database/Repositories/CoreData/CoreDataSensorDataRepository.swift GrowGuard/Services/BackgroundHistorySyncService.swift GrowGuardTests/BLE/BackgroundHistorySyncTests.swift
git commit -m "Sync only new history entries in BGProcessing windows"
```

---

### Task 5: Tracker reports history entries of a wake read

**Files:**
- Modify: `GrowGuard/Services/BackgroundTaskTracker.swift` (`recordWakeRead`)
- Test: `GrowGuardTests/BackgroundTaskTrackerTests.swift`

**Interfaces:**
- Produces: `recordWakeRead(trigger: BackgroundTrigger?, outcome: WakeReadOutcome, duration: TimeInterval, historyEntries: Int = 0)`. Detail: `outcome.rawValue`, plus `" · N history entries"` when `N > 0`.

- [ ] **Step 1: Write the failing test**

Add to `BackgroundTaskTrackerTests`:

```swift
    @Test("A wake read that also fetched history says how many entries")
    func wakeReadReportsHistoryEntries() {
        let tracker = makeTracker()

        tracker.recordWakeRead(trigger: .silentPush, outcome: .saved, duration: 4, historyEntries: 2)
        tracker.recordWakeRead(trigger: .silentPush, outcome: .saved, duration: 3)

        #expect(tracker.executionHistory.map(\.detail) == ["Saved", "Saved · 2 history entries"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundTaskTrackerTests`
Expected: build FAILS with `extra argument 'historyEntries' in call`.

- [ ] **Step 3: Implement**

Change the signature and the `detail:` argument in `recordWakeRead`:

```swift
    func recordWakeRead(trigger: BackgroundTrigger?,
                        outcome: WakeReadOutcome,
                        duration: TimeInterval,
                        historyEntries: Int = 0) {
```

```swift
            detail: historyEntries > 0
                ? "\(outcome.rawValue) · \(historyEntries) history entries"
                : outcome.rawValue,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundTaskTrackerTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/Services/BackgroundTaskTracker.swift GrowGuardTests/BackgroundTaskTrackerTests.swift
git commit -m "Show history entries fetched by a wake read in the debug history"
```

---

### Task 6: Wake read appends incremental history

**Files:**
- Modify: `GrowGuard/Services/BackgroundBLEWakeService.swift`
- Test: `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift`

**Interfaces:**
- Consumes: `setHistoryStopBoundary(_:)`, `startHistoryDataFlow()`, `cleanupHistoryFlow()`, `isHistoryFlowActive`, `historicalDataPublisher` (DeviceConnection); `HistoricalDataLoadingCompleted`; `recordWakeRead(…, historyEntries:)` (Task 5).
- Produces: `BackgroundBLEWakeService.init(…, loadHistoryBoundary: ((String) async -> Date?)? = nil, saveHistoricalEntry: ((HistoricalSensorData, String) async -> Void)? = nil)` appended after `tracker:`.

Behavior:
- Phases per read: `live` → `saving` → `history`.
- After a **saved** live sample and the status check: load the boundary. `nil` (never synced) → finish `.saved` (a full sync cannot fit a wake window). Otherwise set the boundary, subscribe to history entries, start the flow, and finish `.saved` on `HistoricalDataLoadingCompleted` for this device.
- In `history`: disconnect, error and the 9 s timeout all finish as `.saved` (the live sample is stored); entries received so far count.
- `finishRead` calls `cleanupHistoryFlow()` before `pool.disconnect` whenever a flow is active, so the pool does not auto-reconnect to resume it.

- [ ] **Step 1: Write the failing tests**

In `BackgroundWakeServiceTests`:

Add to `Recorder`: `var historySaved = 0`.

Change `makeService` to accept and pass the new dependencies:

```swift
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
            endBackgroundTask: { _ in recorder.ended += 1 },
            notificationCenter: notificationCenter,
            tracker: tracker,
            loadHistoryBoundary: { _ in historyBoundary },
            saveHistoricalEntry: { _, _ in recorder.historySaved += 1 }
        )
        service.start()
        return service
    }
```

Add helpers below `makeSensor()`:

```swift
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
```

Add the tests:

```swift
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
        await settle(seconds: 1.0)

        #expect(tracker.executionHistory.first?.detail == "Saved · 1 history entries")
        #expect(tracker.wakeReadFailureCount == 0)
        #expect(recorder.ended == 1)
        #expect(!pool.getConnection(for: sensor.identifier.uuidString).isHistoryFlowActive,
                "An abandoned flow would make the pool auto-reconnect in the background")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundWakeServiceTests`
Expected: build FAILS with `extra arguments at positions … in call` (`loadHistoryBoundary`, `saveHistoricalEntry`).

- [ ] **Step 3: Dependencies and read state**

In `BackgroundBLEWakeService`:

Below `private let tracker: BackgroundTaskTracker` add:

```swift
    /// Newest stored history date; nil = never synced, skip history
    private let loadHistoryBoundary: (String) async -> Date?
    private let saveHistoricalEntry: (HistoricalSensorData, String) async -> Void
```

Replace the `WakeRead` class with:

```swift
    private final class WakeRead {
        enum Phase {
            /// Waiting for authentication and the live sample
            case live
            /// Sample received and being persisted: the link is no longer
            /// needed, so a disconnect must not turn the read into a failure
            case saving
            /// Live sample stored, fetching entries newer than the stored history
            case history
        }

        var cancellables: Set<AnyCancellable> = []
        var timeoutTask: BLEScheduledTask?
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var liveDataRequested = false
        var phase: Phase = .live
        var historyEntries = 0
        var historyCompletionObserver: NSObjectProtocol?
        var finished = false
        let startedAt = Date()
        /// nil when iOS relaunched the app for the connect (arm state lost)
        var trigger: BackgroundTrigger?
    }
```

Extend `init` — add as the last two parameters:

```swift
         loadHistoryBoundary: ((String) async -> Date?)? = nil,
         saveHistoricalEntry: ((HistoricalSensorData, String) async -> Void)? = nil
```

and assign in the body:

```swift
        self.loadHistoryBoundary = loadHistoryBoundary ?? { uuid in
            try? await RepositoryManager.shared.sensorDataRepository.getLatestSensorDate(for: uuid, source: .historyLoading)
        }
        self.saveHistoricalEntry = saveHistoricalEntry ?? { entry, uuid in
            _ = try? await PlantMonitorService.shared.validateHistoricSensorData(entry, deviceUUID: uuid)
        }
```

- [ ] **Step 4: Phase-aware terminal events**

In `handleArmedConnection`, replace the `.error` / `.disconnected` cases with:

```swift
                case .error, .disconnected:
                    switch read.phase {
                    case .live:
                        let outcome: WakeReadOutcome = state == .disconnected ? .disconnected : .connectionError
                        self.finishRead(for: deviceUUID, outcome: outcome)
                    case .saving:
                        return
                    case .history:
                        // Live sample is stored; keep what history arrived
                        self.finishRead(for: deviceUUID, outcome: .saved)
                    }
```

`ConnectionState` is `Equatable` (custom `==` that also covers `.error`), so `state == .disconnected` compiles.

Replace the sample sink body with:

```swift
            .sink { [weak self, trigger = read.trigger] sensorData in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                read.phase = .saving
                let source = trigger?.sensorDataSource ?? .backgroundTask
                Task { @MainActor in
                    let saved = await self.saveSample(sensorData, deviceUUID, source)
                    guard saved else {
                        self.finishRead(for: deviceUUID, outcome: .sampleRejected)
                        return
                    }
                    await self.runStatusCheck(deviceUUID)
                    await self.fetchNewHistory(for: deviceUUID, connection: connection)
                }
            }
```

Replace the timeout block with:

```swift
        read.timeoutTask = scheduler.schedule(after: wakeReadTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                // Out of time while appending history: the live sample is stored
                self.finishRead(for: deviceUUID, outcome: read.phase == .history ? .saved : .timedOut)
            }
        }
```

- [ ] **Step 5: History phase and cleanup**

Add above `finishRead`:

```swift
    /// Appends the entries recorded since the last stored history entry.
    /// A full sync never fits the wake window, so without stored history
    /// this is left to the details screen and BGProcessing.
    private func fetchNewHistory(for deviceUUID: String, connection: DeviceConnection) async {
        let boundary = await loadHistoryBoundary(deviceUUID)
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        guard let boundary else {
            finishRead(for: deviceUUID, outcome: .saved)
            return
        }

        read.phase = .history
        connection.setHistoryStopBoundary(boundary)

        connection.historicalDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                read.historyEntries += 1
                Task { @MainActor in
                    await self.saveHistoricalEntry(entry, deviceUUID)
                }
            }
            .store(in: &read.cancellables)

        read.historyCompletionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let completedUUID = notification.object as? String
            Task { @MainActor in
                guard completedUUID == deviceUUID else { return }
                self?.finishRead(for: deviceUUID, outcome: .saved)
            }
        }

        connection.startHistoryDataFlow()
    }
```

In `finishRead`, directly after `read.cancellables.removeAll()` add:

```swift
        if let observer = read.historyCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
```

Before `pool.disconnect(from: deviceUUID)` add:

```swift
        // An active flow makes the pool auto-reconnect to resume it
        let connection = pool.getConnection(for: deviceUUID)
        if connection.isHistoryFlowActive {
            connection.cleanupHistoryFlow()
        }
```

Pass the count to the tracker:

```swift
        tracker.recordWakeRead(
            trigger: read.trigger,
            outcome: outcome,
            duration: Date().timeIntervalSince(read.startedAt),
            historyEntries: read.historyEntries
        )
```

Remove the now-unused `saving` references (the property no longer exists).

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests/BackgroundWakeServiceTests`
Expected: all 8 tests pass (5 existing + 3 new).

- [ ] **Step 7: Full suite, three iterations (shared main-actor BLE code)**

Run: `xcodebuild test -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrowGuardTests -test-iterations 3 -run-tests-until-failure`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add GrowGuard/Services/BackgroundBLEWakeService.swift GrowGuardTests/BLE/BackgroundWakeServiceTests.swift
git commit -m "Append new history entries to background wake reads"
```

---

### Task 7: Document and verify on the device

**Files:**
- Modify: `BLE-Reliability.md` (new section after "Resume semantics: suspend vs. cleanup")

- [ ] **Step 1: Document**

Add to `BLE-Reliability.md`:

```markdown
## Incremental history (stop boundary)

The sensor serves history newest-first (index 0 = newest, one entry per
hour — verified on recording `522a3a0d_20260612-160740`). Background paths
set `DeviceConnection.setHistoryStopBoundary(_:)` to the newest stored
`history` entry; the flow ends at the first entry at or before it
(tolerance 600 s, device-clock drift) and posts
`HistoricalDataLoadingCompleted`. The boundary is cleared by
`cleanupHistoryFlow()`, so it applies to one flow.

- `BackgroundHistorySyncService` (BGProcessing): incremental.
- `BackgroundBLEWakeService`: after a saved live sample, fetches the new
  entries inside the same 9 s wake budget. No stored history → skipped.
  Disconnect/timeout in this phase still counts as `.saved`.
- Details screen "load history": full sync, fills gaps older than the
  newest stored entry.

The details screen claims its own live reads (`LiveReadGate`). Samples
from background wake reads on the shared connection are neither
re-requested nor saved a second time as `live_user`.
```

- [ ] **Step 2: Commit**

```bash
git add BLE-Reliability.md
git commit -m "Document incremental history and live read ownership"
```

- [ ] **Step 3: Verify on the device**

1. Install the branch build from Xcode on the iPhone (the server uses the APNs sandbox, so no TestFlight build). In Settings → Task Execution tap **Reset All Statistics**.
2. Open a plant's details screen once (so its view model is alive), then send the app to the background. Do not swipe it away.
3. Wait for at least one push round (server `/status` → `lastPushRound`) plus a few minutes.
4. Pull the database with the phone connected:

```bash
xcrun devicectl list devices   # copy the iPhone's Identifier (UDID) from the "physical" row
D=<UDID>
mkdir -p /tmp/gg-db && for f in CoreDataModels.sqlite CoreDataModels.sqlite-wal CoreDataModels.sqlite-shm; do xcrun devicectl device copy from --device "$D" --domain-type appDataContainer --domain-identifier pro.veit.GrowGuard --source "Library/Application Support/$f" --destination "/tmp/gg-db/$f"; done
sqlite3 /tmp/gg-db/CoreDataModels.sqlite "select datetime(ZDATE+978307200,'unixepoch'), ZSOURCE from ZSENSORDATA order by Z_PK desc limit 12;"
```

Expected:
- A `background_push` (or `background_task`) row **without** a `live_user` row at the same timestamp.
- New `history` rows with hourly dates newer than the previous newest `history` row.
- Settings → Execution History: a `BLE Wake` entry with detail `Saved · N history entries`.

---

## Out of scope (tracked separately)

- `PUSH_INTERVAL_SECONDS` on the server is `1200`; the design assumed hourly. Server config, not app code.
- Arm-generation race in `BackgroundBLEWakeService.finishRead` (CodeRabbit, PR #12 thread on line 142) — pre-existing, needs its own design.

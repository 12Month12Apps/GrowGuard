# Link Quality Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a history sync, show the user whether their current position gives a usable link, and give live feedback while they move to a better one.

**Architecture:** A CoreBluetooth-free `LinkQualityMonitor` receives RSSI samples, history progress and connect/disconnect events and emits a `LinkQuality` snapshot (stage, smoothed dBm, throughput, delta against a reference position). `DeviceConnection` feeds it and publishes the snapshot; `HistoryLoadingView` renders it. RSSI sampling moves to 1 Hz while a history flow is active and the two duplicate RSSI timers collapse into one.

**Tech Stack:** Swift 5.9+ / SwiftUI, iOS 17+, Combine, Swift Testing (`@Test` / `#expect`), `TestScheduler` virtual time, SwiftGen for strings.

**Spec:** `docs/superpowers/specs/2026-09-09-link-quality-assistant-design.md`

## Global Constraints

- UI strings go through `L10n.*`, defined in `GrowGuard/Strings/Localizable.strings`, regenerated with `swiftgen` (config `swiftgen.yml`). Never hard-code a user-visible string.
- `GrowGuard.xcodeproj/project.pbxproj` is hand-maintained. Every new source file needs four entries: `PBXBuildFile`, `PBXFileReference`, the group's `children`, and the target's `Sources` build phase.
- `LinkQualityMonitor` must not import CoreBluetooth and must not reference `DeviceConnection`. It receives values and returns verdicts, so it is testable in virtual time.
- All timing goes through the injected `BLEScheduler` — never `Task.sleep`, never `Timer` directly, or the tests cannot control time.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest. `@MainActor` BLE suites are `@Suite(.serialized)`.
- RSSI band values are fixed by the spec: good `>= -70`, fair `-70…-80`, poor `< -80`, hysteresis `3` dB, median window `5` samples, minimum `10` s before a position's throughput counts.
- Test command used throughout (adjust `-only-testing:` per task):
  `xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60`

---

## File Structure

| File | Responsibility |
|---|---|
| `GrowGuard/BLE/LinkQualityMonitor.swift` (create) | Verdict logic: smoothing, hysteresis, throughput, reference/delta, summary. No BLE types. |
| `GrowGuardTests/BLE/LinkQualityMonitorTests.swift` (create) | Unit tests for all of the above, virtual time. |
| `GrowGuard/BLE/DeviceConnection.swift` (modify) | One consolidated RSSI timer, owns a `LinkQualityMonitor`, publishes `linkQualityPublisher`. |
| `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift` (modify) | Drop the duplicate quality timer; feed progress into the monitor. |
| `GrowGuardTests/BLE/FakeBLETransport.swift` (modify) | Scriptable RSSI so tests can simulate walking around. |
| `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` (modify) | Replace the ad-hoc `distanceHint` with the monitor's verdict. |
| `GrowGuard/DeviceDetails/HistoryLoadingView.swift` (modify) | Render the four states, the comparison line, "stay here", haptics. |
| `GrowGuard/Strings/Localizable.strings` (modify) | New `linkquality.*` keys. |

**Pre-existing problems this plan cleans up** (in code it already touches):
1. `HistoryLoadingView.swift:477` hardcodes `connectionQuality = .good`. Removed in Task 6.
2. `DeviceConnection.startRSSIMonitoring()` and `DeviceConnection+HistoryFlow.startConnectionQualityMonitoring()` both poll `readRSSI()` every 5 s during a sync. Consolidated in Task 4.
3. `DeviceDetailsViewModel.distanceHint(forRSSI:)` is a third, unsmoothed signal interpretation with different thresholds (−65/−80) and hard-coded English. Replaced in Task 5.

---

### Task 1: LinkQualityMonitor — smoothing and stage

**Files:**
- Create: `GrowGuard/BLE/LinkQualityMonitor.swift`
- Create: `GrowGuardTests/BLE/LinkQualityMonitorTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces: `LinkQualityStage` (`.unknown`/`.poor`/`.fair`/`.good`/`.disconnected`), `LinkQuality` struct, `LinkQualityMonitor` class with `record(rssi:at:)` and `var quality: LinkQuality`.

- [ ] **Step 1: Write the failing test**

Create `GrowGuardTests/BLE/LinkQualityMonitorTests.swift`:

```swift
//
//  LinkQualityMonitorTests.swift
//  GrowGuardTests
//
//  Unit tests for the link quality verdict logic. No BLE, no real time.
//

import Testing
import Foundation
@testable import GrowGuard

struct LinkQualityMonitorTests {

    /// Feeds `count` identical samples, one per virtual second, starting at `start`
    private func feed(_ monitor: LinkQualityMonitor, rssi: Int, count: Int, from start: TimeInterval = 0) {
        for index in 0..<count {
            monitor.record(rssi: rssi, at: start + TimeInterval(index))
        }
    }

    @Test("Strong signal reads as good")
    func strongSignalIsGood() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -60, count: 5)

        #expect(monitor.quality.stage == .good)
        #expect(monitor.quality.smoothedRSSI == -60)
    }

    @Test("Weak signal reads as poor")
    func weakSignalIsPoor() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -86, count: 5)

        #expect(monitor.quality.stage == .poor)
    }

    @Test("A single outlier does not change the stage")
    func singleOutlierIsRejected() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -60, count: 4)
        monitor.record(rssi: -95, at: 5)

        // Median of [-60,-60,-60,-60,-95] is -60 — one bad packet must not
        // swing the needle while the user is standing still.
        #expect(monitor.quality.stage == .good)
        #expect(monitor.quality.smoothedRSSI == -60)
    }

    @Test("Stage does not oscillate at the band edge")
    func hysteresisPreventsFlapping() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -60, count: 5)
        #expect(monitor.quality.stage == .good)

        // -71 is past the good threshold but inside the 3 dB hysteresis band,
        // so the stage must hold at good instead of flapping.
        feed(monitor, rssi: -71, count: 5, from: 10)
        #expect(monitor.quality.stage == .good)

        // -75 is clearly past it
        feed(monitor, rssi: -75, count: 5, from: 20)
        #expect(monitor.quality.stage == .fair)

        // Coming back needs to clear the full threshold, not just the band
        feed(monitor, rssi: -72, count: 5, from: 30)
        #expect(monitor.quality.stage == .fair)

        feed(monitor, rssi: -68, count: 5, from: 40)
        #expect(monitor.quality.stage == .good)
    }

    @Test("Stage is unknown before any sample arrives")
    func startsUnknown() {
        let monitor = LinkQualityMonitor()

        #expect(monitor.quality.stage == .unknown)
        #expect(monitor.quality.smoothedRSSI == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/LinkQualityMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: compile failure — `cannot find 'LinkQualityMonitor' in scope`. (The test file must first be registered in the project; see Step 3.)

- [ ] **Step 3: Create the implementation**

Create `GrowGuard/BLE/LinkQualityMonitor.swift`:

```swift
//
//  LinkQualityMonitor.swift
//  GrowGuard
//
//  Verdict logic for the link quality assistant: turns raw RSSI samples and
//  history progress into something a user can act on while walking around.
//
//  Deliberately free of CoreBluetooth and DeviceConnection — values go in,
//  a verdict comes out, so the whole thing is testable in virtual time
//  (same spirit as ReconnectPolicy).
//

import Foundation

/// Coarse link quality, the thing the UI actually shows
enum LinkQualityStage: String, Equatable {
    case unknown
    case disconnected
    case poor
    case fair
    case good
}

/// One snapshot of link quality, everything the UI needs in one value
struct LinkQuality: Equatable {
    var stage: LinkQualityStage = .unknown
    /// Median of the recent samples; nil before the first sample
    var smoothedRSSI: Int?
    /// Entries per second at the current position; nil until measurable
    var entriesPerSecond: Double?
    /// Difference to the reference position; nil while no reference is set
    var deltaRSSI: Int?
    var deltaEntriesPerSecond: Double?
    /// True when the current position has the best throughput of this session
    var isBestSoFar: Bool = false
}

final class LinkQualityMonitor {

    // MARK: Tuning (see BLE-Reliability.md — evidence, not taste)

    /// Signal at or above this counts as good. The existing BLE code warns
    /// below this value.
    static let goodThreshold = -70
    /// Below this the field log stalled (-81…-86 dBm).
    static let fairThreshold = -80
    /// Dead band at the edges, so the display does not flap at -80.
    static let hysteresis = 3
    /// Median window. At 1 Hz sampling this is a 5 second view.
    static let sampleWindow = 5

    private(set) var quality = LinkQuality()

    private var samples: [Int] = []

    init() {}

    /// Records one RSSI sample. `now` is virtual seconds in tests.
    func record(rssi: Int, at now: TimeInterval) {
        samples.append(rssi)
        if samples.count > Self.sampleWindow {
            samples.removeFirst(samples.count - Self.sampleWindow)
        }

        let median = Self.median(of: samples)
        quality.smoothedRSSI = median
        quality.stage = Self.stage(for: median, current: quality.stage)
    }

    // MARK: Pure helpers

    private static func median(of values: [Int]) -> Int {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Band decision with hysteresis: leaving a stage needs `hysteresis` dB
    /// more than entering it, so a value sitting on a threshold holds still.
    private static func stage(for rssi: Int, current: LinkQualityStage) -> LinkQualityStage {
        let goodEnter = goodThreshold
        let goodExit = goodThreshold - hysteresis
        let fairEnter = fairThreshold
        let fairExit = fairThreshold - hysteresis

        switch current {
        case .good:
            if rssi < fairExit { return .poor }
            if rssi < goodExit { return .fair }
            return .good
        case .fair:
            if rssi >= goodEnter { return .good }
            if rssi < fairExit { return .poor }
            return .fair
        case .poor, .unknown, .disconnected:
            if rssi >= goodEnter { return .good }
            if rssi >= fairEnter { return .fair }
            return .poor
        }
    }
}
```

- [ ] **Step 4: Register both files in the Xcode project**

`project.pbxproj` is hand-maintained. Add four entries per file. Use fresh 24-hex-character IDs that do not yet appear in the file (check with `grep`).

For `LinkQualityMonitor.swift`, add next to the other `GrowGuard/BLE` entries; for `LinkQualityMonitorTests.swift`, next to the `GrowGuardTests/BLE` entries (search for `DeviceConnectionScenarioTests.swift` to find all four insertion points and copy the pattern):

```
/* PBXBuildFile section */
<ID_A> /* LinkQualityMonitor.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_B> /* LinkQualityMonitor.swift */; };

/* PBXFileReference section */
<ID_B> /* LinkQualityMonitor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LinkQualityMonitor.swift; sourceTree = "<group>"; };

/* the BLE group's children */
<ID_B> /* LinkQualityMonitor.swift */,

/* the GrowGuard target's Sources build phase */
<ID_A> /* LinkQualityMonitor.swift in Sources */,
```

Verify afterwards:
```bash
grep -c "LinkQualityMonitor.swift" GrowGuard.xcodeproj/project.pbxproj
```
Expected: `4` for the production file plus `4` for the test file — i.e. run the grep for each name and expect `4` each. (Test files go into the `GrowGuardTests` target's Sources phase, not the app's.)

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/LinkQualityMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/BLE/LinkQualityMonitor.swift GrowGuardTests/BLE/LinkQualityMonitorTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add LinkQualityMonitor with median smoothing and hysteresis"
```

---

### Task 2: Reference point, delta and throughput

**Files:**
- Modify: `GrowGuard/BLE/LinkQualityMonitor.swift`
- Modify: `GrowGuardTests/BLE/LinkQualityMonitorTests.swift`

**Interfaces:**
- Consumes: `LinkQualityMonitor`, `LinkQuality` from Task 1.
- Produces: `record(entryIndex:at:)`, `captureReference(at:)`, `minimumMeasurementSeconds`, and the populated `entriesPerSecond` / `deltaRSSI` / `deltaEntriesPerSecond` / `isBestSoFar` fields on `LinkQuality`.

- [ ] **Step 1: Write the failing tests**

Append to `GrowGuardTests/BLE/LinkQualityMonitorTests.swift`, inside the `LinkQualityMonitorTests` struct:

```swift
    @Test("Throughput stays nil until the position has been measured long enough")
    func throughputNeedsAMinimumWindow() {
        let monitor = LinkQualityMonitor()
        monitor.record(entryIndex: 0, at: 0)
        monitor.record(entryIndex: 20, at: 5)

        // 5 s is below the 10 s minimum — reporting a number here would let the
        // user judge a spot on noise.
        #expect(monitor.quality.entriesPerSecond == nil)

        monitor.record(entryIndex: 40, at: 10)
        #expect(monitor.quality.entriesPerSecond == 4.0)
    }

    @Test("Reference point yields a signed delta")
    func referenceProducesDelta() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -84, count: 5)
        monitor.record(entryIndex: 0, at: 0)
        monitor.record(entryIndex: 5, at: 10)   // 0.5 entries/s
        monitor.captureReference(at: 10)

        // User walks to a better spot
        feed(monitor, rssi: -71, count: 5, from: 11)
        monitor.record(entryIndex: 5, at: 11)
        monitor.record(entryIndex: 45, at: 21)  // 4.0 entries/s

        #expect(monitor.quality.deltaRSSI == 13)
        #expect(monitor.quality.deltaEntriesPerSecond == 3.5)
        #expect(monitor.quality.isBestSoFar == true)
    }

    @Test("A worse position reports a negative delta and is not the best")
    func worsePositionReportsNegativeDelta() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -65, count: 5)
        monitor.record(entryIndex: 0, at: 0)
        monitor.record(entryIndex: 40, at: 10)  // 4.0 entries/s
        monitor.captureReference(at: 10)

        feed(monitor, rssi: -85, count: 5, from: 11)
        monitor.record(entryIndex: 40, at: 11)
        monitor.record(entryIndex: 45, at: 21)  // 0.5 entries/s

        #expect(monitor.quality.deltaRSSI == -20)
        #expect(monitor.quality.deltaEntriesPerSecond == -3.5)
        #expect(monitor.quality.isBestSoFar == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/LinkQualityMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: compile failure — `value of type 'LinkQualityMonitor' has no member 'record(entryIndex:at:)'`.

- [ ] **Step 3: Implement**

In `GrowGuard/BLE/LinkQualityMonitor.swift`, add the constant next to the others:

```swift
    /// A position counts as measured only after this long with entries
    /// flowing — below that the number is noise.
    static let minimumMeasurementSeconds: TimeInterval = 10
```

Add the stored state below `private var samples: [Int] = []`:

```swift
    /// Start of the current position: index and time when the user last
    /// settled (connect, or "stay here")
    private var positionStartIndex: Int?
    private var positionStartTime: TimeInterval?
    private var latestIndex: Int?
    private var latestTime: TimeInterval?

    /// Snapshot of the position the user is comparing against
    private var referenceRSSI: Int?
    private var referenceEntriesPerSecond: Double?
    /// Best throughput seen anywhere this session
    private var bestEntriesPerSecond: Double?
```

Add the two methods:

```swift
    /// Records history progress. `entryIndex` is the sync's running entry
    /// counter; only its growth over time matters here.
    func record(entryIndex: Int, at now: TimeInterval) {
        if positionStartIndex == nil {
            positionStartIndex = entryIndex
            positionStartTime = now
        }
        latestIndex = entryIndex
        latestTime = now
        recomputeThroughput()
    }

    /// Freezes the current position as the thing to compare against. Called
    /// automatically when the stage first drops to poor, and by "stay here".
    func captureReference(at now: TimeInterval) {
        referenceRSSI = quality.smoothedRSSI
        referenceEntriesPerSecond = quality.entriesPerSecond

        // The user is about to move: start a fresh measurement window
        positionStartIndex = latestIndex
        positionStartTime = now
        recomputeThroughput()
    }
```

And the private recompute, called from both `record` methods (add the call at the end of `record(rssi:at:)` too):

```swift
    private func recomputeThroughput() {
        defer { recomputeDeltas() }

        guard let startIndex = positionStartIndex,
              let startTime = positionStartTime,
              let index = latestIndex,
              let time = latestTime else {
            quality.entriesPerSecond = nil
            return
        }

        let elapsed = time - startTime
        guard elapsed >= Self.minimumMeasurementSeconds, index > startIndex else {
            quality.entriesPerSecond = nil
            return
        }

        let rate = Double(index - startIndex) / elapsed
        quality.entriesPerSecond = rate
        if rate > (bestEntriesPerSecond ?? -.infinity) {
            bestEntriesPerSecond = rate
        }
    }

    private func recomputeDeltas() {
        if let reference = referenceRSSI, let current = quality.smoothedRSSI {
            quality.deltaRSSI = current - reference
        } else {
            quality.deltaRSSI = nil
        }

        if let reference = referenceEntriesPerSecond, let current = quality.entriesPerSecond {
            quality.deltaEntriesPerSecond = current - reference
        } else {
            quality.deltaEntriesPerSecond = nil
        }

        if let current = quality.entriesPerSecond, let best = bestEntriesPerSecond {
            quality.isBestSoFar = current >= best
        } else {
            quality.isBestSoFar = false
        }
    }
```

At the end of `record(rssi:at:)`, replace the last line so deltas refresh with each sample:

```swift
        quality.stage = Self.stage(for: median, current: quality.stage)
        recomputeDeltas()
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/LinkQualityMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`, 8 tests passed.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/BLE/LinkQualityMonitor.swift GrowGuardTests/BLE/LinkQualityMonitorTests.swift
git commit -m "Add reference position, delta and throughput to LinkQualityMonitor"
```

---

### Task 3: Connection gaps and the automatic reference

**Files:**
- Modify: `GrowGuard/BLE/LinkQualityMonitor.swift`
- Modify: `GrowGuardTests/BLE/LinkQualityMonitorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: `markDisconnected(at:)`, `markConnected(at:)`, `reset()`, `summary` returning `LinkQualitySummary` (fields: `entryCount`, `reconnects`, `medianRSSI`, `worstRSSI`).

- [ ] **Step 1: Write the failing tests**

Append inside the `LinkQualityMonitorTests` struct:

```swift
    @Test("A connection gap clears the needle instead of freezing it")
    func disconnectDoesNotFreezeTheNeedle() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -62, count: 5)
        #expect(monitor.quality.stage == .good)

        monitor.markDisconnected(at: 10)

        // A stale "good" here is exactly the lie the hardcoded .good told.
        #expect(monitor.quality.stage == .disconnected)
        #expect(monitor.quality.smoothedRSSI == nil)
        #expect(monitor.quality.entriesPerSecond == nil)
    }

    @Test("Reconnect starts a fresh measurement window")
    func reconnectRestartsMeasurement() {
        let monitor = LinkQualityMonitor()
        monitor.record(entryIndex: 0, at: 0)
        monitor.record(entryIndex: 40, at: 10)
        monitor.markDisconnected(at: 11)
        monitor.markConnected(at: 20)

        // Old samples must not bleed into the new window
        feed(monitor, rssi: -68, count: 5, from: 20)
        #expect(monitor.quality.stage == .good)
        #expect(monitor.quality.entriesPerSecond == nil)

        monitor.record(entryIndex: 40, at: 21)
        monitor.record(entryIndex: 60, at: 31)
        #expect(monitor.quality.entriesPerSecond == 2.0)
    }

    @Test("Summary reports what the sync log needs")
    func summaryReportsSessionFacts() {
        let monitor = LinkQualityMonitor()
        feed(monitor, rssi: -70, count: 3)
        monitor.record(rssi: -86, at: 4)
        monitor.record(rssi: -64, at: 5)
        monitor.record(entryIndex: 0, at: 0)
        monitor.record(entryIndex: 300, at: 100)
        monitor.markDisconnected(at: 101)
        monitor.markConnected(at: 103)

        let summary = monitor.summary
        #expect(summary.entryCount == 300)
        #expect(summary.reconnects == 1)
        #expect(summary.worstRSSI == -86)
        #expect(summary.medianRSSI == -70)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the `-only-testing:GrowGuardTests/LinkQualityMonitorTests` command from Task 2 Step 2.
Expected: compile failure — `no member 'markDisconnected(at:)'`.

- [ ] **Step 3: Implement**

Add to `GrowGuard/BLE/LinkQualityMonitor.swift`, above `LinkQualityMonitor`:

```swift
/// End-of-sync facts for the log line that saves the next analysis
struct LinkQualitySummary: Equatable {
    var entryCount: Int = 0
    var reconnects: Int = 0
    var medianRSSI: Int?
    var worstRSSI: Int?
}
```

Add state inside the class, next to the other stored properties:

```swift
    /// Every sample of the session, for the closing summary
    private var allSamples: [Int] = []
    private var reconnectCount = 0
    private var firstIndex: Int?
```

In `record(rssi:at:)`, record the sample for the summary as the first line:

```swift
        allSamples.append(rssi)
```

In `record(entryIndex:at:)`, remember the first index ever seen, right after the `positionStartIndex` block:

```swift
        if firstIndex == nil { firstIndex = entryIndex }
```

Add the three new methods:

```swift
    /// The link dropped: the needle must go blank, not stale.
    func markDisconnected(at now: TimeInterval) {
        samples.removeAll()
        quality.stage = .disconnected
        quality.smoothedRSSI = nil
        quality.entriesPerSecond = nil
        quality.deltaRSSI = nil
        quality.deltaEntriesPerSecond = nil
        quality.isBestSoFar = false

        positionStartIndex = nil
        positionStartTime = nil
        latestIndex = nil
        latestTime = nil
    }

    /// Reconnected: start measuring this position from scratch.
    func markConnected(at now: TimeInterval) {
        reconnectCount += 1
        samples.removeAll()
        quality.stage = .unknown
        quality.smoothedRSSI = nil
        quality.entriesPerSecond = nil
    }

    /// Full reset between syncs
    func reset() {
        samples.removeAll()
        allSamples.removeAll()
        reconnectCount = 0
        firstIndex = nil
        positionStartIndex = nil
        positionStartTime = nil
        latestIndex = nil
        latestTime = nil
        referenceRSSI = nil
        referenceEntriesPerSecond = nil
        bestEntriesPerSecond = nil
        quality = LinkQuality()
    }

    /// Facts for the closing log line of a sync
    var summary: LinkQualitySummary {
        LinkQualitySummary(
            entryCount: (latestIndex ?? firstIndex ?? 0) - (firstIndex ?? 0),
            reconnects: reconnectCount,
            medianRSSI: allSamples.isEmpty ? nil : Self.median(of: allSamples),
            worstRSSI: allSamples.min()
        )
    }
```

Note: `markConnected` counts reconnects, so the *first* connect of a sync must not call it — `DeviceConnection` calls `reset()` when a fresh flow starts (Task 4).

- [ ] **Step 4: Run tests to verify they pass**

Run the `-only-testing:GrowGuardTests/LinkQualityMonitorTests` command.
Expected: `** TEST SUCCEEDED **`, 11 tests passed.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/BLE/LinkQualityMonitor.swift GrowGuardTests/BLE/LinkQualityMonitorTests.swift
git commit -m "Handle connection gaps and session summary in LinkQualityMonitor"
```

---

### Task 4: Wire it into DeviceConnection, one timer at 1 Hz

**Files:**
- Modify: `GrowGuard/BLE/DeviceConnection.swift` (`startRSSIMonitoring()`, publishers section)
- Modify: `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift` (`startConnectionQualityMonitoring()`)
- Modify: `GrowGuard/BLE/DeviceConnection+PeripheralLink.swift` (`didReadRSSI`)
- Modify: `GrowGuardTests/BLE/FakeBLETransport.swift`
- Create: `GrowGuardTests/BLE/LinkQualityIntegrationTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `LinkQualityMonitor`, `LinkQuality` from Tasks 1–3.
- Produces: `DeviceConnection.linkQualityPublisher: AnyPublisher<LinkQuality, Never>`, `DeviceConnection.linkQuality: LinkQuality`, `DeviceConnection.captureLinkQualityReference()`, and `FakeFlowerCarePeripheral.rssiSequence: [Int]`.

- [ ] **Step 1: Make the fake's RSSI scriptable**

In `GrowGuardTests/BLE/FakeBLETransport.swift`, add to `FakeFlowerCarePeripheral`'s "Device contents" section:

```swift
    /// RSSI values handed out in order; the last one repeats. Lets a test
    /// simulate the user walking around.
    var rssiSequence: [Int] = [-55]
    private var rssiIndex = 0
```

Replace the whole `readRSSI()` method:

```swift
    func readRSSI() {
        let value = rssiSequence[min(rssiIndex, rssiSequence.count - 1)]
        rssiIndex += 1
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didReadRSSI: value, error: nil)
        }
    }
```

- [ ] **Step 2: Write the failing integration test**

Create `GrowGuardTests/BLE/LinkQualityIntegrationTests.swift`:

```swift
//
//  LinkQualityIntegrationTests.swift
//  GrowGuardTests
//
//  DeviceConnection must feed the monitor and publish the verdict, and must
//  sample fast enough during a sync to be useful while walking around.
//

import Testing
import Combine
import Foundation
@testable import GrowGuard

@MainActor
@Suite(.serialized)
struct LinkQualityIntegrationTests {

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
        await drainMainActor()
    }

    @Test("A weak link is published as poor during the sync")
    func weakLinkIsPublishedAsPoor() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 400)
        sensor.rssiSequence = [-85]

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var stages: [LinkQualityStage] = []
        let cancellable = connection.linkQualityPublisher.sink { stages.append($0.stage) }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 12)
        await pump()

        #expect(stages.contains(.poor), "Weak link never surfaced: \(stages)")
    }

    @Test("RSSI is sampled at 1 Hz while history is syncing")
    func samplesFastDuringSync() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 400)
        sensor.rssiSequence = [-75]

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        var updates = 0
        let cancellable = connection.linkQualityPublisher.sink { _ in updates += 1 }
        defer { cancellable.cancel() }

        pool.connect(to: sensor.identifier.uuidString)
        await pump()
        scheduler.advance(by: 12)
        await pump()

        // ~10 samples in 10 s of syncing. The old 5 s interval would give 2,
        // which is useless for walking around. Two timers gave 4 duplicates.
        #expect(updates >= 8, "Expected ~1 Hz sampling, got \(updates) updates")
        #expect(updates <= 14, "More updates than 1 Hz — duplicate timers are back")
    }
}
```

- [ ] **Step 3: Register the new test file and run to verify failure**

Add the four `project.pbxproj` entries for `LinkQualityIntegrationTests.swift` (GrowGuardTests target), as in Task 1 Step 4. Then run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/LinkQualityIntegrationTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: compile failure — `value of type 'DeviceConnection' has no member 'linkQualityPublisher'`.

- [ ] **Step 4: Add the monitor and publisher to DeviceConnection**

In `GrowGuard/BLE/DeviceConnection.swift`, next to the other subjects (after `let rssiSubject = ...`):

```swift
    /// Subject für das Link-Quality-Urteil (Standort-Assistent)
    let linkQualitySubject = CurrentValueSubject<LinkQuality, Never>(LinkQuality())

    /// Verdict logic — fed by RSSI samples, progress and connect events
    let linkQualityMonitor = LinkQualityMonitor()
```

Next to the other publishers (after `rssiPublisher`):

```swift
    /// Public Publisher für das Link-Quality-Urteil
    var linkQualityPublisher: AnyPublisher<LinkQuality, Never> {
        linkQualitySubject.eraseToAnyPublisher()
    }

    /// Aktuelles Urteil ohne Subscription
    var linkQuality: LinkQuality { linkQualitySubject.value }

    /// Setzt den Vergleichspunkt neu ("Hier bleiben")
    func captureLinkQualityReference() {
        linkQualityMonitor.captureReference(at: now())
        linkQualitySubject.send(linkQualityMonitor.quality)
    }
```

`DeviceConnection` has no clock yet — its init is `init(deviceUUID:scheduler:)` at `DeviceConnection.swift:256`. Add one, mirroring `ConnectionPoolManager.init`. Add the stored property next to `scheduler`:

```swift
    /// Zeitquelle für den LinkQualityMonitor — in Tests virtuelle Zeit
    let now: () -> TimeInterval
```

Change the init at `DeviceConnection.swift:256`:

```swift
    init(deviceUUID: String,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
```
(keep the rest of the existing init body unchanged)

And at `ConnectionPoolManager.swift:147`, hand the pool's own clock down so virtual time reaches the monitor:

```swift
        let newConnection = DeviceConnection(deviceUUID: deviceUUID, scheduler: scheduler, now: now)
```

- [ ] **Step 5: Consolidate the two RSSI timers**

In `GrowGuard/BLE/DeviceConnection.swift`, replace the body of `startRSSIMonitoring()`:

```swift
    /// Startet RSSI Monitoring für Verbindungsqualität.
    /// Während eines History-Syncs 1 Hz (der Nutzer soll beim Umherlaufen
    /// sofortiges Feedback bekommen), sonst 5 s. `readRSSI()` ist auf iOS
    /// eine lokale Controller-Abfrage und kostet keinen Funkverkehr.
    func startRSSIMonitoring() {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            return
        }

        let interval: TimeInterval = isHistoryFlowActive ? 1.0 : 5.0

        rssiMonitorTask?.cancel()
        rssiMonitorTask = scheduler.scheduleRepeating(every: interval) { [weak self] in
            guard let self = self,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected else {
                self?.rssiMonitorTask?.cancel()
                self?.rssiMonitorTask = nil
                return
            }

            peripheral.readRSSI()
        }
    }
```

`isHistoryFlowActive` is `private` today; change it to `internal` (drop the `private`) so the extension and this method can read it.

In `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift`, delete `startConnectionQualityMonitoring()` entirely and replace its call site in `startHistoryDataFlow()` (currently `startConnectionQualityMonitoring()`) with:

```swift
        // Sampling auf 1 Hz hochschalten — ein Timer, nicht zwei
        startRSSIMonitoring()
```

The remaining callers are `suspendHistoryFlow()` (`DeviceConnection+HistoryFlow.swift:270`) and `cleanupHistoryFlow()` (`:289`). Replace the call in both with:

```swift
        // Sampling zurück auf den Ruhe-Takt
        rssiMonitorTask?.cancel()
        rssiMonitorTask = nil
```

Then delete `stopConnectionQualityMonitoring()` (`:325-328`) and the now-unused `connectionMonitorTask` property (`DeviceConnection.swift:152`). Make `rssiMonitorTask` internal (drop its `private`) so the extension can reach it.

Verify nothing is left behind:
```bash
grep -rn "connectionMonitorTask\|ConnectionQualityMonitoring" --include="*.swift" GrowGuard/
```
Expected: no output.

- [ ] **Step 6: Feed the monitor**

In `GrowGuard/BLE/DeviceConnection+PeripheralLink.swift`, in `peripheralLink(_:didReadRSSI:error:)`, after the existing `rssiSubject.send(rssi)`:

```swift
        linkQualityMonitor.record(rssi: rssi, at: now())

        // Beim ersten Absacken auf poor den Vergleichspunkt festhalten —
        // das ist der Moment, in dem der Nutzer losgeht
        if linkQualityMonitor.quality.stage == .poor,
           linkQualityMonitor.quality.deltaRSSI == nil {
            linkQualityMonitor.captureReference(at: now())
        }
        linkQualitySubject.send(linkQualityMonitor.quality)
```

In `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift`, wherever `historyProgressSubject.send((nextIndex, totalEntries))` happens (there are three call sites — in `processHistoryData`, in `handleEntryFailure`, and the initial `historyProgressSubject.send((0, totalEntries))`), add directly after each:

```swift
        linkQualityMonitor.record(entryIndex: currentEntryIndex, at: now())
        linkQualitySubject.send(linkQualityMonitor.quality)
```

In `startHistoryDataFlow()`, for a fresh flow only (inside the `else` branch of `if isResumingHistory`), reset the monitor:

```swift
            linkQualityMonitor.reset()
```

In `GrowGuard/BLE/DeviceConnection.swift`, in `handleDisconnected(error:)`, as the first statement:

```swift
        linkQualityMonitor.markDisconnected(at: now())
        linkQualitySubject.send(linkQualityMonitor.quality)
```

and in `handleConnected()`, after `stateSubject.send(.connected)`:

```swift
        if isHistoryFlowActive {
            linkQualityMonitor.markConnected(at: now())
            linkQualitySubject.send(linkQualityMonitor.quality)
        }
```

- [ ] **Step 7: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`. The whole suite must pass, not just the new tests — `BLEPerformanceTests.trafficBudget` in particular proves the extra sampling did not add GATT traffic.

- [ ] **Step 8: Commit**

```bash
git add GrowGuard/BLE GrowGuardTests/BLE GrowGuard.xcodeproj/project.pbxproj
git commit -m "Feed LinkQualityMonitor from DeviceConnection, one RSSI timer at 1 Hz during sync"
```

---

### Task 5: One source of truth in the ViewModel

**Files:**
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift:41`, `:157-161`, `:458-467`
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsView.swift:85-89`

**Interfaces:**
- Consumes: `DeviceConnection.linkQualityPublisher`, `LinkQuality`, `LinkQualityStage`.
- Produces: `DeviceDetailsViewModel.linkQuality: LinkQuality` (replaces `connectionDistanceHint: String`).

- [ ] **Step 1: Replace the ad-hoc hint**

In `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift`, replace the property at line 41:

```swift
    var linkQuality: LinkQuality = LinkQuality()
```

Replace the RSSI subscription (lines ~157-161):

```swift
        // Subscribe zum Link-Quality-Urteil (eine Quelle für Signalgüte)
        poolRSSISubscription = connection.linkQualityPublisher.sink { [weak self] quality in
            Task { @MainActor in
                self?.linkQuality = quality
            }
        }
```

Delete `distanceHint(forRSSI:)` (lines ~458-467) entirely. It was a third, unsmoothed interpretation with thresholds that disagreed with the spec (−65 vs −70) and hard-coded English strings.

- [ ] **Step 2: Update the consumer**

In `GrowGuard/DeviceDetails/DeviceDetailsView.swift`, replace the block at lines 85-89 that reads `viewModel.connectionDistanceHint`:

```swift
                        if let rssi = viewModel.linkQuality.smoothedRSSI {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text(L10n.Linkquality.label(rssi))
                            }
                        }
```

Add to `GrowGuard/Strings/Localizable.strings`:

```
/* Link Quality */
"linkquality.label" = "Signal: %d dBm";
```

Regenerate:
```bash
swiftgen
```

- [ ] **Step 3: Build and run the full suite**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`. A compile error mentioning `connectionDistanceHint` means a consumer was missed — `grep -rn "connectionDistanceHint" --include="*.swift" .` must return nothing.

- [ ] **Step 4: Commit**

```bash
git add GrowGuard/DeviceDetails GrowGuard/Strings
git commit -m "Replace ad-hoc distance hint with the shared link quality verdict"
```

---

### Task 6: The assistant UI in HistoryLoadingView

**Files:**
- Modify: `GrowGuard/DeviceDetails/HistoryLoadingView.swift` (`HistoryConnectionQuality` enum at :20, `connectionQualityView` at :319, the hardcoded assignment at :477)
- Modify: `GrowGuard/Strings/Localizable.strings`

**Interfaces:**
- Consumes: `DeviceDetailsViewModel.linkQuality`, `LinkQualityStage`, `DeviceConnection.captureLinkQualityReference()`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Delete the parallel enum and the lie**

In `GrowGuard/DeviceDetails/HistoryLoadingView.swift`, delete the `HistoryConnectionQuality` enum (lines 20-25) and the `@State private var connectionQuality` property (line 35). Delete the hardcoded assignment at line 477 including its comment:

```swift
            // Set connection quality to good for ConnectionPool (BLE is inherently good if connected)
            self.connectionQuality = .good
```

Replace every remaining `connectionQuality` reference with `viewModel.linkQuality.stage`, and change the `switch` cases from `.unknown/.poor/.fair/.good` to also handle `.disconnected`.

- [ ] **Step 2: Rewrite the quality view**

Replace `connectionQualityView` (line ~319) with:

```swift
    private var connectionQualityView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text(qualityText)
                    .font(.caption.bold())
                    .foregroundColor(qualityColor)
                if let rssi = viewModel.linkQuality.smoothedRSSI {
                    Text(L10n.Linkquality.dbm(rssi))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let rate = viewModel.linkQuality.entriesPerSecond {
                    Text(L10n.Linkquality.rate(String(format: "%.1f", rate)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if viewModel.linkQuality.isBestSoFar {
                    Text(L10n.Linkquality.bestSoFar)
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }
            }

            if viewModel.linkQuality.stage == .poor {
                Text(L10n.Linkquality.moveHint)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            if let delta = viewModel.linkQuality.deltaRSSI {
                HStack(spacing: 4) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(delta >= 0 ? L10n.Linkquality.better(delta) : L10n.Linkquality.worse(abs(delta)))
                }
                .font(.caption.bold())
                .foregroundColor(delta >= 0 ? .green : .orange)

                Button(L10n.Linkquality.stayHere) {
                    viewModel.captureLinkQualityReference()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: viewModel.linkQuality.stage) { _, _ in
            // Beim Umherlaufen und Hinhocken am Blumentopf schaut niemand
            // aufs Display — der Impuls macht das Feature erst benutzbar.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
```

Replace `qualityText`, `qualityColor` and `barColor(for:)` with versions that switch on `LinkQualityStage` — every case must be handled or the compiler will not accept the switch:

```swift
    private var qualityText: String {
        switch viewModel.linkQuality.stage {
        case .unknown:      return L10n.Linkquality.unknown
        case .disconnected: return L10n.Linkquality.disconnected
        case .poor:         return L10n.Linkquality.poor
        case .fair:         return L10n.Linkquality.fair
        case .good:         return L10n.Linkquality.good
        }
    }

    private var qualityColor: Color {
        switch viewModel.linkQuality.stage {
        case .unknown, .disconnected: return .gray
        case .poor:                   return .orange
        case .fair:                   return .yellow
        case .good:                   return .green
        }
    }

    private func barColor(for index: Int) -> Color {
        switch viewModel.linkQuality.stage {
        case .unknown, .disconnected: return .gray
        case .poor:                   return index == 0 ? .orange : .gray
        case .fair:                   return index <= 1 ? .yellow : .gray
        case .good:                   return .green
        }
    }
```

- [ ] **Step 3: Add the strings and a passthrough on the ViewModel**

Add to `GrowGuard/Strings/Localizable.strings`:

```
"linkquality.dbm" = "%d dBm";
"linkquality.rate" = "%@ entries/s";
"linkquality.moveHint" = "Weak signal. Move closer to the plant or clear obstacles between phone and sensor.";
"linkquality.better" = "%d dB better than before";
"linkquality.worse" = "%d dB worse than before";
"linkquality.stayHere" = "Stay here";
"linkquality.bestSoFar" = "best spot so far";
"linkquality.disconnected" = "Connection lost, reconnecting…";
"linkquality.unknown" = "Checking…";
"linkquality.poor" = "Poor";
"linkquality.fair" = "Fair";
"linkquality.good" = "Good";
```

Run `swiftgen`.

Add to `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift`:

```swift
    /// "Hier bleiben" — Vergleichspunkt neu setzen
    func captureLinkQualityReference() {
        deviceConnection?.captureLinkQualityReference()
    }
```

- [ ] **Step 4: Build and verify manually**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`.

The view has no unit tests (consistent with the rest of the loading view), so verify on hardware: start a history sync, walk away from the sensor until the stage turns orange, confirm the move hint and the comparison line appear, walk back, confirm the delta turns green and a haptic pulse fires at each stage change.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/DeviceDetails GrowGuard/Strings
git commit -m "Show real link quality and placement guidance during history sync"
```

---

### Task 7: Logging

**Files:**
- Modify: `GrowGuard/BLE/DeviceConnection+PeripheralLink.swift` (stage transitions)
- Modify: `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift` (`cleanupHistoryFlow`)
- Modify: `GrowGuard/BLE/DeviceConnection.swift` (`captureLinkQualityReference`)

**Interfaces:**
- Consumes: `LinkQualityMonitor.summary`, `LinkQualitySummary`.
- Produces: nothing.

- [ ] **Step 1: Log stage transitions**

In `GrowGuard/BLE/DeviceConnection+PeripheralLink.swift`, in `didReadRSSI`, wrap the monitor feed so a transition is logged once:

```swift
        let previousStage = linkQualityMonitor.quality.stage
        linkQualityMonitor.record(rssi: rssi, at: now())
        let newStage = linkQualityMonitor.quality.stage
        if newStage != previousStage {
            AppLogger.ble.bleConnection("📶 \(previousStage.rawValue) → \(newStage.rawValue): \(rssi) dBm (median \(self.linkQualityMonitor.quality.smoothedRSSI ?? 0)) for device \(self.deviceUUID)")
        }
```

- [ ] **Step 2: Log the per-position summary**

In `GrowGuard/BLE/DeviceConnection.swift`, in `captureLinkQualityReference()`, before capturing:

```swift
        let quality = linkQualityMonitor.quality
        AppLogger.ble.bleConnection("📍 Position marked for device \(self.deviceUUID): \(quality.smoothedRSSI ?? 0) dBm, \(quality.entriesPerSecond.map { String(format: "%.1f", $0) } ?? "—") entries/s")
```

- [ ] **Step 3: Log the closing line of every sync**

In `GrowGuard/BLE/DeviceConnection+HistoryFlow.swift`, in `cleanupHistoryFlow()`, before the state reset:

```swift
        let linkSummary = linkQualityMonitor.summary
        AppLogger.ble.info("📶 Sync link summary for device \(self.deviceUUID): \(linkSummary.entryCount) entries, \(linkSummary.reconnects) reconnects, median \(linkSummary.medianRSSI ?? 0) dBm, worst \(linkSummary.worstRSSI ?? 0) dBm")
```

- [ ] **Step 4: Run the full suite**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Update the reliability doc**

Add a section to `BLE-Reliability.md` after "Connection-window budget", describing: one RSSI timer (1 Hz during sync, 5 s otherwise), the bands and hysteresis, and that `LinkQualityMonitor` is the single source of truth for signal quality (the old `distanceHint` and the hardcoded `.good` are gone).

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/BLE BLE-Reliability.md
git commit -m "Log link quality transitions and a per-sync summary line"
```

---

## Notes for the implementer

- `readRSSI()` on iOS is a local controller query, so 1 Hz costs no air time. If `BLEPerformanceTests.trafficBudget` starts failing, something added *GATT* traffic — that is a real regression, not a budget to bump.
- The monitor deliberately holds no reference to `DeviceConnection`. Keep it that way; it is what makes the verdict logic testable.
- `markConnected()` counts reconnects. A fresh sync calls `reset()` instead, so the summary does not report a phantom reconnect for the first connect.

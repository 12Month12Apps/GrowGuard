# BLE Testing Strategy — Path to Production Confidence

Status: Proposal (2026-06-11)
Goal: Ship GrowGuard with high confidence that BLE communication with Xiaomi FlowerCare
sensors works reliably — without destabilizing the current, working implementation.

---

## 1. Current State Analysis

### 1.1 Architecture: two parallel BLE stacks

| Stack | Files | Used by |
|---|---|---|
| **Legacy** — `FlowerCareManager` (singleton, ~1.7k lines) | `BLE/FlowerManager.swift` | `HistoryLoadingView`, `AppIntent` (Siri), `DeviceDetailsViewModel` (fallback path), `BLEBenchmark` |
| **New** — `ConnectionPoolManager` + `DeviceConnection` | `BLE/ConnectionPoolManager.swift`, `BLE/DeviceConnection.swift` | `BackgroundSensorDataService`, `InitialSensorDataService`, `OverviewList`, `DeviceDetailsViewModel` (default path), `MultiDeviceTestView` |

`SettingsStore.connectionMode` toggles between them — but only inside
`DeviceDetailsViewModel`. Other call sites are hardwired to one stack. Consequence:
**even with the flag set to "connectionPool", the legacy singleton is still active**
(Siri intent, history loading UI, LED blink). Both stacks own their own
`CBCentralManager`, can scan/connect to the same peripheral concurrently, and only the
pool has state restoration. This is the single biggest source of nondeterministic BLE
behavior and must be covered (or eliminated) before launch.

### 1.2 Testability blockers (why we can't unit-test the interesting parts today)

1. **No seam over CoreBluetooth.** `CBCentralManager` / `CBPeripheral` are used
   directly. They cannot be instantiated meaningfully in tests (simulator has no BLE),
   so connection, auth, history-resume and retry logic is untestable as written.
2. **Singletons everywhere.** `FlowerCareManager.shared`, `ConnectionPoolManager.shared`,
   `RepositoryManager.shared`, `PlantMonitorService.shared` are referenced from inside
   the BLE layer — tests can't isolate state, and the BLE layer reaches "up" into
   persistence/validation.
3. **Timer-chained protocol sequencing.** The FlowerCare GATT flow (mode write → wait
   150 ms → read time → wait 100 ms → entry count → …) is implemented as nested
   `Timer.scheduledTimer` / `DispatchQueue.asyncAfter` closures. Tests would need real
   wall-clock waits; timing changes are untested and risky.
4. **Logic lives in delegate callbacks.** Decisions (resume vs. restart history flow,
   reconnect-or-give-up, incremental sync start index) are embedded in
   `didDisconnectPeripheral` / `didUpdateValueFor` instead of a testable state machine.

### 1.3 Existing test coverage

| Suite | Verdict |
|---|---|
| `SensorDataDecoderTests` | Good direction, weak execution: historical-data tests are commented out; 3 tests assert nothing (`#expect(true)`); no fuzz/garbage-input cases; advertisement decoders untested. |
| `FlowerManagerHistoryTests` | Good pattern: `#if DEBUG` test hooks + mock subclass with `centralManager = nil`. Covers initial state, entry-count decode, cancellation. Legacy stack only. |
| `DeviceConnectionHistoryTests` | **Hardware tests in the default test plan.** Hardcoded device UUID, expectations with 30–120 s timeouts. In CI/simulator they burn ~7–8 minutes and fail. No coverage of `DeviceConnection` logic without a physical sensor. |

`GrowGuard.xctestplan` runs all of the above together — so the suite is effectively
not runnable in CI, which means today there is **zero automated regression protection**
for the BLE layer.

### 1.4 Concrete risk hot-spots found during analysis (test targets!)

- **Dual-stack interference** (see 1.1) — two centrals connecting to one peripheral.
- **Disconnect/reconnect loops**: legacy `didDisconnectPeripheral` has 4 different
  reconnect branches; `DeviceConnection.shouldAutoReconnect` returns `true` whenever a
  history flow is active with no metadata yet — combined with the pool's retry counter
  this is exactly the loop class described in `BLE-Loop-Detection-Concept.md`.
- **Strong `self` captures** in `DispatchQueue.asyncAfter` (auth timeout, settle delays)
  keep managers alive and can fire against a torn-down flow.
- **`attemptReconnection`** (legacy) declares success after a fixed 0.3 s — a race, not
  a check.
- **Decoder fragility**: `decodeHistoricalSensorData` silently returns `nil` if device
  time wasn't read first (per-instance `secondsSinceBoot` state);
  `decodeMiBeaconAdvertisement` / `decodeServiceAdvertisement` are self-described
  guesses; `decodeRealTimeSensorValues` requires exactly 16 bytes.
- **Incremental sync index** (`lastHistoryIndex`) update logic writes to the repository
  from inside BLE callbacks; off-by-one or reset bugs corrupt future syncs.
- `static var shared = FlowerCareManager()` is mutable — anything can replace the
  singleton.

---

## 2. Strategy: a layered test pyramid for BLE

We cannot automate a radio link end-to-end, so confidence comes from four layers, each
catching a different failure class:

```
   L4  Field/Beta (TestFlight + metrics)        — real-world RF, iOS lifecycle
   L3  Hardware-in-the-loop (manual + scripted) — real sensor, real timing
   L2  Simulated-peripheral integration tests   — protocol logic, reconnect, resume
   L1  Pure unit tests (decoder, state machine) — byte-level correctness
```

The principle for "without breaking things": **L1 and L2 are added around the existing
code via additive seams (default-argument injection). The legacy stack is not touched
until L2/L3 prove the pool stack, then it is removed behind the existing feature flag.**

---

## 3. Phased Plan

### Phase 1 — Stop the bleeding (no production code changes, ~1 day)

1. **Split test plans.**
   - `UnitTests.xctestplan` → `SensorDataDecoderTests`, `FlowerManagerHistoryTests`,
     ViewModel tests. Runs in CI on every push.
   - `HardwareTests.xctestplan` → `DeviceConnectionHistoryTests`. Run manually with a
     real sensor; read the device UUID from an env var
     (`TEST_FLOWERCARE_UUID`) instead of the hardcoded constant, and `XCTSkip` when
     it's absent.
2. **CI gate**: `xcodebuild test -testPlan UnitTests` on the iPhone 17 simulator.
3. **Fix the assertion-free decoder tests** and re-enable the commented-out historical
   tests (they need `setDeviceBootTime` called first — that's the missing piece).

Exit criteria: green, sub-minute unit suite that runs on every commit.

### Phase 2 — Build the byte-level safety net (L1, ~2–3 days)

The decoder is pure Swift and the highest-ROI test surface. The app already logs every
raw frame as hex (`AppLogger` + `bleData`), so **real fixtures are free**: run one full
sync against a real sensor, export via `LogExportView`, and turn the hex dumps into a
fixture file.

Add tests for `SensorDataDecoder`:
- Real-frame fixtures: live values, historical entries, history metadata, entry count,
  firmware/battery, device time (golden tests — exact expected values).
- Boundary/garbage: empty, truncated (1…15 bytes), all-0xFF, oversized; assert `nil`,
  never a crash or a bogus value.
- Timestamp math: history decode **without** prior `setDeviceBootTime` → `nil`;
  `timestamp > secondsSinceBoot` → `nil`; correct date back-calculation.
- Advertisement decoders (MiBeacon, service data) — current behavior pinned as
  characterization tests, marked as "best-guess format".
- Property-style fuzz: random `Data` of random length into every decode function →
  must not crash (catches `withUnsafeBytes` range issues).

### Phase 3 — Seams + simulated sensor (L2, the core investment, ~1–2 weeks)

This is what makes connection logic testable **without rewriting it**.

1. **Protocol seam over CoreBluetooth** (additive, default = real implementation):
   ```swift
   protocol BLECentral {  // implemented by CBCentralManager via thin wrapper
       var state: CBManagerState { get }
       func retrievePeripherals(withIdentifiers: [UUID]) -> [BLEPeripheral]
       func connect(_ p: BLEPeripheral, options: [String: Any]?)
       func cancelConnection(_ p: BLEPeripheral)
       func scanForPeripherals(withServices: [CBUUID]?, options: [String: Any]?)
       func stopScan()
   }
   protocol BLEPeripheral: AnyObject {  // implemented by CBPeripheral wrapper
       var identifier: UUID { get }
       var state: CBPeripheralState { get }
       func discoverServices(_ uuids: [CBUUID]?)
       func writeValue(_ d: Data, forCharacteristic uuid: CBUUID, type: CBCharacteristicWriteType)
       func readValue(forCharacteristic uuid: CBUUID)
       func readRSSI()
   }
   ```
   `ConnectionPoolManager` and `DeviceConnection` get the dependency via initializer
   with a default argument (`central: BLECentral = CBCentralManagerWrapper(...)`) —
   **zero call-site changes, zero behavior changes.**
2. **Injectable clock/scheduler** for the timer chains (same pattern: default arg =
   real `Timer`). Tests advance time instantly; no flaky sleeps.
3. **`FakeFlowerCarePeripheral`**: a scriptable in-memory implementation of the real
   GATT protocol, seeded with the recorded frames from Phase 2:
   - auth challenge/response, mode change `0xA01F`, history mode `0xA00000`,
     entry count `0x3C`, entry fetch `0xA1 <idx LE>`, device time.
   - Scenario hooks: respond after N ms, drop connection at entry K, send corrupt
     frame, never respond (timeout path), report 0 entries.
4. **Scenario test suite** against `ConnectionPoolManager` + `DeviceConnection`
   (deterministic, milliseconds-fast):
   - Happy path: connect → auth → live data → full history sync → disconnect.
   - Incremental sync: `lastHistoryIndex` respected; full refresh when index ≥ total.
   - **Disconnect at entry K → auto-reconnect → resume at K** (not restart, no data
     gap, no duplicate entries).
   - Reconnect-loop guard: repeated instant disconnects → gives up after max retries,
     publishes error, **does not loop** (regression test for the documented loop bug).
   - Auth timeout → proceeds without auth → history still completes.
   - Metadata timeout (10 s) → clean failure state, timers all invalidated.
   - Cancellation mid-flow → no further fetches, state reset, no zombie timers
     (assert via injected scheduler).
   - Bluetooth powered off mid-flow / queued connects flush on power-on.
   - Multi-device: 3 simultaneous connections, data routed to the right publishers.
   - State restoration callback → already-connected peripheral resumes correctly.

Exit criteria: every bullet above is a green, CI-run test. These tests become the
contract any future BLE refactor must satisfy.

### Phase 4 — Hardware-in-the-loop (L3, ongoing, start ~2 days)

Automated tests prove logic; only real hardware proves RF behavior and iOS quirks.

1. **Scripted hardware suite** (the existing `DeviceConnectionHistoryTests`, kept and
   extended, run via `HardwareTests.xctestplan` on a real iPhone + sensor before each
   release).
2. **Manual release checklist** (one page, executed per release candidate):
   - Pair new sensor (Add Device flow), LED blink.
   - Full history sync (fresh sensor) and incremental sync (second run).
   - Walk out of range mid-sync → return → resume completes.
   - Low battery sensor, sensor at 8–10 m / through a wall.
   - App backgrounded mid-sync; app force-killed → state restoration.
   - Siri intent fetch; background task fetch (within the ~25 s budget); widget update.
   - Bluetooth toggled off/on mid-operation; Airplane mode.
   - Two sensors syncing in parallel.
   - **Both feature-flag modes** (`connectionPool` and legacy) until legacy is removed.
3. **Tracing**: install Apple's Bluetooth diagnostic profile / use PacketLogger for one
   full sync per release; archive the trace next to the release tag. When a beta user
   reports a BLE issue, compare their exported log (`LogExportView`) against it.
4. Optional but cheap insurance: an **ESP32/nRF52 dev board emulating the FlowerCare
   GATT service** gives a deterministic "sensor" you can script (force disconnects,
   corrupt frames) — bridges the gap between the in-memory fake and the real plant
   sensor.

### Phase 5 — Converge to one stack + field telemetry (L4, before submission)

1. **Decide: ConnectionPool is the production stack.** Sequence:
   a. Route the remaining legacy call sites (`HistoryLoadingView`, `AppIntent`,
      LED blink) through `DeviceConnection` — each move covered by Phase 3 scenarios.
   b. Flag default → `connectionPool` for the whole beta; legacy stays as emergency
      fallback.
   c. Delete `FlowerManager.swift` once beta exit criteria are met. One central, one
      code path, half the surface to test forever after.
2. **Measure, don't guess.** Add a tiny `BLESessionMetrics` (counts only, logged via
   AppLogger and visible in the log export): sync attempts, successes, entries fetched,
   reconnects per session, decode failures, time-to-sync. No backend needed — TestFlight
   feedback + log export is enough at this scale.
3. **TestFlight beta with exit criteria** (measured over, say, 2 weeks / ≥10 testers):
   - History sync success rate ≥ 95 % of attempted sessions.
   - Zero reconnect loops (no session with > 3 reconnects).
   - Zero decode crashes (fuzz layer should already guarantee this).
   - Background fetch completes within budget in ≥ 90 % of attempts.

---

## 4. What we explicitly do NOT do

- No big-bang rewrite of `FlowerManager.swift` — it gets deleted, not refactored, and
  only after the pool stack is proven by L2 + L3.
- No mocking of `CBCentralManager` via subclassing (fragile, Apple discourages it) —
  the wrapper-protocol seam is additive and safe.
- No UI tests for BLE flows — the simulator has no Bluetooth; UI tests would test mocks
  of mocks. ViewModel logic is covered by existing ViewModel unit tests instead.

## 5. Effort & order summary

| Phase | Effort | Risk to existing behavior | Outcome |
|---|---|---|---|
| 1. Test-plan split + CI | ~1 day | none | Suite runs at all |
| 2. Decoder fixtures + fuzz | 2–3 days | none | Byte-level safety net |
| 3. Seams + fake peripheral + scenarios | 1–2 weeks | minimal (default-arg injection) | Connection/resume/retry logic under test |
| 4. Hardware suite + checklist + tracing | 2 days + per release | none | RF/iOS reality check |
| 5. Single stack + beta metrics | 3–5 days + beta period | controlled via existing flag | Production confidence, smaller surface |

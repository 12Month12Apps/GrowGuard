# BLE Reliability — What Is Implemented

The ConnectionPool stack is the only BLE stack (legacy `FlowerCareManager`
deleted 2026-06). This documents the reliability mechanisms that actually
exist in code, their parameters, and how to tune them. The corresponding
tests live in `GrowGuardTests/BLE/` and run in virtual time.

## Reconnect backoff — `ReconnectPolicy` (GrowGuard/BLE/ReconnectPolicy.swift)

One pure struct replaces the previously duplicated retry blocks in
`ConnectionPoolManager`. `attempt` counts failures so far; after
`maxAttempts` (3) the pool gives up with `.maxRetriesExceeded`.

| Disconnect reason | Delay attempt 1 | Delay attempt 2 | Rationale |
|---|---|---|---|
| `clean` (sensor idle-drop), `peripheralDisconnected` (CBError 7) | 1 s | 2 s | Sensor is reachable, get back fast |
| `connectionTimeout` (CBError 6), `failedToConnect`, `unknown` | 2 s | 4 s | Radio environment needs air |
| `appTimeout` (our 10 s connect watchdog) | 1 s | 2 s | Historical behavior preserved |
| `bluetoothUnavailable` | — | — | Queued, retried on power-on; never burns attempts |

The auto-reconnect delay after an unexpected mid-sync disconnect is the
attempt-1 delay for the mapped reason. All delays run on the injected
`BLEScheduler` — no `Task.sleep` — so tests control time.

## Disconnect-loop guard — `DisconnectLoopGuard`

Trips when **5 disconnects without history progress** happen within
**120 s**. The progress delta is the discriminator: a flaky link that drops
five times while the entry index advances is fine (each progressing drop
resets the streak); a frozen index is a loop and aborts with
`.disconnectLoopDetected` instead of reconnecting forever (protects the
~25 s background-fetch budget too). `resetRetryCounter(for:)` —
called on user-initiated connects — resets the guard.

## Session contract: retry budget + state semantics

- **Max-retries is sticky by design** (pinned by
  `maxRetriesStickyUntilReset`): once a device exhausts its 3 attempts, the
  pool refuses further `connect(to:)` calls and re-emits `.error` until
  `resetRetryCounter(for:)` is called. This prevents auto-paths from retrying
  forever.
- **Every caller that starts a new session MUST call
  `resetRetryCounter(for:)` first.** Callers: `DeviceDetailsViewModel`,
  `AppIntent`, `BLEBenchmark`, `InitialSensorDataService` (dashboard live
  refresh), `BackgroundHistorySyncService` (background history sync). Forgetting this
  makes a device permanently show "Error" after one unreachable episode
  (regression test: `dashboardRefreshResetsRetryBudget`).
- **Sensor-initiated disconnects are not errors.** FlowerCare drops the link
  itself after idle (CBError 7, `peripheralDisconnected`);
  `DeviceConnection.handleDisconnected` maps it to `.disconnected`, not
  `.error` (regression test: `sensorIdleDisconnectIsNotAnError`).
- **Retries preserve the session config.** The pool's backoff path re-uses
  the connection's `autoStartHistoryFlowEnabled` — a live-only refresh never
  escalates into a full history sync on retry (regression test:
  `retryPreservesHistoryFlowFlag`).
- **An active history sync is protected from live-only callers.**
  `setAutoStartHistoryFlowEnabled(false)` is deferred while
  `isHistoryFlowActive` (the flag gates resume-after-reconnect), and
  `InitialSensorDataService` skips syncing devices entirely. To cancel a sync
  deliberately, call `cleanupHistoryFlow()` *first*, then disable auto-start
  (regression tests: `dashboardRefreshDoesNotBreakActiveHistorySync`,
  `autoStartDisableIgnoredDuringActiveFlow`).
- **UI reads sync state from the pool, not from ActivityKit.** The overview's
  per-device loading indicator subscribes to `historyProgressPublisher` /
  `isHistoryLoading`; the Live Activity is only a fallback (it does not exist
  on Mac "Designed for iPhone" or with Live Activities disabled).

## Background arming (arm-don't-fetch)

Spec: `docs/superpowers/specs/2026-06-12-background-ble-design.md`.
Background triggers (BGAppRefreshTask, silent push, enter-background) call
`ConnectionPoolManager.armBackgroundConnect(for:)` instead of racing a full
connect+read against the ~30 s window:

- **No watchdog, no retry budget by design.** The pending `connect()` IS
  the reliability mechanism — iOS completes it whenever the sensor
  advertises, minutes or hours later. Armed devices never enter the
  sticky-error path; `didFailToConnect` keeps them armed without burning
  retries (tests: `BackgroundArmTests`).
- **Armed set persisted** in UserDefaults key `ble_background_armed_devices`
  so a state-restoration relaunch re-recognizes armed devices; the
  `poweredOn` handler re-issues their pending connects.
- **Wake handling never re-arms** (`BackgroundBLEWakeService`): the sensor
  advertises continuously in range, so re-arming after a read would create a
  connect/disconnect wake loop. Arming comes exclusively from time-based
  triggers — one trigger, one sample (tests: `BackgroundWakeServiceTests`).
- **History sync in BGProcessingTask** (`BackgroundHistorySyncService`):
  sequential per device, suspends via `suspendHistoryFlow()` on task
  expiration so a later window can resume (tests:
  `BackgroundHistorySyncTests`).
- **Silent push (phase 2, hourly server cadence):** the push handler arms
  connects with source `background_push`. `registerForRemoteNotifications`
  runs unconditionally at launch — silent pushes need no notification
  permission, so token registration must not be gated on the permission
  prompt. Push receipts are tracked (`BackgroundTaskTracker.
  recordPushReceived`, visible in Settings → Task Scheduling debug) to
  verify the server cadence reaches the device.

## Connection-window budget: setup must not eat the link

A FlowerCare on a weak link (RSSI < -80 dBm, tired coin cell) holds a
connection only a few seconds. Everything between `didConnect` and the first
history entry is subtracted from that window, so setup cost is a reliability
parameter, not a detail.

- **The auth challenge never gets an answer.** FlowerCare 3.3.6 exposes the
  auth characteristic but only *acks the write*; a response could only arrive
  as a notification, and nothing in the stack subscribes to notifications
  (`setNotifyValue` does not exist on the `BLEPeripheralLink` seam) or reads
  that characteristic. `handleAuthenticationResponse` is unreachable on this
  firmware — every connect ends in the "proceed without auth" branch.
- **Cost of waiting for it:** the 4 s auth timeout used to run on EVERY
  connect, pushing the first entry request to ~4.9 s after connect. On a
  sensor whose link dies at ~5 s that means **zero entries per reconnect** —
  the entry index freezes and after 5 stalled drops the `DisconnectLoopGuard`
  aborts the sync ("stuck at entry N").
- **Now:** the confirmed auth write starts a short grace period
  (`DeviceConnection.authGracePeriod`, 0.4 s — a real notification arrives
  within one or two connection intervals). The 4 s timeout remains only for
  sensors that never ack at all. First entry request: ~1.3 s after connect.
- **Regression tests:** `HistoryResumeWindowTests` pins both halves — the
  setup budget (first entry ≤ 1.5 s after connect with a silent auth
  characteristic) and the end-to-end case (a 300-entry sync completes while
  the sensor drops the link every 5 s). Note that
  `FakeFlowerCarePeripheral.hasAuthCharacteristic` defaults to `false`, so
  tests that do not set it never exercise the auth path at all.

## Per-entry retry/skip (DeviceConnection)

- **Response timeout: 2 s per entry.** A silent sensor no longer freezes the
  sync until the global 10-minute timeout.
- **Retries: ≤ 2 per entry**, then the entry is skipped. "No response" and
  "garbage frame" (decode failure) share the same counters.
- **Skip budget: `max(20, totalEntries / 20)`.** Exceeding it aborts with
  `.tooManyCorruptEntries` — a sensor that only produces garbage doesn't
  burn battery for minutes.
- `lastSyncSkippedEntries` survives the flow cleanup for benchmark/UI.

## Resume semantics: suspend vs. cleanup

- `suspendHistoryFlow()` — cancels scheduled work but **keeps**
  `totalEntries`/`currentEntryIndex`. Used by every mid-flow disconnect
  path, so a stray task firing around a disconnect can never zero the
  resume state. After reconnect the sync continues at the exact index
  (verified: no entry below the resume point is re-fetched).
- `cleanupHistoryFlow()` — full reset. Only for: completion, user cancel,
  global 10-minute timeout, metadata timeout, loop-guard trip, final
  connection failure.

## Incremental history (stop boundary)

The sensor serves history newest-first (index 0 = newest, one entry per
hour — verified on recording `522a3a0d_20260612-160740`). Background paths
set `DeviceConnection.setHistoryStopBoundary(_:)` to the newest stored
`history` entry; the flow ends at the first entry at or before it
(tolerance 600 s, device-clock drift) and posts
`HistoricalDataLoadingCompleted`.

The boundary applies to one flow. `cleanupHistoryFlow()` clears it,
`suspendHistoryFlow()` keeps it for the resume. A path that set a
boundary but ends without a flow to resume (timeout, `.error`, flow never
started) clears it itself: `BackgroundHistorySyncService` in
`finishCurrentDevice`, `BackgroundBLEWakeService` in `finishRead`. The
details screen also clears it before every start it owns ("load history",
auto-start on a connection without an active flow), so a foreground sync
is always full.

- `BackgroundHistorySyncService` (BGProcessing): incremental. Sets the
  boundary only if the connection has no active flow — a suspended flow
  (its own expired window, or a user's full sync) keeps its boundary;
  loading the newest stored date again would end the resume at the
  entries it just saved.
- `BackgroundBLEWakeService`: after a saved live sample, fetches the new
  entries inside the same 9 s wake budget. No stored history → skipped.
  Disconnect/timeout in this phase, and a timeout while the sample is
  being saved, still count as `.saved`.
- Details screen "load history": full sync, fills gaps older than the
  newest stored entry.
- Accepted gap: an interrupted incremental sync (wake read timeout or
  disconnect after saving some entries) moves the newest stored entry,
  and with it the next boundary, past the entries it did not reach. Those
  older entries are only filled by the next foreground full sync.

The details screen shares its pool connection with background reads and
only acts on what it started:

- Live reads: `LiveReadGate` — it requests and saves only a sample it
  claimed. On `didEnterBackgroundNotification` the claim is released
  (`release()`), so a wake read armed on entering background is not
  mistaken for the screen's read within the 60 s claim lifetime.
- History: `ownsHistoryFlow` — set by "load history" and the screen's
  auto-start, cleared by its completion handler and on cancel. Entries,
  progress/Live Activity and completion ("history loaded this session")
  are handled only while it is set. On entering background it stays set
  only if the flow is already active (a running user sync continues with
  auto-reconnect; `armBackgroundConnect` skips that connection).

Background samples and history entries are therefore neither re-requested
nor saved a second time by the screen.

- If the history flow can't start at all (e.g. the sensor drops the link
  during the save), the wake read finishes as `.saved` immediately and
  clears the boundary; `finishRead` always clears a boundary the read set,
  so a foreground full sync never inherits it.
- The pool re-checks `connection.shouldAutoReconnect` before an
  auto-reconnect connects: in `attemptFastReconnect`, and — when the fast
  attempts fell back to scanning — again on discovery (explicit
  `connect(to:)` scans are not affected). A reconnect scheduled for a flow
  that was cleaned up in the meantime (wake read ended) is skipped.
- An empty sensor history also posts `HistoricalDataLoadingCompleted`.

## Record & replay (beta-tester problem reports)

1. Tester enables **Record BLE Sessions** in the debug menu
   (`LogExportView`), reproduces the problem, shares the
   `*.ble-session.json` via the share sheet. Recording captures raw
   transport traffic (timestamps, characteristic UUIDs, hex payloads,
   error codes) — no personal data. Files flush to disk on every
   disconnect, on app-background, and when the toggle turns off.
2. Drop the file into `GrowGuardTests/BLE/Recordings/` (bundled
   automatically via folder reference).
3. Add one entry to `ReplayFixtures.all` in `ReplaySessionTests.swift`
   with the expected outcome (entry count / completion / error).

The generic runner replays the session in virtual time against the real
pool stack and fails with a readable diff if the app's outbound traffic
diverges from the recording.

## Performance budgets (`BLEPerformanceTests`)

Budgets derive from the protocol's own constants — never wall clock:
inter-entry delay 0.02 s, batch pause 0.05 s per 150 entries, fake response
delay 0.01 s. The tests assert exact traffic counts (no re-fetch loops),
a virtual-time ceiling (catches delay inflation), and recovery cost
(2 mid-sync disconnects → exactly 2 reconnects, zero re-fetches below the
resume point). If you intentionally change a protocol delay, update the
cost model comment in `BLEPerformanceTests.swift`.

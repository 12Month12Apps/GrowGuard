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

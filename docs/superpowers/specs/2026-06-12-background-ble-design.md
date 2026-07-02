# Background BLE Data Collection — Design

Date: 2026-06-12
Status: Draft, pending user review

## Problem

GrowGuard needs to (1) notify the user promptly when a plant is dry and
(2) collect dense sensor data for charts — while the app is not in the
foreground. Four mechanisms exist today (BGAppRefreshTask,
BGProcessingTask, silent push, bluetooth-central + state restoration),
and none works reliably.

Root cause: the first three triggers all try to complete an entire BLE
session (connect → discover → auth → read) inside a ~30-second system
window, racing self-imposed budgets (8 s/device, 25 s overall, 10 s
connect watchdog, 3-retry sticky error). The fourth mechanism — the one
that could make this reliable — is configured but functionally dead:
no code path ever leaves a pending connection alive for iOS to wake the
app on.

Two facts reframe the problem:

- The FlowerCare sensor logs hourly into on-device history regardless of
  the app, and history sync already exists. Chart density therefore does
  not require frequent background wakes — it requires history sync to
  succeed regularly.
- `CBCentralManager.connect()` has no timeout by OS design. A pending
  connect survives app suspension (and, with the already-configured
  state restoration, system termination). When the sensor is seen
  advertising, iOS connects and wakes the app with ~10 s of runtime —
  enough for auth (≤4 s) + live read.

## Priorities (user-confirmed)

1. Timely "plant is dry / needs water" notifications.
2. As much chart data as possible.

## Design: arm, don't fetch

Invert the architecture: background triggers stop trying to *complete*
a fetch and instead *arm* pending connects. The BLE wake performs the
actual read.

### Components

**1. `ConnectionPoolManager.armBackgroundConnect(deviceUUID)` (new)**

`retrievePeripherals(withIdentifiers:)` + `connect()` with:

- no connect watchdog (the pending connect IS the mechanism),
- no retry budget / sticky-error participation,
- no scan fallback (a scan in background is slow and unnecessary —
  the known-identifier connect completes whenever the sensor is in
  range),
- live-only session (`autoStartHistoryFlow: false`).

Re-arming an already-pending peripheral is idempotent (CoreBluetooth
treats repeat `connect()` as a no-op). Foreground paths keep today's
watchdog/retry/scan behavior unchanged.

**2. Triggers become cheap (~1 s) and only arm**

- `BGAppRefreshTask` handler: arm connects for all sensor devices,
  reschedule next task, `setTaskCompleted` immediately. (Fast handlers
  also improve the scheduler's willingness to grant future windows.)
- Silent push handler: same as above.
- `applicationDidEnterBackground`: arm connects — yields one
  near-guaranteed fresh sample shortly after the user leaves the app.
- `BGProcessingTask`: the exception. It gets minutes of runtime, so it
  runs **history sync** (connect → auth → history flow). The history
  flow already supports suspend/resume at an entry index
  (`suspendHistoryFlow`), so the expiration handler suspends cleanly
  and the next processing window resumes.

**3. Background wake handler (new service, replaces most of
`BackgroundSensorDataService`)**

On `didConnect` while the app is in background (including wakes via
state restoration):

1. `UIApplication.beginBackgroundTask` to protect the read,
2. auth + live read (existing `DeviceConnection` flow),
3. `PlantMonitorService.validateSensorData` to save,
4. run `PlantMonitorService.checkDeviceStatus(device:)` for that device
   immediately (not only the daily check) so a dry plant notifies on
   this sample,
5. disconnect, end background task.

The wake handler never re-arms. The sensor advertises continuously in
range, so re-arming after a read would reconnect instantly and create a
wake loop. Arming comes exclusively from time-based triggers; cadence =
trigger cadence, with near-100 % capture per granted trigger.

**4. Phase 2 (optional): server-driven cadence**

The existing GrowGuard server sends a silent push every 1–2 hours; the
handler arms connects. This is the only legitimate lever to raise wake
cadence beyond BGTaskScheduler grants. Phase 1 is fully functional
without the server.

### Error handling

- **Sensor out of range:** pending connect stays pending; no retries
  burned, no sticky error. Next trigger re-arms idempotently.
- **Bluetooth off:** arm requests queue via the existing
  `pendingConnections` path and re-issue on `poweredOn`.
- **`validateSensorData` returns nil:** treated as "device done, no
  data" instead of dangling until a timeout (fixes an existing gap).
- **Force-quit / reboot:** iOS does not relaunch force-quit apps for
  BLE events, and pending connects do not survive reboot. Accepted
  platform limitation; next app open re-arms and history sync backfills
  charts.

### What gets removed/simplified

- `BackgroundSensorDataService`'s continuation/timeout machinery
  (8 s per-device, 25 s overall budgets) and the
  OperationQueue/DispatchGroup wrappers in `AppDelegate` task handlers
  (replace with plain `Task` + expiration handler).
- The legacy `fetch` entry in `UIBackgroundModes` (unused;
  `setMinimumBackgroundFetchInterval` is never called).

### Testing

Built on the existing transport seam (`FakeBLETransport`) and
virtual-time scheduler:

- arm → trigger window "ends" → connect completes later → sample saved
  → `checkDeviceStatus` ran,
- background-armed connects bypass watchdog/retry/sticky-error,
- foreground connects keep watchdog/retry (regression),
- history sync suspends on BGProcessing expiration and resumes at the
  same index next window,
- wake handler does not re-arm after a successful read.

### Expectations (explicit)

- Phase 1: roughly 2–6 reliable samples/day for notification checks
  (BGTask grants + enter-background arm + occasional silent pushes).
- Phase 2: notification latency bounded by push cadence (~1–2 h worst
  case).
- Charts: complete hourly data via history sync, independent of wake
  cadence.
- iOS will never permit minute-level continuous background sampling for
  a non-accessory app; this design does not attempt to evade that.

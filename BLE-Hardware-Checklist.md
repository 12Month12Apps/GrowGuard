# BLE Hardware Release Checklist

Run this against a **real FlowerCare sensor** before every release candidate.
The automated suites prove the logic (see [BLE-Reliability.md](BLE-Reliability.md));
only this proves radio + iOS/macOS reality.

## 0. Automated hardware suite (run first)

```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard \
  -testPlan HardwareTests \
  -destination 'platform=iOS,name=<your iPhone>' \
  TEST_FLOWERCARE_UUID=<peripheral-uuid> \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180
```

The peripheral UUID is per-device (find it in the app's log export after one
connection: "Connecting to known device: …"). On a Mac with Bluetooth, the
`-destination 'id=<mac-device-id>'` form works too. Quit the GrowGuard app
first — two BLE clients fight over the sensor.

## 1. Connection & data (each release)

| # | Check | Pass criteria |
|---|---|---|
| 1.1 | Pair a NEW sensor via Add Device | Sensor found, added, appears in overview |
| 1.2 | LED blink | Sensor LED flashes |
| 1.3 | Live data refresh | Fresh values within ~10 s; plausible temp/moisture/lux |
| 1.4 | Full history sync (sensor with > 50 entries) | Progress UI runs to 100 %, entry count matches, no loop |
| 1.5 | Incremental sync (run 1.4 again) | Only new entries fetched ("incremental sync from index" in log) |
| 1.6 | History on idle-dropped connection | Open details, wait > 10 s (sensor drops link), THEN tap Load Historical Data → reconnects and completes |
| 1.7 | Sub-zero temperature (sensor in freezer 10 min) | Negative °C shown, not 100 °C, history entries not dropped |

## 2. Radio reality (each release)

| # | Check | Pass criteria |
|---|---|---|
| 2.1 | Walk out of range mid-sync, return after ~30 s | Sync resumes at same entry, completes, no duplicates |
| 2.2 | Sensor at 8–10 m / through a wall | Connects (slower OK), sync completes |
| 2.3 | Repeated instant disconnects (hold sensor in metal box) | Loop guard trips after ≤5 no-progress drops with "Disconnect loop detected" in log — NO endless reconnect loop |
| 2.4 | Two sensors syncing in parallel | Both complete; data lands on the right plants |
| 2.5 | Out-of-range + return mid-sync | Resumes at the exact entry index ("Resuming history flow at entry" in log), no restart from 0 |
| 2.6 | Sensor powered off mid-sync (pull battery) | Bounded failure after retry budget; no reconnect storm in logs |

## 3. OS lifecycle (each release)

| # | Check | Pass criteria |
|---|---|---|
| 3.1 | Background the app mid-sync | Sync continues or resumes on foreground |
| 3.2 | Force-kill mid-sync, relaunch | State restoration reconnects; no crash; sync restartable |
| 3.3 | Bluetooth off → on mid-operation | Queued connect fires when BT returns |
| 3.4 | Siri intent fetch | Live values returned |
| 3.5 | Background task fetch | Completes within ~25 s budget (check log timestamps) |
| 3.6 | Widget update after sync | Widget shows fresh values |

## 4. Trace capture (once per release)

1. Install Apple's Bluetooth diagnostic profile (iOS) or use PacketLogger (macOS).
2. Record one full history sync.
3. Archive the trace next to the release tag — it's the baseline for diffing
   when beta users report BLE issues (compare against their LogExportView export).

## 5. Record & replay (once per release)

| # | Check | Pass criteria |
|---|---|---|
| 5.1 | Enable "Record BLE Sessions" in the debug menu, run a full sync | Recording file appears in the list with plausible size |
| 5.2 | Share the recording via the share sheet | Valid `*.ble-session.json` arrives (AirDrop/Mail) |
| 5.3 | Drop the file into `GrowGuardTests/BLE/Recordings/` + register in `ReplayFixtures.all` | Replay test passes against the recording |
| 5.4 | Disable the toggle | No new files are created on subsequent syncs |

## Verified runs

| Date | Build/Branch | Platform | Scope | Result |
|---|---|---|---|---|
| 2026-06-12 | ble-phase3-transport-seams | macOS (Designed for iPad) | 1.3, 1.4, 1.6 | ✅ live read works; 84-entry sync completes incl. reconnect after idle-drop |
| 2026-06-12 | ble-phase3-transport-seams | macOS (Designed for iPad) | 0 (automated suite) | ✅ all 5 tests passed across runs (89-entry syncs at ~1.6 entries/s; two mid-sync sensor disconnects auto-recovered with resume). ⚠️ Sensor battery at 0 % caused stalls in later runs — replace the CR2032 before relying on suite timing |

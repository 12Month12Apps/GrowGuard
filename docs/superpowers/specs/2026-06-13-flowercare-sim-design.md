# FlowerCareSim — macOS Sensor Simulator

**Date:** 2026-06-13
**Status:** Approved, implementing

## Problem

GrowGuard talks to a Xiaomi/HHCC **FlowerCare** plant sensor over BLE. Testing
the app's BLE stack on the go (away from physical hardware) requires a stand-in
that *acts as the sensor*. We want a macOS app that advertises and behaves like a
FlowerCare so a real iPhone running GrowGuard can connect to it and:

1. **Replay** a recorded `*.ble-session.json` session (the core need).
2. Serve a **live, editable** sensor (sliders for moisture/temp/light/EC/battery
   + a synthetic history buffer) for hand-crafted scenarios.
3. **Inject faults** that exercise the app's reliability code.

## Protocol facts (verified against the app)

- App scans (both `AddDeviceBLE` and `ConnectionPoolManager`) with a service
  filter of `[flowerCareServiceUUID]` = `0000fe95-…`. The sim must advertise
  `fe95`, even though the real data lives in services `1204` + `1206`.
- GATT the app discovers and uses:
  - Service `00001204-…` (data): `1a00` write, `1a01` realtime read/notify,
    `1a02` firmware read.
  - Service `00001206-…` (history): `1a10` history-control write, `1a11`
    history-data read, `1a12` device-time read.
- **Auth is optional.** `DeviceConnection.startAuthentication()` calls
  `completeAuthentication()` immediately when no auth characteristic
  (`00000001-…`) is present. The sim omits that characteristic → app proceeds
  straight to firmware read + history flow, matching the recordings.
- History flow (`DeviceConnection+HistoryFlow.swift`) is **request/response with
  uniquely-keyed requests**:
  1. write `a00000` to `1a10` (enter history mode), read `1a12` (device time),
  2. write `3c` to `1a10` (entry-count command), read `1a11` → metadata frame
     whose first 2 bytes are the entry count, little-endian,
  3. per entry `i`: write `a1` + 2-byte LE index to `1a10`, read `1a11` → entry
     frame.
- Per-entry response timeout is 2 s, ≤2 retries then skip (skip budget
  `max(20, total/20)`); see `BLE-Reliability.md`.

## Architecture

Three layers plus shared models.

```
SwiftUI app (FlowerCareSim target)
  mode picker · traffic log · per-mode controls
        │ drives
SensorBrain (protocol, CoreBluetooth-free, unit-tested)
  answer(read: CBUUID) -> ReadOutcome
  answer(write: CBUUID, payload: Data) -> WriteOutcome
  ├─ ReplayBrain  — request→response map built from a recording
  ├─ LiveBrain    — editable state + synthetic history, encodes frames
  └─ FaultBrain   — decorator over any brain
        │ used by
SimulatedPeripheral
  wraps CBPeripheralManager; builds GATT 1204+1206; advertises fe95
  routes didReceiveRead/didReceiveWrite → brain; emits TrafficEvent

Shared files (added to BOTH GrowGuard app and FlowerCareSim targets):
  UUIDs.swift · BLESessionRecording.swift
  SensorDataDecoder.swift · HistoricalSensorData.swift
```

### SimulatedPeripheral

Owns `CBPeripheralManager`. On `.poweredOn`:

- Builds the GATT database: service `1204` (`1a00` write, `1a01` read+notify,
  `1a02` read) and service `1206` (`1a10` write, `1a11` read, `1a12` read). No
  auth characteristic.
- Starts advertising `CBAdvertisementDataServiceUUIDsKey: [fe95]`,
  `CBAdvertisementDataLocalNameKey: "Flower care"`.
- `didReceiveRead` → `brain.answer(read:)`; respond `.success` with bytes, or an
  error result for fault cases.
- `didReceiveWrite` → `brain.answer(write:payload:)`; respond with the request
  result, then push any follow-up value (e.g. the `1a11` frame) so the app's
  subsequent read resolves.
- Every request emits a `TrafficEvent { t, direction, char, hex, note }` to the
  UI log.

`removeAllServices()` + `stopAdvertising()` is the **go-dark** action used for
approximated disconnect/reconnect (the central hits supervision timeout after a
few seconds — `CBPeripheralManager` has no force-disconnect API).

### SensorBrain implementations

- **ReplayBrain** — Indexes a `BLESessionRecording` once at load:
  - read responses → per-characteristic FIFO queues keyed by UUID (the ordered
    `valueUpdated` payloads for that char),
  - write responses → `(char, payloadHex) → following 1a11 frame`.
  Resolves request-driven lookups. Unknown request → returns an error/empty
  result and logs a "no scripted response (protocol drift)" warning.
- **LiveBrain** — Editable state: moisture %, temperature (×10 °C), light lux,
  conductivity µS/cm, battery %, firmware string, synthetic history buffer of N
  entries. Encodes frames on demand via `FlowerCareFrameEncoder` (the inverse of
  `SensorDataDecoder`; `GrowGuardTests/BLE/FlowerCareFrameFixtures.swift` is the
  byte-layout reference). Answers `a00000`/`3c`/`a1XXXX` against the buffer.
- **FaultBrain** — Decorator wrapping any brain. Per request it can: pass
  through, return garbage bytes, stay silent (no response → app's 2 s timeout),
  return an error result, or delay. Exposes the top-level go-dark action.

### UI

Mode picker (Replay / Live / Fault). Shared chrome always visible: power/
advertising state, connected-central indicator, and a scrolling **traffic log**
(timestamp · direction · char · hex · note) shaped like the recording's own
events.

- Replay: file picker for `*.ble-session.json` + parsed summary (firmware,
  entry count, event count).
- Live: sliders/fields for each sensor value + history buffer size + firmware.
- Fault: per-fault toggles (garbage / silent / error / slow) + "go dark" button.

## Data flow (replay), end to end

1. Pick a recording → `ReplayBrain` indexes it.
2. Sim advertises. GrowGuard's Add Device scan finds "Flower care"; user adds it
   (OS assigns a fresh peripheral identifier for this Mac↔phone pair — one-time).
3. App connects → discovers `1204`/`1206` → reads `1a02` → writes `a00000` →
   reads `1a12` → writes `3c` → reads `1a11` (metadata) → loops `a1XXXX` / read
   `1a11` per entry. Each step is a brain lookup; the traffic log shows it live;
   the app completes the sync.

## Error handling

- `CBPeripheralManager` not `.poweredOn` / unauthorized → status banner;
  advertising queued until power-on. Info.plist carries
  `NSBluetoothAlwaysUsageDescription`.
- Brain cannot answer → error result + prominent log warning (surfaces drift
  rather than failing silently).
- Malformed recording → readable load error; advertising does not start.

## Testing

- **Unit (TDD core, no hardware):**
  - `ReplayBrain` indexing — against the bundled
    `history-5-entries-clean__synthetic__20260612.ble-session.json`: firmware
    read resolves, `a00000`/`3c` confirm, metadata frame = 5 entries, each
    `a1XXXX → 1a11` mapping resolves to the right frame.
  - `FlowerCareFrameEncoder` round-trips through `SensorDataDecoder`.
- **Manual (hardware checklist):** real iPhone + this Mac, one end-to-end replay
  of each bundled recording while watching the traffic log and GrowGuard's sync.

## Project wiring

- New `FlowerCareSim` macOS app target + `FlowerCareSimTests` unit-test target
  in the existing `GrowGuard.xcodeproj` (added via the `xcodeproj` Ruby gem to
  keep the hand-maintained pbxproj valid).
- **Shared files added to the sim target (no copies):** `UUIDs.swift` and
  `BLESessionRecording.swift` only. `SensorDataDecoder.swift` was *not* shared
  into the sim: it references the app's SwiftData-backed `SensorDataTemp`, which
  would cascade the entire database layer into the simulator. The sim never
  decodes (it only serves/encodes), so it doesn't need it. The encoder is
  verified against golden wire-format bytes — bytes that were confirmed to
  decode correctly through the real `SensorDataDecoder` during development.
- The synthetic recording fixture is copied into `FlowerCareSimTests/Recordings/`
  (the app's recordings are bundled as a folder reference, so a single file
  can't be cherry-picked from it as a test resource).
- Both targets build; the 6 brain/encoder unit tests pass under `xcodebuild
  test -scheme FlowerCareSim`.

## Out of scope (YAGNI)

- Recording on the sim side (recording already lives in GrowGuard).
- Instant mid-sync link drops (CoreBluetooth peripheral limitation; go-dark
  approximation is sufficient).
- Multi-sensor / simultaneous central simulation.

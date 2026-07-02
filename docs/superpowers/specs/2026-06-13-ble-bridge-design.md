# BLE Bridge — single-machine GrowGuard ↔ FlowerCareSim

**Date:** 2026-06-13
**Status:** Approved, implementing
**Builds on:** `2026-06-13-flowercare-sim-design.md`

## Problem

FlowerCareSim talks to GrowGuard over real Bluetooth, which needs two radios —
i.e. two physical devices (Mac + iPhone). A single Mac has one Bluetooth
controller, and a controller cannot hear its own advertisements, so GrowGuard
running on the *same* Mac (Simulator, Designed-for-iPad, or native) can never
discover FlowerCareSim. The iOS Simulator has no CoreBluetooth at all.

We want a **single-machine** workflow: GrowGuard in the iOS Simulator (or on the
Mac) connecting to FlowerCareSim on the same Mac, exercising the real connection
and history-sync logic — without a radio.

## Approach

A **debug-only, opt-in alternate transport.** GrowGuard's BLE stack already
talks to a protocol seam (`BLECentral` / `BLEPeripheralLink`, see
`BLETransport.swift`) rather than CoreBluetooth directly. We add a bridge
implementation of that seam that forwards over a localhost TCP socket to
FlowerCareSim. Everything above the seam —`ConnectionPoolManager`,
`DeviceConnection`, history flow, `ReconnectPolicy`, retry/skip,
reconnect/resume — runs unchanged and for real. Only the transport leaf is
swapped, and only when an env var is set (never in release).

The real BLE path (`CoreBluetoothTransport`, `SimulatedPeripheral`) is untouched.

## Architecture

```
── GrowGuard (iOS Simulator or Mac) ──────────┐     ┌── FlowerCareSim (Mac) ──
ConnectionPoolManager ─ BLECentral seam ──┐   │     │
AddDeviceViewModel ─ DeviceDiscovery seam ┤   │ TCP │  BridgeServer (NWListener)
                                          ├───┼─────┼─►  drives the SAME
BridgeBLECentral / BridgeBLEPeripheralLink│   │:8765│     SensorBrain (replay/
BridgeDeviceDiscovery     (all #if DEBUG) ┘   │     │     live/fault) + GATT
                                              │     │     emits TrafficEvents
──────────────────────────────────────────── ┘     └─────────────────────────
```

`BridgeServer` is a **second front-end to the same brains** that
`SimulatedPeripheral` already wraps — no brain logic is duplicated. Both the
socket path and the radio path share `ReplayBrain`/`LiveBrain`/`FaultBrain` and
log to the same traffic view.

## Wire protocol

Newline-delimited JSON over TCP on `127.0.0.1` (the iOS Simulator reaches the
host Mac via localhost; a real phone cannot — acceptable, the bridge is the
single-machine tool). One central per server. No TLS/auth (localhost dev tool).

A pure `BridgeMessage` enum + `BridgeCodec` (encode/decode) is the unit-tested
core. Messages mirror the seam vocabulary:

- **Central → Sim (requests):** `scan`, `stopScan`, `connect(id)`,
  `cancel(id)`, `discoverServices(id)`, `discoverChars(id, service)`,
  `read(id, char)`, `write(id, char, dataHex, withResponse)`, `readRSSI(id)`.
- **Sim → Central (events):** `state(value)`, `discovered(id, name, services,
  rssi)`, `connected(id)`, `disconnected(id, error?)`,
  `servicesDiscovered(id, services)`, `charsDiscovered(id, service, chars)`,
  `valueUpdated(id, char, dataHex, error?)`, `writeConfirmed(id, char, error?)`,
  `rssi(id, value)`.

`error?` carries domain/code so the bridge can reproduce CoreBluetooth-style
failures (e.g. for the silent/error faults).

## Components

### GrowGuard side (all `#if DEBUG`)

- **`BLEBridgeConfig`** — reads `GROWGUARD_BLE_BRIDGE` (e.g. `127.0.0.1:8765`)
  once at launch. `isEnabled` + `host`/`port`. Unset ⇒ everything uses the real
  transport, zero behaviour change.
- **`BridgeConnection`** — owns the `NWConnection`, framing (split on `\n`),
  send/receive of `BridgeMessage`. Shared by the central and discovery clients
  (single socket).
- **`BridgeBLECentral` : `BLECentral`** — forwards `connect`/`cancel`/`scan`/
  `stopScan`; routes inbound events to `centralDelegate`. `retrievePeripherals(
  withIdentifiers:)` synthesises a `BridgeBLEPeripheralLink` immediately (the
  sim is one known sensor) so connecting a saved device needs no scan.
- **`BridgeBLEPeripheralLink` : `BLEPeripheralLink`** — forwards
  `discoverServices`/`discoverCharacteristics`/`read`/`write`/`readRSSI`;
  receives events via the central and calls `linkDelegate`. Tracks `state`.
- **`BridgeDeviceDiscovery` : `DeviceDiscovery`** — the bridge implementation of
  the new discovery seam; sends `scan`, surfaces `discovered` as
  `DiscoveredDevice`.

Injection: `ConnectionPoolManager.init`'s `else` branch picks `BridgeBLECentral`
when `BLEBridgeConfig.isEnabled`, else the existing
`RecordingBLECentral(CoreBluetoothCentral(...))`. `AddDeviceViewModel` picks
`BridgeDeviceDiscovery` vs the real one likewise.

### Add Device refactor (production code)

Introduce `struct DiscoveredDevice { let id: UUID; let name: String? }` and:

```swift
protocol DeviceDiscovery {
    var onState: ((CBManagerState) -> Void)? { get set }
    var onFound: ((DiscoveredDevice) -> Void)? { get set }
    func start()
    func stop()
}
```

`CoreBluetoothDeviceDiscovery` wraps today's `AddDeviceBLE`. Migrate
`AddDeviceViewModel.devices` (`[CBPeripheral]` → `[DiscoveredDevice]`),
`AddDeviceView`'s row, and `AddDeviceDetails`'s navigation case + init + save
from `CBPeripheral` to `DiscoveredDevice` (they only use `.identifier`/`.name`).
This removes CoreBluetooth from the add-device view layer, matching the existing
seam philosophy. It is the only change to a production path — covered by the
existing onboarding behaviour plus a manual smoke test on the real path.

### FlowerCareSim side

- **`BridgeServer`** — `NWListener` on the configured port. Accepts one
  connection, decodes requests, and answers using the sim's fixed peripheral
  identity (constant UUID, name "Flower care") + known GATT (services
  `1204`/`1206` and their characteristics) + the active `SensorBrain`. Reuses
  `brain.read/write`; emits `TrafficEvent`s to the existing log. `scan` →
  `discovered`; `connect` → `connected`; `discoverServices/Chars` → the static
  GATT; `read/write` → brain outcomes mapped to `valueUpdated`/`writeConfirmed`
  (including `.error`/`.silent`).
- **UI** — a Bridge section in `ContentView`: enable/disable, port field,
  listening + connected-client status. Bridge and radio can both be on; both
  share the active brain and traffic log.

## Data flow (add + sync over the bridge)

1. Run GrowGuard in the iOS Simulator with env
   `GROWGUARD_BLE_BRIDGE=127.0.0.1:8765`; FlowerCareSim running, Bridge enabled.
2. Add Device → `BridgeDeviceDiscovery` sends `scan`; sim replies `discovered`
   ("Flower care", fixed UUID) → appears in the list → add & save (fixed UUID).
3. Connect → `BridgeBLECentral` connects + discovers + reads/writes over the
   socket → sim drives the active brain → full history sync, identical to BLE.

## Error handling

- Socket not reachable (sim not running / wrong port) → `BridgeBLECentral`
  reports `state(.poweredOff)`; the app shows its normal "Bluetooth
  unavailable" path. Reconnect attempts retry the socket.
- Connection drop mid-sync → `disconnected` event → existing reconnect/resume.
- Sim "go dark" over the bridge → emit `disconnected`; the bridge supports an
  instant drop here (unlike the radio's supervision-timeout approximation), so
  it's actually a *better* mid-sync-drop test on one machine.
- Malformed message → logged and dropped; never crashes either side.

## Testing

- **Unit (pure):**
  - `BridgeCodec` round-trips every request and event message
    (GrowGuard tests + `FlowerCareSimTests`).
  - `BridgeBLECentral`/`BridgeBLEPeripheralLink` drive the correct
    `BLECentralDelegate`/`BLEPeripheralLinkDelegate` callbacks given a fake
    `BridgeConnection`.
  - `BridgeServer` request handling against a brain returns the expected events.
- **Manual:** GrowGuard in the iOS Simulator + FlowerCareSim on the same Mac →
  add the simulated device, replay a bundled recording (sync completes with the
  expected entry count), switch to Live and confirm value changes, inject a
  fault and confirm retry/skip. Plus one smoke test of the *real* Add Device
  flow on hardware to confirm the `DiscoveredDevice` refactor didn't regress it.

## Out of scope (YAGNI)

- Multiple simultaneous centrals on one bridge server.
- TLS / authentication on the socket.
- Any release-build behaviour: the GrowGuard bridge is entirely `#if DEBUG`, and
  inert unless `GROWGUARD_BLE_BRIDGE` is set.
- Bridging over a real network to another machine (localhost only).

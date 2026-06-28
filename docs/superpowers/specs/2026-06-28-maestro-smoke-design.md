# Maestro smoke + bridge-E2E layer

**Date:** 2026-06-28
**Status:** Approved, implementing
**Builds on:** `2026-06-13-ble-bridge-design.md`, `2026-06-13-flowercare-sim-design.md`

## Problem

GrowGuard has XCUITest navigation coverage ([NavigationUITests.swift](../../../GrowGuardUITests/NavigationUITests.swift))
but no fast, Xcode-free smoke layer that can run the main user flows quickly and
serve as the foundation for a later AI-driven exploratory layer (Maestro MCP +
agent). We want to stand up Maestro for the normal flows, anchored on stable
selectors, reusing the launch seams the app already exposes.

## Goal & non-goals

**Goal:** A Maestro flow suite that smoke-tests the normal flows on the iOS
Simulator, plus a bridge-backed E2E flow that exercises the add-sensor path
deterministically via FlowerCareSim. Maestro becomes the fast smoke layer
alongside (not replacing) the existing XCUITests.

**Non-goals (YAGNI):**
- Real-Bluetooth scanning on the Simulator — impossible (no radio).
- Real-hardware E2E (physical iPhone + real FlowerCare) — Maestro is iOS
  **simulator-only** (official real-device support not yet shipped). This stays
  in XCUITest via [HardwareTests.xctestplan](../../../HardwareTests.xctestplan).
- CI wiring and the AI exploratory layer — deferred to later iterations.
- Destructive / side-effecting settings actions (delete all data, push-token
  re-register) — excluded from smoke for safety, not capability.

## Tier model

Everything testable, split by environment:

| Tier | Coverage | Environment | Tool |
|------|----------|-------------|------|
| **A — Smoke** | 4 happy-path flows, seeded device | Simulator, no BLE | Maestro (this work) |
| **B — Bridge-E2E** | + add-sensor, live sensor data, deterministic | Simulator + FlowerCareSim | Maestro (this work) |
| **C — Real hardware** | real CoreBluetooth stack + real sensor | physical iPhone | XCUITest / HardwareTests (out of scope) |

## Approach

A new `.maestro/` directory at the repo root. Flows are anchored on the app's
existing **accessibility identifiers** rather than localized text, so they are
language-independent and robust. Each flow launches via a shared subflow that
reuses the launch seams the XCUITests already prove work.

```
.maestro/
  config.yaml                       # appId, tags
  subflows/launch.yaml              # shared launch (param: seed on/off)
  flows/00_launch_tabs.yaml         # ┐
  flows/10_overview_detail.yaml     # ├ Tier A — tag: smoke
  flows/20_add_manual.yaml          # │
  flows/30_settings.yaml            # ┘
  flows/40_add_sensor_bridge.yaml   #   Tier B — tag: bridge
  README.md
```

### Existing accessibility identifiers (anchors)

| ID | Location |
|----|----------|
| `overviewScreen` | [OverviewList.swift:147](../../../GrowGuard/OverviewList/OverviewList.swift) |
| `deviceCard-<uuid>` | [OverviewList.swift:430](../../../GrowGuard/OverviewList/OverviewList.swift) — seeded device: `deviceCard-UITEST-DEVICE-0001` |
| `deviceDetailScreen` | [DeviceDetailsView.swift:508](../../../GrowGuard/DeviceDetails/DeviceDetailsView.swift) |
| `addDeviceScreen` | [AddDeviceView.swift:130](../../../GrowGuard/AddDevice/AddDeviceView.swift) |
| `addManuallyCard` | [AddDeviceView.swift:55](../../../GrowGuard/AddDevice/AddDeviceView.swift) |
| `addFlowerScreen` | [AddWithoutSensor.swift:61](../../../GrowGuard/AddDevice/WithoutSensor/AddWithoutSensor.swift) |

### New accessibility identifiers (to add)

Targeted, testability-improving edits:
- Settings screen root (AppSettingsView)
- The three tab-bar items (Overview / Add / Settings) in [ContentView.swift](../../../GrowGuard/ContentView.swift)
- History screen (HistoryListView, reached from device detail)

### Launch seams reused

From [NavigationUITests.swift](../../../GrowGuardUITests/NavigationUITests.swift):
- `-veit.pro.showOnboarding 1` — skip onboarding (UserDefaults argument domain)
- `-AppleLanguages (en)` / `-AppleLocale en_US` — deterministic English titles
- `-uiTestSeedDevice` — seed "UITest Plant" (`UITEST-DEVICE-0001`) without BLE
  ([AppDelegate.swift:433](../../../GrowGuard/AppDelegate.swift))

**Risk to verify empirically:** Maestro's iOS `launchApp.arguments` must actually
reach these seams — especially the bare flag `-uiTestSeedDevice` and the
array-style `-AppleLanguages (en)`. Maestro passes launch *arguments* (not env
vars). If a seam doesn't take, fall back to a small launch-arg / UserDefaults
read in the app following the existing convention. Confirm before relying on it.

## Tier A flows

- **`00_launch_tabs`** — launch (no seed) → assert `overviewScreen` → tap each
  tab, assert each tab's screen renders.
- **`10_overview_detail`** — launch (seeded) → `overviewScreen` → tap
  `deviceCard-UITEST-DEVICE-0001` → `deviceDetailScreen` → open the gear ⚙️
  settings sheet ([DeviceDetailsView.swift:525](../../../GrowGuard/DeviceDetails/DeviceDetailsView.swift)) →
  close → open History → back.
- **`20_add_manual`** — Add tab → `addDeviceScreen` → tap `addManuallyCard` →
  `addFlowerScreen` → back. (Sensor path excluded here — covered in Tier B.)
- **`30_settings`** — Settings tab → assert title/screen → scroll through the
  sections. No destructive/side-effect taps.

**Acceptance:** all four green on the booted iPhone 17 Pro simulator.

## Tier B flow (directly after A)

The bridge ([BLEBridgeConfig.swift](../../../GrowGuard/BLE/Bridge/BLEBridgeConfig.swift),
[ConnectionPoolManager.swift:123](../../../GrowGuard/BLE/ConnectionPoolManager.swift))
swaps CoreBluetooth for a socket to FlowerCareSim; everything above the transport
runs unchanged, so the add-sensor flow is deterministic on a plain simulator.

**Wrinkle:** the bridge is read from the `GROWGUARD_BLE_BRIDGE` **env var**, but
Maestro sets launch **arguments** on iOS, not env vars. Resolution: add a
DEBUG-only **launch-arg seam** to `BLEBridgeConfig` (e.g. read
`-GROWGUARD_BLE_BRIDGE host:port` from `ProcessInfo.arguments` / UserDefaults in
addition to the env var), so Maestro can enable the bridge. Alternative
considered: set the env via `simctl` before the Maestro run — rejected as more
fragile and less self-contained than the launch-arg seam.

- **`40_add_sensor_bridge`** (tag `bridge`) — launch with the bridge pointing at
  FlowerCareSim → Add tab → simulated sensor appears in the available-sensors
  list → tap → complete add → device appears in Overview.
- Requires `~/Dev/FlowerCareSim` running; documented in the README.

**Acceptance:** green with FlowerCareSim running.

## Running

- Tier A (no external deps): `maestro test .maestro/flows --exclude-tags=bridge`
- Tier B: start FlowerCareSim, then `maestro test .maestro/flows --include-tags=bridge`

README documents installation (Maestro CLI + JDK) and both run modes.

## Testing

Acceptance is the flows themselves running green:
- Tier A: 4 flows on the booted simulator.
- Tier B: the bridge flow with FlowerCareSim running.

No additional unit tests; the deliverable is the executable flow suite plus the
small app-side accessibility-identifier and bridge launch-arg additions.

# Link Quality Assistant — live placement feedback during history sync

**Date:** 2026-09-09
**Status:** Approved, not yet implemented
**Related:** `BLE-Reliability.md` (connection-window budget), `2026-06-12-background-ble-design.md`

## Problem

A FlowerCare on a weak link holds a connection only a few seconds. That is the
physical cause behind stalled history syncs: the sensor drops the link before
enough entries get through. The software side of this was fixed (setup no
longer burns the connection window on a futile auth wait), but the user is
still blind to the actual link quality and has no way to act on it.

Two concrete gaps:

1. **The app currently lies about it.** `HistoryLoadingView` has a complete
   `connectionQualityView` with `poor` / `fair` / `good` states, an animation
   and a tip block — but `connectionQuality` is assigned in exactly one place
   (`HistoryLoadingView.swift:477`), hardcoded to `.good` once connected.
   `.poor` and `.fair` are unreachable. During a field session at −81…−86 dBm
   the app showed "good connection" the whole time.
2. **The RSSI signal that exists is too slow to act on.** `rssiPublisher`
   emits every 5 s and no view subscribes to it; the values only reach the log.
   Walking around to find a better spot needs roughly 1 Hz.

The user's ask, verbatim: during history loading, tell them "you are standing
in a bad spot, go elsewhere" — and then whether the new spot is actually better.

## Approach

**RSSI as the fast needle, throughput as the verdict.** RSSI reacts within a
second and makes walking around feel responsive, but it is only a proxy — a
good RSSI does not guarantee a stable sync. Throughput (entries/second) measures
exactly what the user cares about, but needs 10–20 s in one position before the
number means anything. Using both, with that role split, avoids being led to a
spot the needle likes and the sync still aborts.

Comparison is **relative, not absolute**: the question is "is it better *here*
than *there*", not "is 2.4 entries/s objectively good". This also avoids
inventing throughput thresholds we have no evidence for.

## Architecture

New unit `LinkQualityMonitor` (`GrowGuard/BLE/`), with no CoreBluetooth
dependency — values are handed in, a verdict comes out. Testable in virtual
time with `TestScheduler`, in the spirit of `ReconnectPolicy`.

```
DeviceConnection ──rssiPublisher──┐
                 ──progress───────┼──► LinkQualityMonitor ──► LinkQuality
                 ──disconnects────┘        (smoothing,          snapshot
                                            hysteresis,             │
                                            baseline)               ▼
                                                          HistoryLoadingView
```

`LinkQuality` snapshot: stage (`good`/`fair`/`poor`/`disconnected`), smoothed
dBm, throughput (entries/s, `nil` until measurable), delta against the
reference point.

**Sampling is consolidated.** Today two independent 5 s timers both call
`peripheral.readRSSI()` during a sync — `startRSSIMonitoring()` (from
`handleConnected`) and `startConnectionQualityMonitoring()` (from the history
flow) — uncoordinated, both feeding the same `rssiSubject`. These collapse into
one timer that runs at **1 Hz while a history flow is active** and at the
existing 5 s otherwise. `readRSSI()` on iOS is a local controller query and
costs no extra air traffic, so the faster rate does not steal sync bandwidth.

## Verdict logic

- **Smoothing:** median of the last 5 samples (a 5 s window at 1 Hz). Median,
  not mean, so a single −95 dBm outlier cannot swing the stage.
- **Bands:** `≥ −70` good, `−70…−80` fair, `< −80` poor. Grounded in evidence,
  not invented: the existing code warns below −70, and the field log stalled at
  −81…−86.
- **Hysteresis:** 3 dB at the band edges. Without it the display oscillates
  around −80 and the user chases noise.
- **Throughput:** entries/s. The number the user is shown is the difference
  against the reference position (below), not against an absolute threshold.
  The session's best rate is tracked separately, only to label the current spot
  as "best so far". A position counts as measured after ~10 s with entries
  flowing; until then the UI shows "measuring…" rather than a number.
- **Reference point:** captured automatically the first time the stage drops to
  `poor` — that is the moment the user starts moving. The display then shows the
  difference ("+7 dB, 3.1 instead of 0.4 entries/s"). A "stay here" button
  re-baselines.
- **Connection gaps:** while reconnecting, no samples arrive. The stage becomes
  `disconnected` and the needle is NOT frozen at its last value. A stale good
  value is exactly the lie the current hardcoded `.good` already tells.

## UI

`connectionQualityView` in `HistoryLoadingView` gets real data and four states:

| State | Presentation |
|---|---|
| good / fair | Unobtrusive: stage, dBm, throughput ("3.1 entries/s · −64 dBm"). No call to action. |
| poor | The existing tip block expands: "Weak signal (−84 dBm). Move closer to the plant or clear obstacles." Reference point is set. |
| searching | Comparison line: "before −84 dBm · now −71 dBm ▲ better", throughput follows after ~10 s. Plus a **"stay here"** button that re-baselines. |
| disconnected | "Connection lost, reconnecting…" — no frozen needle. |

All strings via `L10n.*` in `Localizable.strings`, regenerated with `swiftgen`
(project convention).

**Haptics:** a light `UIImpactFeedbackGenerator` pulse on stage change. While
walking around and crouching at a plant pot the user is not staring at the
screen; this is what makes the feature usable rather than merely well-meant.

## Logging

Raw RSSI values already land in `BLESessionRecorder` (`.rssiRead` including the
value) whenever recording is enabled — nothing to build there. What is missing
is the verdict around them, emitted via `AppLogger.ble` so it appears in the
log export:

- every stage transition with values (`📶 poor → fair: −84 → −71 dBm`)
- a per-position summary on "stay here"
- **one summary line per sync**: entries, reconnects, median RSSI, worst
  stretch. This is the line that saves half the analysis on the next problem
  report.

## Testing

`LinkQualityMonitorTests`, virtual time:

- a single −95 dBm outlier does not change the stage (median smoothing)
- no oscillation across the −80 boundary (hysteresis)
- no frozen value during a connection gap — stage becomes `disconnected`
- delta against the reference point is computed correctly
- throughput reports "measuring…" until enough samples exist

`FakeFlowerCarePeripheral` needs **scriptable RSSI** — it currently returns a
fixed −55 dBm, which cannot simulate walking around. A sequence or closure
replaces the constant.

The view itself stays untested, consistent with the rest of the loading view.

## Out of scope

- **Persisting RSSI to Core Data** for multi-week trend correlation. New entity
  plus migration; session recording and log export already answer "why did this
  sync fail". A separate feature if trends are wanted later.
- **Steering WiFi to 5 GHz from the app.** Not possible: iOS gives apps no band
  control, and the band cannot even be read reliably
  (`CNCopyCurrentNetworkInfo` is restricted since iOS 13 and returns SSID/BSSID
  only). Router-side concern; the app can at most show a hint.
- **Movement detection via CoreMotion.** Not needed for the feedback loop.

## Implementation note

`GrowGuard.xcodeproj/project.pbxproj` is hand-maintained — new source files
must be registered manually (PBXBuildFile, PBXFileReference, group children,
Sources build phase).

# Sensor Health — honest battery display and dead-sensor detection

**Date:** 2026-09-14
**Status:** Approved, not yet implemented
**Related:** `2026-06-12-background-ble-design.md` (wake loop), `BLE-Reliability.md`

## Problem

A user's sensor showed **25 % battery** while it had in fact been dead for
days: no readings arrived, the app kept displaying the last number it knew,
and nothing pointed at the battery. Swapping the cell fixed everything
instantly. The cell was a cheap CR2032 (IKEA 20-pack), which matters: those
sag under radio load and the FlowerCare's percentage, derived from cell
voltage, falls off a cliff instead of declining linearly. For this sensor
"25 %" already means "replace now".

Four concrete gaps in the app:

1. **Battery is persisted only while the detail screen is open.** The only
   subscriber to `deviceInfoPublisher` is `DeviceDetailsViewModel`
   (`DeviceDetailsViewModel.swift:151`). Every background wake reads the
   battery from the sensor (`completeAuthentication` → `readDeviceInfo`) and
   nobody stores it. The 25 % was whatever the detail screen last saw.
2. **The battery value has no timestamp.** `updateDeviceInfo` deliberately
   leaves `lastUpdate` alone (battery reads are not measurements), so the app
   cannot tell that the 25 % is days old.
3. **Nothing detects a silent sensor.** The overview shows "3 days ago" but no
   warning and no notification. That is what would have caught this case.
4. **Icon and colour are hardcoded** to `battery.75percent` in green
   (`OverviewList.swift:385`, `DeviceDetailsView.swift:53`), whatever the value.

## Approach

**A pool-level health monitor, not a smarter detail screen.** Battery
persistence and contact bookkeeping move to a service that observes the
`ConnectionPoolManager`, so background wakes count as much as an open detail
screen. A pure verdict type turns the stored facts into one of a handful of
states the UI and the notification path both consume.

**"Silent" means time *and* failed attempts.** A sensor is declared
unreachable only when at least 48 h passed since the last reading **and** at
least 3 contact attempts since then failed. The attempt gate proves the *app
tried* — it guards against "Background App Refresh off, phone in a drawer",
where the app never had a chance and silence means nothing.

**The app cannot tell "dead" from "out of range".** BLE gives the same
signal for both: nothing. Silent pushes and BGAppRefresh fire wherever the
phone has network, so on a trip the attempt budget fills within hours and the
48 h gate alone decides. The design handles this with two tools instead of
pretending to detect holidays:

- **Peer witness.** If *another* sensor **at the same location** delivered a
  reading inside the 48 h window, the phone was demonstrably in range while
  this one stayed silent — the verdict is `confirmed`. A sensor in the
  living room says nothing about one in the garden shed, which is why the
  user assigns each sensor a location (below). With a single sensor, a
  sensor alone at its location, or when every sensor there is silent, the
  verdict is `unconfirmed`. All-silent is ambiguous on purpose: it is most
  likely a trip, but cells bought as a pack die as a pack (the reported case
  was an IKEA 20-pack), so it still warns.
- **Hedged copy.** An unconfirmed verdict says "not responding for 3 days —
  if you are at home, check the battery", not "the battery is empty". The
  cost of a false positive is one notification per trip; the cost of a false
  negative was days of missing data. The state clears itself on the first
  reading after the user returns.

Location-based home detection (geofence) was considered and rejected: it
needs a permission, a setup step and a location stack to suppress one
notification per trip.

Rejected alternatives:

- **Timestamp only, stay in the detail screen.** Cheap, but background reads
  stay unpersisted and a dead sensor stays undetected. Does not solve the
  reported problem.
- **Voltage-trend prediction.** Store the battery history and forecast a
  replacement date. Worthless for cells with a cliff-shaped curve; YAGNI.

## Data model

Four new attributes on `FlowerDevice`, all lightweight-migration compatible:

| Attribute | Type | Default | Meaning |
|---|---|---|---|
| `batteryUpdatedAt` | Date, optional | nil | When the battery value was last read from the sensor |
| `failedContactAttempts` | Integer 16 | 0 | Failed contact attempts since the last successful reading |
| `lastFailedContactAt` | Date, optional | nil | When the last failed attempt was recorded (rate limiting + UI) |
| `location` | String, optional | nil | User-named place ("Living room", "Balcony"); sensors sharing a location are within Bluetooth range of each other |

`location` is stored trimmed; an empty string is saved as nil. Matching is
exact after trimming — the suggestion UI (below) is what keeps "Balcony" and
"balcony" from becoming two places, not a fuzzy comparison.

**A new model version is required.** `CoreDataModels.xcdatamodeld` currently
holds a single unversioned `CoreDataModels.xcdatamodel`. Lightweight migration
needs the *source* model in the bundle to infer the mapping; editing the only
model in place makes existing stores (beta testers via TestFlight) fail to open
and `DataService` `fatalError`s. So: add `CoreDataModels 2.xcdatamodel`, mark
it current in `.xccurrentversion`, and add the attributes there.
`NSPersistentContainer` enables automatic + inferred migration by default; no
code change in `DataService` is needed.

`FlowerDeviceDTO` gets the four fields. `battery`, `batteryUpdatedAt`,
`lastUpdate`, `failedContactAttempts`, `lastFailedContactAt` and `location`
become `var`
so callers mutate a copy instead of rebuilding the 14-argument init. The
existing six call sites that reconstruct the whole DTO to change one field
(`updateDeviceInfo`, `updateDeviceLastUpdate`, `syncLastUpdateTimestamps`, …)
switch to `var copy = device; copy.x = …`. Fields that describe identity
(`id`, `uuid`, `added`, …) stay `let`.

## Architecture

```
ConnectionPoolManager ──deviceEventsPublisher──► SensorHealthMonitor ──► FlowerDeviceRepository
   (.deviceInfo / .sensorData /                      │      │
    .historicalData / .attemptGaveUp)                │      └──► NotificationService
                                                     │
BackgroundBLEWakeService ──recordFailedContact──────┘

FlowerDeviceDTO ──► SensorHealth.evaluate(device:peers:now:) ──► OverviewList / DeviceDetailsView
```

### `ConnectionPoolManager.deviceEventsPublisher` (new seam)

One pool-wide `AnyPublisher<DeviceEvent, Never>`. `getConnection(for:)` merges
each new connection's `deviceInfoPublisher`, `sensorDataPublisher` and
`historicalDataPublisher` into it, tagged with the device UUID, at creation
time. `handleAttemptFailure`'s `.giveUp` branch emits `.attemptGaveUp(uuid)`.

```swift
enum DeviceEvent {
    case deviceInfo(uuid: String, DeviceConnection.DeviceInfo)
    case sensorData(uuid: String)
    case historicalData(uuid: String)
    case attemptGaveUp(uuid: String)
}
```

Payload-free cases carry only the UUID; the monitor needs "contact happened",
not the reading. This keeps the seam small and lets tests drive it directly.

### `SensorHealthMonitor` (`GrowGuard/Services/`)

Singleton in the style of `BackgroundBLEWakeService`, started once from
`AppDelegate`. Dependencies injected through `init` for tests: the pool's
event publisher, `FlowerDeviceRepository`, a `SensorHealthNotifying` protocol
(implemented by `NotificationService`), `UserDefaults`, and a `now: () -> Date`
clock. No CoreBluetooth.

Responsibilities:

1. **Persist battery.** On `.deviceInfo`: load the device, set `battery`,
   `firmware`, `batteryUpdatedAt = now`, save. `lastUpdate` stays untouched
   (unchanged rule: battery reads are not measurements).
2. **Bookkeep contact.**
   - `.sensorData` / `.historicalData` → `recordSuccessfulContact(uuid)`:
     `failedContactAttempts = 0`, `lastFailedContactAt = nil`, clear the
     unreachable-notified marker.
   - `.attemptGaveUp` and the explicit `recordFailedContact(uuid)` entry point
     → `failedContactAttempts += 1`, `lastFailedContactAt = now`.
     **Rate limit:** a failure less than 1 h after `lastFailedContactAt` is
     ignored. Background triggers (push, BGAppRefresh, enter-background) can
     fire minutes apart; without the limit one evening would exhaust the
     3-attempt budget and the time gate would be the only real gate.
3. **Notify on state change.** After every write, load all sensor devices,
   run `SensorHealth.evaluate` for the changed device with the others as
   peers, and hand the result to the notifier (below). A successful contact
   also re-evaluates every *other* silent sensor: the newly responding device
   is the witness that can upgrade their verdict from unconfirmed to
   confirmed.

Failed-contact call sites in `BackgroundBLEWakeService`:

- `armAll`: for each device, **before** re-arming, if
  `pool.isBackgroundArmed(uuid)` is already true the previous trigger armed the
  device and it never woke — the sensor did not advertise. That is exactly the
  dead-battery signature and the only place it is observable, because a
  never-advertising peripheral produces no CoreBluetooth callback at all.
  Record a failure, then re-arm as today.
- `finishRead(success: false)`: the sensor connected but delivered no reading
  within `wakeReadTimeout`, or dropped before authenticating.

`DeviceDetailsViewModel` keeps its `deviceInfoPublisher` subscription **only
to refresh its displayed copy**; the repository write in `updateDeviceInfo`
is removed. The monitor owns persistence; the view model owns what is on
screen. The two arrive from the same event, so no ordering dependency exists.

### `SensorHealth` (pure verdict, `GrowGuard/Core/`)

```swift
enum SensorHealth: Equatable {
    case ok
    case batteryUnknown                     // never read
    case batteryLow(percent: Int)           // ≤ 30 %
    case batteryCritical(percent: Int)      // ≤ 15 %
    case unreachable(since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool)

    /// `peers` are the *other* sensor devices; they act as witnesses.
    static func evaluate(_ device: FlowerDeviceDTO,
                         peers: [FlowerDeviceDTO],
                         now: Date) -> SensorHealth
}
```

`confirmedByPeer` is true when at least one peer **with the same `location`**
has a last reading younger than 48 h. `nil` matches only `nil`: sensors
without a location form their own group, and tagging one sensor deliberately
takes it out of that group. Non-sensor peers are ignored.

Evaluation order (first match wins):

"Last reading" below is the later of `lastUpdate` and the newest entry in
`sensorData` — background saves do not always bump `lastUpdate` (the overview
syncs it lazily in `syncLastUpdateTimestamps`), and the monitor evaluates in
the background where that sync has not run.

1. `!device.isSensor` → `.ok`
2. `now - lastReading ≥ 48 h && failedContactAttempts ≥ 3` → `.unreachable`.
   `lastKnownBattery` is `battery` if `batteryUpdatedAt != nil`, else `nil`.
3. `batteryUpdatedAt == nil` → `.batteryUnknown`
4. `battery ≤ 15` → `.batteryCritical`
5. `battery ≤ 30` → `.batteryLow`
6. otherwise `.ok`

Thresholds are constants on the type (`unreachableAfter = 48 h`,
`unreachableAttempts = 3`, `lowBattery = 30`, `criticalBattery = 15`). **The
percentages are an assumption**, chosen from the reported failure at 25 % and
community reports that FlowerCare units stop responding in the 20–30 % band
with weak cells. Revisit if field data says otherwise; they live in one place.

Staleness is a display concern, not a health state: the views show
`batteryUpdatedAt` relative ("read 9 days ago") when it is older than 7 days.

### Notifications (`NotificationService`)

Two new notifications, both once per episode, marker keys in `UserDefaults`
following the existing `notification.lastImmediate.<uuid>` pattern:

| Trigger | Marker | Cleared when |
|---|---|---|
| Health becomes `.unreachable` | `sensorHealth.unreachableNotified.<uuid>` stores the flavour (`unconfirmed` / `confirmed`) | next successful contact |
| Health becomes `.batteryLow` or `.batteryCritical` | `sensorHealth.lowBatteryNotified.<uuid>` | battery read back above 40 % (new cell) |

The unreachable marker allows exactly one upgrade: an episode that was
notified as `unconfirmed` may notify once more when it becomes `confirmed`
(the user came home, another sensor answered, this one still did not). A
`confirmed` episode never notifies again. It never downgrades — a peer going
silent later does not turn a confirmed verdict back into an unconfirmed one
for notification purposes.

Copy (via `L10n`, English strings in `Localizable.strings`):

- Unreachable, unconfirmed: title "🔋 {name} is not responding", body "No
  readings for {n} days. Were you near it? If so, check the battery — last
  known level {p} %." With a location set the body starts with "No readings
  from {location} for {n} days." When `lastKnownBattery` is nil the body
  drops the last clause.
- Unreachable, confirmed: title "🔋 {name} needs a new battery", body "Your
  other sensors at {location} respond, this one has been silent for {n}
  days. Last known level {p} %." Without a location: "Your other sensors
  respond, …". Same rule for a nil level.
- Low battery: title "🔋 Replace the battery in {name}", body "Battery is at
  {p} %. Cheap coin cells drop out without warning at this level."

Both use `interruptionLevel = .active` (not time-sensitive; nothing is dying
right now except the sensor). `cancelNotifications(for:)` also removes these
identifiers when a device is deleted.

## UI

**Battery chip** (overview row and details header), replacing the hardcoded
symbol:

| Health | Symbol | Colour | Text |
|---|---|---|---|
| ok | `battery.100percent` / `.75percent` / `.50percent` by level | green | "82 %" |
| batteryLow | `battery.25percent` | orange | "25 %" |
| batteryCritical | `battery.0percent` | red | "12 %" |
| batteryUnknown | `battery.0percent` | secondary | "–" |

Symbol by level: > 87 → 100, > 62 → 75, > 37 → 50, > 12 → 25, else 0. When
`batteryUpdatedAt` is older than 7 days a secondary caption below the chip
reads "read {relative}".

**Unreachable banner.** In the overview row the connection-status line
("Disconnected · Active …") is replaced by a red line: "Not responding for 3
days" (unconfirmed) or "Silent for 3 days · replace battery" (confirmed). In
the details header a full-width red banner below the last-update line carries
the same headline plus one explanatory sentence: unconfirmed — "If you are at
home, check the battery."; confirmed — "Your other sensors respond, this one
does not." — followed by "Last known battery 25 %" when available. The banner
has no button; the fix is physical. The views obtain peers from the device
list they already hold (overview) or a repository fetch on load (details).
With a location set, the confirmed sentence reads "Your other sensors at
{location} respond, this one does not." and the unconfirmed one "Were you
near {location}? If so, check the battery."

**Location field.** A new "Location" section directly below "Device Name" in
both the device settings form (`SettingsView`) and the add-device form
(`AddDeviceDetails`): one `TextField` with the footer "Sensors at the same
location are within Bluetooth range of each other. Two floors are two
locations." Below the field, the distinct locations already used by other
devices appear as tappable chips; tapping one fills the field. That is the
whole de-duplication mechanism. The overview row shows the location as a
secondary caption after the name when set ("Rose · Balcony").

All strings are `L10n` keys; regenerate `Strings+Generated.swift` with
`swiftgen`. The overview's existing English literals in `connectionLabel` are
out of scope and stay as they are.

## Logging

`AppLogger.sensor` gets one line per state transition
(`🔋 Rose: ok → unreachable (3 attempts, last reading 2.1 d ago, battery 25 %)`)
and one per persisted battery read. No new log categories.

## Testing

`SensorHealthTests` (pure, no BLE, no Core Data):

- 47 h without reading and 10 failed attempts → not unreachable (time gate)
- 5 days without reading and 2 failed attempts → not unreachable (attempt gate)
- 48 h and 3 attempts → unreachable, `lastKnownBattery` populated iff
  `batteryUpdatedAt` set
- no peers → `confirmedByPeer == false`; one peer with a reading 1 h old →
  true; only peers that are themselves 3 days silent → false; a non-sensor
  peer with a fresh `lastUpdate` → false (ignored)
- location: fresh peer at the same location → true; fresh peer at a
  different location → false; both nil → true; device nil, peer "Balcony" →
  false; " Balcony " and "Balcony" match (trimmed on save)
- battery 30 → low, 31 → ok, 15 → critical, 16 → low (boundaries)
- battery never read → unknown even when value is 0
- non-sensor device → always ok

`SensorHealthMonitorTests` with a fake repository, fake notifier, injected
clock and a `PassthroughSubject<DeviceEvent, Never>`:

- `.deviceInfo` persists battery + `batteryUpdatedAt`, leaves `lastUpdate`
- `.sensorData` resets `failedContactAttempts` and clears the unreachable
  marker
- two failures 10 min apart count once; 61 min apart count twice
- crossing into unreachable notifies once; a second evaluation does not; a
  success then another crossing notifies again
- an unconfirmed episode upgrades to confirmed exactly once: sensor A silent
  3 days, sensor B silent 3 days → A notified unconfirmed; B delivers a
  reading → A re-evaluated, notified confirmed; B delivers again → no third
  notification for A
- B going silent again after A was confirmed does not notify A again
- low-battery notification fires once at 30 %, not again at 28 %, again after
  a 95 % read followed by 29 %

`BackgroundWakeServiceTests` (existing `FakeBLETransport`, virtual time):

- a device armed by one trigger that never connects counts one failed contact
  on the next `armAll`
- a wake read that times out counts one failed contact
- a successful wake read records no failure

`ConnectionPoolManagerTests`:

- `deviceEventsPublisher` relays `deviceInfo` / `sensorData` from a connection
  created via `getConnection`, tagged with the right UUID
- `.giveUp` emits `.attemptGaveUp`

**Migration check (manual, before merge):** install the current `main` build
on a simulator, add a device, then install this branch's build on top and
confirm the device list still loads. This is the only guard against the
unversioned-model crash; it cannot run in the unit suite because the suite
uses the shared store of whatever model the test host was built with.

Views stay untested, consistent with the rest of the app.

## Out of scope

- **Widgets / Live Activity.** They do not show battery today; adding health
  there is a separate change.
- **Battery history and prediction.** See rejected alternatives.
- **Localising the existing hardcoded overview status labels.**
- **Grouping or filtering the overview by location.** The field is stored
  and shown; sorting the list around it is a separate feature.
- **Detecting the phone's location.** No geofence, no CoreLocation. The
  user tells the app where the sensor is, not where the phone is.
- **Changing the BLE protocol** (e.g. reading the battery characteristic more
  often). One read per authenticated connection is enough; the problem was
  that the read was thrown away.

## Implementation note

`GrowGuard.xcodeproj/project.pbxproj` is hand-maintained — new source files
(`SensorHealth.swift`, `SensorHealthMonitor.swift`, the two test files) and
the new `.xcdatamodel` version must be registered manually.

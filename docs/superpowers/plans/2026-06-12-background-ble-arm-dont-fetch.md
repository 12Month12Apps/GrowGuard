# Background BLE "Arm, Don't Fetch" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Background triggers (BGAppRefreshTask, silent push, enter-background) stop racing the ~30s window and instead arm no-timeout pending BLE connects; the BLE wake performs the read and the dry-plant notification check. BGProcessingTask runs history sync for chart density.

**Architecture:** `ConnectionPoolManager` gets a background-arm path (no watchdog, no retry budget, persisted across relaunch, emits on a publisher when an armed connect completes). A new `BackgroundBLEWakeService` consumes that publisher: auth → live read → save → `checkDeviceStatus` → disconnect → disarm (never re-arms — wake-loop prevention). A new `BackgroundHistorySyncService` runs sequential history syncs inside BGProcessingTask windows with suspend-on-expiration. `BackgroundSensorDataService` (the old race-the-window fetcher) is deleted.

**Tech Stack:** Swift, CoreBluetooth (via the existing `BLECentral`/`BLEPeripheralLink` seam), Combine, BackgroundTasks, swift-testing with `FakeCentral`/`FakeFlowerCarePeripheral`/`TestScheduler` (virtual time).

**Spec:** `docs/superpowers/specs/2026-06-12-background-ble-design.md`

**Build/test commands** (from AGENTS.md):
- Build: `xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build -quiet`
- Unit tests: `xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60`
- Single suite: append `-only-testing:GrowGuardTests/<SuiteName>`

**pbxproj is hand-maintained** (only `GrowGuardWidgets` is a filesystem-synchronized group). Every new file needs four entries in `GrowGuard.xcodeproj/project.pbxproj`: a `PBXBuildFile` line, a `PBXFileReference` line, a children entry in the right group, and a files entry in the right Sources build phase. Copy the style of the existing custom-ID entries (e.g. `56BGSD002EC7000000000001 /* BackgroundSensorDataService.swift */`). App files belong next to the `Services` group entries (around lines 108/268/516/965); test files next to `ConnectionPoolManagerTests.swift` entries (around lines 47/202/440/991).

---

## File structure

| File | Responsibility |
|---|---|
| `GrowGuard/BLE/ConnectionPoolManager.swift` (modify) | New background-arm API: `armBackgroundConnect`, `disarmBackgroundConnect`, `disarmAllBackgroundConnects`, `isBackgroundArmed`, `armedConnectionPublisher`, UserDefaults persistence, poweredOn re-arm, restore-state emit, armed-failure handling |
| `GrowGuard/Services/BackgroundBLEWakeService.swift` (create) | Wake orchestration: subscribe armed-connection events, live read, save, status check, disconnect, disarm, UIBackgroundTask bracket, foreground disarm |
| `GrowGuard/Services/BackgroundHistorySyncService.swift` (create) | Sequential history sync for BGProcessingTask with expiration suspend |
| `GrowGuard/AppDelegate.swift` (modify) | Triggers arm instead of fetch; early pool/wake-service init; processing task runs history sync |
| `GrowGuard/Info.plist` (modify) | Drop legacy `fetch` background mode |
| `GrowGuard/Services/BackgroundSensorDataService.swift` (delete) | Replaced; `BackgroundFetchResult` struct moves to `BackgroundTaskTracker.swift` |
| `GrowGuardTests/BLE/FakeBLETransport.swift` (modify) | Add `simulateConnectCompletion(of:)` to `FakeCentral` |
| `GrowGuardTests/BLE/BackgroundArmTests.swift` (create) | Pool arm behavior |
| `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift` (create) | Wake service orchestration |
| `GrowGuardTests/BLE/BackgroundHistorySyncTests.swift` (create) | History sync service |

---

### Task 1: Pool — background-arm API, happy path

**Files:**
- Modify: `GrowGuard/BLE/ConnectionPoolManager.swift`
- Modify: `GrowGuardTests/BLE/FakeBLETransport.swift` (add `simulateConnectCompletion`)
- Create: `GrowGuardTests/BLE/BackgroundArmTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj` (register test file)

- [x] **Step 1.1: Add `simulateConnectCompletion` to `FakeCentral`** (test infrastructure, needed by the failing tests)

In `GrowGuardTests/BLE/FakeBLETransport.swift`, inside `FakeCentral`'s `// MARK: Test triggers` section add:

```swift
/// Simulates a pending connect completing much later (background-arm
/// path: connectSucceeds was false when connect() was issued)
func simulateConnectCompletion(of identifier: UUID) {
    guard let fake = knownPeripherals[identifier] else { return }
    fake.state = .connected
    centralDelegate?.central(self, didConnect: fake)
}
```

- [x] **Step 1.2: Write the failing tests**

Create `GrowGuardTests/BLE/BackgroundArmTests.swift`:

```swift
//
//  BackgroundArmTests.swift
//  GrowGuardTests
//
//  Background-arm path of ConnectionPoolManager (spec
//  2026-06-12-background-ble-design.md): pending connects without
//  watchdog/retry, persisted across pool instances, armed publisher.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
struct BackgroundArmTests {

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundArmTests-\(UUID().uuidString)")!

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeSensor() -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        central.register(sensor)
        return sensor
    }

    /// Lets the pool's Task-hopped delegate callbacks run
    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    @Test("armBackgroundConnect issues a connect and emits on the armed publisher")
    func armedConnectEmits() async {
        let pool = makePool()
        let sensor = makeSensor()
        var emitted: [String] = []
        let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
        defer { sub.cancel() }

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()

        #expect(central.connectRequests == [sensor.identifier])
        #expect(emitted == [sensor.identifier.uuidString])
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("Armed connect has no watchdog and no retry burn: stays pending and completes late")
    func armedConnectSurvivesLongPending() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        var emitted: [String] = []
        let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
        defer { sub.cancel() }

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()
        // Far past the 10 s foreground watchdog and all retry backoffs
        scheduler.advance(by: 120)
        await pump()

        let connection = pool.getConnection(for: sensor.identifier.uuidString)
        if case .error = connection.connectionState {
            Issue.record("Armed connect must never produce an error state")
        }
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests.count == 1, "No retry storm for armed connects")

        // The pending connect completes much later — wake event fires
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        #expect(emitted == [sensor.identifier.uuidString])
    }

    @Test("disarm removes the device and persists")
    func disarmPersists() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()
        pool.disarmBackgroundConnect(for: sensor.identifier.uuidString)

        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        let secondPool = makePool()
        #expect(!secondPool.isBackgroundArmed(sensor.identifier.uuidString))
    }

    @Test("Armed set survives pool recreation (state-restoration relaunch)")
    func armedSetPersistsAcrossPoolInstances() async {
        let pool = makePool()
        let sensor = makeSensor()

        pool.armBackgroundConnect(for: sensor.identifier.uuidString)
        await pump()

        let relaunchedPool = makePool()
        #expect(relaunchedPool.isBackgroundArmed(sensor.identifier.uuidString))
    }
}
```

- [x] **Step 1.3: Register the test file in pbxproj**

In `GrowGuard.xcodeproj/project.pbxproj` add four lines, each next to the corresponding `ConnectionPoolManagerTests.swift` line (find with `grep -n "ConnectionPoolManagerTests" GrowGuard.xcodeproj/project.pbxproj`):

1. PBXBuildFile section: `56BARM012EC7000000000001 /* BackgroundArmTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56BARM002EC7000000000001 /* BackgroundArmTests.swift */; };`
2. PBXFileReference section: `56BARM002EC7000000000001 /* BackgroundArmTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackgroundArmTests.swift; sourceTree = "<group>"; };`
3. Tests group children (where `ConnectionPoolManagerTests.swift` is listed): `56BARM002EC7000000000001 /* BackgroundArmTests.swift */,`
4. GrowGuardTests Sources phase: `56BARM012EC7000000000001 /* BackgroundArmTests.swift in Sources */,`

- [x] **Step 1.4: Run the tests, verify they FAIL to compile** (missing `defaults:` init param, `armBackgroundConnect`, etc.)

Run: `xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -only-testing:GrowGuardTests/BackgroundArmTests`
Expected: build failure mentioning `armBackgroundConnect` / `defaults`.

- [x] **Step 1.5: Implement the arm API in `ConnectionPoolManager`**

a) Extend the stored properties (below the existing `connectOptions`):

```swift
// MARK: - Background Arm (pending connects, spec 2026-06-12)

/// Geräte mit aktivem Background-Pending-Connect. Persistiert, damit ein
/// State-Restoration-Relaunch armed-Geräte wiedererkennt.
private var backgroundArmedDevices: Set<String> = []
private let armedDevicesDefaultsKey = "ble_background_armed_devices"
private let defaults: UserDefaults

/// Meldet Geräte, deren Background-Pending-Connect zustande kam —
/// BackgroundBLEWakeService liest dann live aus und disarmt
private let armedConnectionSubject = PassthroughSubject<String, Never>()
var armedConnectionPublisher: AnyPublisher<String, Never> {
    armedConnectionSubject.eraseToAnyPublisher()
}
```

b) Change the init signature and load the persisted set:

```swift
init(central: BLECentral? = nil,
     scheduler: BLEScheduler = MainRunLoopScheduler(),
     now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
     defaults: UserDefaults = .standard) {
```

and inside the init body, after `self.now = now`:

```swift
self.defaults = defaults
self.backgroundArmedDevices = Set(defaults.stringArray(forKey: armedDevicesDefaultsKey) ?? [])
```

c) Add the public API (new section after `resetRetryCounter`):

```swift
// MARK: - Background Arm API

/// Pending-Connect ohne Watchdog/Retry-Budget: iOS verbindet, sobald der
/// Sensor advertised — Minuten oder Stunden später. Der Connect überlebt
/// App-Suspension und (mit State Restoration) System-Termination.
func armBackgroundConnect(for deviceUUID: String) {
    guard let uuid = UUID(uuidString: deviceUUID) else {
        AppLogger.ble.bleError("armBackgroundConnect: invalid UUID \(deviceUUID)")
        return
    }

    let connection = getConnection(for: deviceUUID)

    // Laufenden History-Sync nicht kapern (Auto-Reconnect hält ihn am Leben)
    guard !connection.isHistoryFlowActive else {
        AppLogger.ble.bleConnection("armBackgroundConnect: history flow active for \(deviceUUID), skipping")
        return
    }

    connection.setAutoStartHistoryFlowEnabled(false)
    backgroundArmedDevices.insert(deviceUUID)
    persistArmedDevices()

    guard central.state == .poweredOn else {
        // Bleibt armed; der poweredOn-Handler re-armt aus dem Set
        AppLogger.ble.bleWarning("armBackgroundConnect: Bluetooth not ready, \(deviceUUID) stays armed")
        return
    }

    if connection.connectionState == .connected || connection.connectionState == .authenticated {
        AppLogger.ble.bleConnection("armBackgroundConnect: \(deviceUUID) already connected, emitting wake")
        armedConnectionSubject.send(deviceUUID)
        return
    }

    guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
        // Kein Scan-Fallback: Background-Scans sind langsam; das Gerät war
        // schon mal verbunden, der nächste Trigger versucht es erneut
        AppLogger.ble.bleWarning("armBackgroundConnect: \(deviceUUID) not in retrieve cache, stays armed")
        return
    }

    connection.setPeripheral(peripheral)
    central.connect(peripheral, options: Self.connectOptions)
    AppLogger.ble.bleConnection("🛡 Armed background pending connect for \(deviceUUID)")
}

func disarmBackgroundConnect(for deviceUUID: String) {
    backgroundArmedDevices.remove(deviceUUID)
    persistArmedDevices()
}

func disarmAllBackgroundConnects() {
    backgroundArmedDevices.removeAll()
    persistArmedDevices()
}

func isBackgroundArmed(_ deviceUUID: String) -> Bool {
    backgroundArmedDevices.contains(deviceUUID)
}

private func persistArmedDevices() {
    defaults.set(Array(backgroundArmedDevices), forKey: armedDevicesDefaultsKey)
}
```

d) Emit the wake event in `didConnect`. In `central(_:didConnect:)`, after `connection.handleConnected()` add:

```swift
if backgroundArmedDevices.contains(peripheralUUID) {
    AppLogger.ble.info("🛡 Background-armed connect completed for \(peripheralUUID)")
    armedConnectionSubject.send(peripheralUUID)
}
```

- [x] **Step 1.6: Run the tests, verify all 4 PASS** (same command as 1.4)

- [x] **Step 1.7: Run the full unit suite** (no `-only-testing`) to confirm no regression (the init signature change uses a default, existing call sites must still compile).

- [x] **Step 1.8: Commit**

```bash
git add GrowGuard/BLE/ConnectionPoolManager.swift GrowGuardTests/BLE/FakeBLETransport.swift GrowGuardTests/BLE/BackgroundArmTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add background-arm pending connects to ConnectionPoolManager"
```

---

### Task 2: Pool — armed failure paths, poweredOn re-arm, restore emit

**Files:**
- Modify: `GrowGuard/BLE/ConnectionPoolManager.swift`
- Modify: `GrowGuardTests/BLE/BackgroundArmTests.swift`

- [x] **Step 2.1: Write the failing tests** (append to `BackgroundArmTests`)

```swift
@Test("didFailToConnect for an armed device burns no retries and stays armed")
func armedFailToConnectStaysArmed() async {
    let pool = makePool()
    let sensor = makeSensor()
    central.connectSucceeds = false

    pool.armBackgroundConnect(for: sensor.identifier.uuidString)
    await pump()

    // Simulate iOS reporting a transient connect failure 3x
    for _ in 0..<3 {
        central.centralDelegate?.central(central, didFailToConnect: sensor, error: nil)
        await pump()
        scheduler.advance(by: 30)
        await pump()
    }

    let connection = pool.getConnection(for: sensor.identifier.uuidString)
    if case .error = connection.connectionState {
        Issue.record("Armed connect failure must not surface as error state")
    }
    #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
}

@Test("poweredOn re-issues pending connects for persisted armed devices")
func poweredOnRearmsPersistedDevices() async {
    let sensor = makeSensor()
    defaults.set([sensor.identifier.uuidString], forKey: "ble_background_armed_devices")
    central.state = .poweredOff

    let pool = makePool()
    #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))
    #expect(central.connectRequests.isEmpty)

    central.simulateStateChange(to: .poweredOn)
    await pump()

    #expect(central.connectRequests == [sensor.identifier])
}

@Test("willRestoreState emits wake for already-connected armed devices")
func restoreEmitsForConnectedArmedDevice() async {
    let sensor = makeSensor()
    defaults.set([sensor.identifier.uuidString], forKey: "ble_background_armed_devices")
    sensor.state = .connected

    let pool = makePool()
    var emitted: [String] = []
    let sub = pool.armedConnectionPublisher.sink { emitted.append($0) }
    defer { sub.cancel() }

    central.centralDelegate?.central(central, willRestoreState: [sensor])
    await pump()

    #expect(emitted == [sensor.identifier.uuidString])
}
```

- [x] **Step 2.2: Run, verify the 3 new tests FAIL**

Run: same `-only-testing:GrowGuardTests/BackgroundArmTests` command.
Expected: `armedFailToConnectStaysArmed` may already pass or fail depending on retry handling (the failure handler currently burns retries and errors after 3 attempts — it must fail or error), `poweredOnRearmsPersistedDevices` FAILS (no re-arm), `restoreEmitsForConnectedArmedDevice` FAILS (no emit).

- [x] **Step 2.3: Implement the three behaviors**

a) In `central(_:didFailToConnect:error:)`, inside the `Task { @MainActor in ... }` after `cancelConnectionTimeout`, add before `handleAttemptFailure`:

```swift
if self.backgroundArmedDevices.contains(peripheralUUID) {
    // Armed Connects haben kein Retry-Budget: bleiben armed, der
    // nächste Trigger oder poweredOn re-issued den Pending-Connect
    AppLogger.ble.bleWarning("Armed connect failed for \(peripheralUUID) — staying armed, no retry burn")
    return
}
```

b) In the `.poweredOn` case of `central(_:didUpdateState:)`, after the existing `pendingConnections` replay block, add:

```swift
// Re-issue pending connects für armed Geräte (Restoration-Relaunch
// oder BT-Toggle); für bereits pendende Peripherals ein No-Op
for deviceUUID in Array(backgroundArmedDevices) {
    armBackgroundConnect(for: deviceUUID)
}
```

c) In `central(_:willRestoreState:)`, inside the `if peripheral.state == .connected` branch after `connection.handleConnected()`, add:

```swift
if backgroundArmedDevices.contains(peripheralUUID) {
    AppLogger.ble.info("🛡 Restored armed connection for \(peripheralUUID), emitting wake")
    armedConnectionSubject.send(peripheralUUID)
}
```

- [x] **Step 2.4: Run the suite, verify all `BackgroundArmTests` PASS**

- [x] **Step 2.5: Commit**

```bash
git add GrowGuard/BLE/ConnectionPoolManager.swift GrowGuardTests/BLE/BackgroundArmTests.swift
git commit -m "Armed connects: no retry burn, poweredOn re-arm, restore wake emit"
```

---

### Task 3: BackgroundBLEWakeService

**Files:**
- Create: `GrowGuard/Services/BackgroundBLEWakeService.swift`
- Create: `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj` (register both)

- [x] **Step 3.1: Write the failing tests**

Create `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift`:

```swift
//
//  BackgroundWakeServiceTests.swift
//  GrowGuardTests
//
//  Wake orchestration: armed connect completes → auth → live read →
//  save → status check → disconnect → disarm. Never re-arms.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
import UIKit
@testable import GrowGuard

@MainActor
struct BackgroundWakeServiceTests {

    final class Recorder {
        var saved: [(uuid: String, source: SensorDataSource)] = []
        var statusChecks: [String] = []
        var began = 0
        var ended = 0
    }

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundWakeServiceTests-\(UUID().uuidString)")!
    let recorder = Recorder()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeService(pool: ConnectionPoolManager,
                             deviceUUIDs: [String],
                             saveSucceeds: Bool = true) -> BackgroundBLEWakeService {
        let recorder = self.recorder
        let service = BackgroundBLEWakeService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveSample: { _, uuid, source in
                recorder.saved.append((uuid, source))
                return saveSucceeds
            },
            runStatusCheck: { uuid in recorder.statusChecks.append(uuid) },
            beginBackgroundTask: { recorder.began += 1; return UIBackgroundTaskIdentifier(rawValue: 7) },
            endBackgroundTask: { _ in recorder.ended += 1 }
        )
        service.start()
        return service
    }

    private func makeSensor() -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        central.register(sensor)
        return sensor
    }

    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    /// Pump + advance in small slices so scheduler work and main-actor
    /// Tasks interleave like in production
    private func settle(seconds: TimeInterval) async {
        let slices = max(1, Int(seconds / 0.1))
        for _ in 0..<slices {
            await pump()
            scheduler.advance(by: 0.1)
        }
        await pump()
    }

    @Test("Wake read happy path: save, status check, disconnect, disarm, bg-task bracket")
    func wakeReadHappyPath() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.map(\.uuid) == [sensor.identifier.uuidString])
        #expect(recorder.saved.map(\.source) == [.backgroundPush])
        #expect(recorder.statusChecks == [sensor.identifier.uuidString])
        #expect(recorder.began == 1)
        #expect(recorder.ended == 1)
        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(sensor.state == .disconnected, "Wake handler must disconnect to save sensor battery")
    }

    @Test("Disconnect before data ends the read cleanly and disarms (no re-arm)")
    func disconnectBeforeDataFinishesRead() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundTask)
        await pump()
        // Pending connect completes, then the sensor drops immediately
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        central.simulateDisconnect(of: sensor.identifier, error: nil)
        await settle(seconds: 1.0)

        #expect(recorder.saved.isEmpty)
        #expect(recorder.began == 1)
        #expect(recorder.ended == 1)
        #expect(!pool.isBackgroundArmed(sensor.identifier.uuidString))
        #expect(central.connectRequests.count == 1, "Wake handler must not re-arm")
    }
}
```

- [x] **Step 3.2: Register both new files in pbxproj**

Same four-entry pattern as Step 1.3. IDs:
- `BackgroundBLEWakeService.swift` (app target, next to the `BackgroundTaskTracker.swift` entries): fileRef `56BWKS002EC7000000000001`, buildFile `56BWKS012EC7000000000001`, group children where `BackgroundSensorDataService.swift` is listed, Sources phase of the app target.
- `BackgroundWakeServiceTests.swift` (test target): fileRef `56BWKT002EC7000000000001`, buildFile `56BWKT012EC7000000000001`.

- [x] **Step 3.3: Run, verify FAIL to compile** (`BackgroundBLEWakeService` missing)

Run: `-only-testing:GrowGuardTests/BackgroundWakeServiceTests`

- [x] **Step 3.4: Implement the service**

Create `GrowGuard/Services/BackgroundBLEWakeService.swift`:

```swift
//
//  BackgroundBLEWakeService.swift
//  GrowGuard
//
//  Handles BLE wakes from background-armed pending connects (spec:
//  docs/superpowers/specs/2026-06-12-background-ble-design.md).
//  Triggers (BGTask / silent push / enter-background) only ARM pending
//  connects via ConnectionPoolManager; when iOS completes one and wakes
//  the app, this service does auth → live read → save → dry-plant check
//  → disconnect → disarm. It never re-arms (wake-loop prevention).
//

import Foundation
import Combine
import UIKit

@MainActor
final class BackgroundBLEWakeService {

    static let shared = BackgroundBLEWakeService()

    // MARK: - Injected dependencies (tests override)

    private let pool: ConnectionPoolManager
    private let scheduler: BLEScheduler
    private let loadSensorDeviceUUIDs: () async -> [String]
    /// Returns true if the sample was valid and stored
    private let saveSample: (SensorDataTemp, String, SensorDataSource) async -> Bool
    /// Dry-plant notification check for one device
    private let runStatusCheck: (String) async -> Void
    private let beginBackgroundTask: () -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void

    // MARK: - State

    /// Arm source per device so saved samples carry the right SensorDataSource
    private var armSources: [String: SensorDataSource] = [:]
    private var activeReads: [String: WakeRead] = [:]
    private var armedConnectionSubscription: AnyCancellable?
    private var foregroundObserver: NSObjectProtocol?

    /// iOS grants ~10 s after a BLE wake; auth alone can take 4 s
    private let wakeReadTimeout: TimeInterval = 9.0

    private final class WakeRead {
        var cancellables: Set<AnyCancellable> = []
        var timeoutTask: BLEScheduledTask?
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var liveDataRequested = false
        var finished = false
    }

    init(pool: ConnectionPoolManager? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         loadSensorDeviceUUIDs: (() async -> [String])? = nil,
         saveSample: ((SensorDataTemp, String, SensorDataSource) async -> Bool)? = nil,
         runStatusCheck: ((String) async -> Void)? = nil,
         beginBackgroundTask: (() -> UIBackgroundTaskIdentifier)? = nil,
         endBackgroundTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        self.pool = pool ?? ConnectionPoolManager.shared
        self.scheduler = scheduler
        self.loadSensorDeviceUUIDs = loadSensorDeviceUUIDs ?? {
            let devices = (try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()) ?? []
            return devices.filter { $0.isSensor }.map { $0.uuid }
        }
        self.saveSample = saveSample ?? { data, uuid, source in
            (try? await PlantMonitorService.shared.validateSensorData(data, deviceUUID: uuid, source: source)) != nil
        }
        self.runStatusCheck = runStatusCheck ?? { uuid in
            guard let device = try? await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: uuid) else { return }
            try? await PlantMonitorService.shared.checkDeviceStatus(device: device)
        }
        self.beginBackgroundTask = beginBackgroundTask ?? {
            var id: UIBackgroundTaskIdentifier = .invalid
            id = UIApplication.shared.beginBackgroundTask(withName: "ble-wake-read") {
                UIApplication.shared.endBackgroundTask(id)
            }
            return id
        }
        self.endBackgroundTask = endBackgroundTask ?? { id in
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: - Lifecycle

    /// Must be called in didFinishLaunching, right after the pool exists,
    /// so wakes via state restoration are handled
    func start() {
        guard armedConnectionSubscription == nil else { return }

        armedConnectionSubscription = pool.armedConnectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceUUID in
                self?.handleArmedConnection(deviceUUID)
            }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                BackgroundBLEWakeService.shared.disarmAll()
            }
        }
    }

    /// Arms pending connects for all sensors. Cheap (~1 s) — call from
    /// BGAppRefreshTask, silent push, and applicationDidEnterBackground.
    func armAll(source: SensorDataSource) async {
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("🛡 Background arm: \(uuids.count) sensor(s), source \(source.rawValue)")
        for uuid in uuids {
            armSources[uuid] = source
            pool.armBackgroundConnect(for: uuid)
        }
    }

    func disarmAll() {
        pool.disarmAllBackgroundConnects()
        armSources.removeAll()
    }

    // MARK: - Wake handling

    private func handleArmedConnection(_ deviceUUID: String) {
        guard activeReads[deviceUUID] == nil else { return }

        AppLogger.ble.info("🛡 BLE wake: armed connect completed for \(deviceUUID)")
        let read = WakeRead()
        read.backgroundTaskID = beginBackgroundTask()
        activeReads[deviceUUID] = read

        let connection = pool.getConnection(for: deviceUUID)

        connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                switch state {
                case .authenticated:
                    guard !read.liveDataRequested else { return }
                    read.liveDataRequested = true
                    connection.requestLiveData()
                case .error, .disconnected:
                    self.finishRead(for: deviceUUID, success: false)
                default:
                    break
                }
            }
            .store(in: &read.cancellables)

        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .first()
            .sink { [weak self] sensorData in
                guard let self else { return }
                let source = self.armSources[deviceUUID] ?? .backgroundTask
                Task { @MainActor in
                    let saved = await self.saveSample(sensorData, deviceUUID, source)
                    if saved {
                        await self.runStatusCheck(deviceUUID)
                    }
                    self.finishRead(for: deviceUUID, success: saved)
                }
            }
            .store(in: &read.cancellables)

        read.timeoutTask = scheduler.schedule(after: wakeReadTimeout) { [weak self] in
            Task { @MainActor in
                self?.finishRead(for: deviceUUID, success: false)
            }
        }
    }

    private func finishRead(for deviceUUID: String, success: Bool) {
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        read.finished = true
        read.timeoutTask?.cancel()
        read.cancellables.removeAll()
        activeReads[deviceUUID] = nil
        armSources[deviceUUID] = nil

        // One trigger, one chance: never re-arm from a wake (wake-loop
        // prevention — the sensor advertises continuously in range)
        pool.disarmBackgroundConnect(for: deviceUUID)
        pool.disconnect(from: deviceUUID)

        if success {
            BackgroundTaskTracker.shared.recordRefreshTaskExecution(result: BackgroundFetchResult(
                successfulDevices: [deviceUUID],
                failedDevices: [],
                totalDataPoints: 1,
                duration: 0
            ))
        }

        endBackgroundTask(read.backgroundTaskID)
        AppLogger.ble.info("🛡 BLE wake read finished for \(deviceUUID) (success: \(success))")
    }
}
```

- [x] **Step 3.5: Run, verify both tests PASS**

- [x] **Step 3.6: Commit**

```bash
git add GrowGuard/Services/BackgroundBLEWakeService.swift GrowGuardTests/BLE/BackgroundWakeServiceTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add BackgroundBLEWakeService: wake-driven live reads with notification check"
```

---

### Task 4: BackgroundHistorySyncService

**Files:**
- Create: `GrowGuard/Services/BackgroundHistorySyncService.swift`
- Create: `GrowGuardTests/BLE/BackgroundHistorySyncTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

- [x] **Step 4.1: Write the failing tests**

Create `GrowGuardTests/BLE/BackgroundHistorySyncTests.swift`:

```swift
//
//  BackgroundHistorySyncTests.swift
//  GrowGuardTests
//
//  Sequential history sync for BGProcessingTask windows: full sync per
//  device, expiration suspends cleanly.
//

import Testing
import Combine
import Foundation
import CoreBluetooth
@testable import GrowGuard

@MainActor
struct BackgroundHistorySyncTests {

    final class Recorder {
        var savedEntries: [(deviceUUID: String, entry: HistoricalSensorData)] = []
        var done = false
    }

    let scheduler = TestScheduler()
    let central = FakeCentral()
    let defaults = UserDefaults(suiteName: "BackgroundHistorySyncTests-\(UUID().uuidString)")!
    let recorder = Recorder()

    private func makePool() -> ConnectionPoolManager {
        ConnectionPoolManager(central: central,
                              scheduler: scheduler,
                              now: { [scheduler] in scheduler.now },
                              defaults: defaults)
    }

    private func makeService(pool: ConnectionPoolManager, deviceUUIDs: [String]) -> BackgroundHistorySyncService {
        let recorder = self.recorder
        return BackgroundHistorySyncService(
            pool: pool,
            scheduler: scheduler,
            loadSensorDeviceUUIDs: { deviceUUIDs },
            saveHistoricalEntry: { entry, uuid in
                recorder.savedEntries.append((uuid, entry))
            }
        )
    }

    private func makeSensor(entries: Int) -> FakeFlowerCarePeripheral {
        let sensor = FakeFlowerCarePeripheral(scheduler: scheduler)
        sensor.historyEntries = (0..<entries).map { index in
            FlowerCareFrames.historyEntry(timestamp: UInt32(100 + index * 60),
                                          temperatureX10: Int16(200 + index),
                                          brightness: 1000,
                                          moisture: 40,
                                          conductivity: 300)
        }
        central.register(sensor)
        return sensor
    }

    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    @Test("Syncs all history entries of a device, then completes and disconnects")
    func syncsAllEntries() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 3)
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }

        for _ in 0..<100 where !recorder.done {
            await pump()
            scheduler.advance(by: 0.5)
        }
        await pump()

        #expect(recorder.done, "syncAllDevices must complete")
        #expect(recorder.savedEntries.count == 3)
        #expect(recorder.savedEntries.allSatisfy { $0.deviceUUID == sensor.identifier.uuidString })
        #expect(sensor.state == .disconnected)
    }

    @Test("requestExpiration suspends the in-flight sync and returns")
    func expirationSuspends() async {
        let pool = makePool()
        let sensor = makeSensor(entries: 50)
        sensor.silentEntryIndices = Set(5..<50) // sync stalls from entry 5
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])
        let recorder = self.recorder

        Task { @MainActor in
            await service.syncAllDevices()
            recorder.done = true
        }

        // Let the sync start and fetch the first few entries
        for _ in 0..<10 {
            await pump()
            scheduler.advance(by: 0.2)
        }
        #expect(!recorder.done)

        service.requestExpiration()
        await pump()

        #expect(recorder.done, "Expiration must make syncAllDevices return")
    }
}
```

- [x] **Step 4.2: Register both files in pbxproj** (same four-entry pattern as Step 1.3):
  - `BackgroundHistorySyncService.swift` (app target): fileRef `56BHSY002EC7000000000001`, buildFile `56BHSY012EC7000000000001`
  - `BackgroundHistorySyncTests.swift` (test target): fileRef `56BHST002EC7000000000001`, buildFile `56BHST012EC7000000000001`

- [x] **Step 4.3: Run, verify FAIL to compile**

Run: `-only-testing:GrowGuardTests/BackgroundHistorySyncTests`

- [x] **Step 4.4: Implement the service**

Create `GrowGuard/Services/BackgroundHistorySyncService.swift`:

```swift
//
//  BackgroundHistorySyncService.swift
//  GrowGuard
//
//  Runs full history syncs inside BGProcessingTask windows (minutes of
//  runtime, unlike the ~30 s of BGAppRefreshTask). Sequential per device;
//  the expiration handler suspends the in-flight flow so a later window
//  can resume while the process lives. Spec:
//  docs/superpowers/specs/2026-06-12-background-ble-design.md
//

import Foundation
import Combine

@MainActor
final class BackgroundHistorySyncService {

    static let shared = BackgroundHistorySyncService()

    // MARK: - Injected dependencies (tests override)

    private let pool: ConnectionPoolManager
    private let scheduler: BLEScheduler
    private let loadSensorDeviceUUIDs: () async -> [String]
    private let saveHistoricalEntry: (HistoricalSensorData, String) async -> Void

    /// Hard per-device cap; BGProcessing windows are usually several minutes
    private let perDeviceTimeout: TimeInterval = 240

    // MARK: - State

    private var expirationRequested = false
    private var currentDeviceUUID: String?
    private var currentContinuation: CheckedContinuation<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var completionObserver: NSObjectProtocol?
    private var timeoutTask: BLEScheduledTask?

    init(pool: ConnectionPoolManager? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         loadSensorDeviceUUIDs: (() async -> [String])? = nil,
         saveHistoricalEntry: ((HistoricalSensorData, String) async -> Void)? = nil) {
        self.pool = pool ?? ConnectionPoolManager.shared
        self.scheduler = scheduler
        self.loadSensorDeviceUUIDs = loadSensorDeviceUUIDs ?? {
            let devices = (try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()) ?? []
            return devices.filter { $0.isSensor }.map { $0.uuid }
        }
        self.saveHistoricalEntry = saveHistoricalEntry ?? { entry, uuid in
            _ = try? await PlantMonitorService.shared.validateHistoricSensorData(entry, deviceUUID: uuid)
        }
    }

    // MARK: - Public API

    func syncAllDevices() async {
        expirationRequested = false
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("📚 Background history sync: \(uuids.count) sensor(s)")
        for uuid in uuids {
            guard !expirationRequested else { break }
            await syncDevice(uuid)
        }
        AppLogger.ble.info("📚 Background history sync finished (expired: \(self.expirationRequested))")
    }

    /// Called from the BGProcessingTask expiration handler: suspends the
    /// in-flight flow (progress kept in DeviceConnection for resume) and
    /// makes syncAllDevices return.
    func requestExpiration() {
        expirationRequested = true
        guard let uuid = currentDeviceUUID else { return }
        AppLogger.ble.bleWarning("📚 History sync expiring — suspending device \(uuid)")
        pool.getConnection(for: uuid).suspendHistoryFlow()
        finishCurrentDevice()
    }

    // MARK: - Per-device sync

    private func syncDevice(_ deviceUUID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            currentDeviceUUID = deviceUUID
            currentContinuation = continuation

            let connection = pool.getConnection(for: deviceUUID)

            connection.historicalDataPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] entry in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.saveHistoricalEntry(entry, deviceUUID)
                    }
                }
                .store(in: &cancellables)

            connection.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    if case .error = state {
                        self?.finishCurrentDevice()
                    }
                }
                .store(in: &cancellables)

            completionObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let completedUUID = notification.object as? String
                Task { @MainActor in
                    guard completedUUID == deviceUUID else { return }
                    self?.finishCurrentDevice()
                }
            }

            timeoutTask = scheduler.schedule(after: perDeviceTimeout) { [weak self] in
                Task { @MainActor in
                    AppLogger.ble.bleWarning("📚 History sync timeout for \(deviceUUID)")
                    self?.finishCurrentDevice()
                }
            }

            // Pool contract: every new session needs a fresh retry budget
            pool.resetRetryCounter(for: deviceUUID)
            pool.connect(to: deviceUUID, autoStartHistoryFlow: true)
        }
    }

    private func finishCurrentDevice() {
        guard let continuation = currentContinuation else { return }
        currentContinuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil
        cancellables.removeAll()
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }
        if let uuid = currentDeviceUUID {
            pool.disconnect(from: uuid)
        }
        currentDeviceUUID = nil
        continuation.resume()
    }
}
```

- [x] **Step 4.5: Run, verify both tests PASS**

- [x] **Step 4.6: Commit**

```bash
git add GrowGuard/Services/BackgroundHistorySyncService.swift GrowGuardTests/BLE/BackgroundHistorySyncTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add BackgroundHistorySyncService for BGProcessingTask windows"
```

---

### Task 5: AppDelegate rewiring + Info.plist

No new unit tests (UIKit lifecycle glue); verified by build + full suite + manual checklist at the end.

**Files:**
- Modify: `GrowGuard/AppDelegate.swift`
- Modify: `GrowGuard/Info.plist`

- [x] **Step 5.1: Early BLE-stack init in `didFinishLaunchingWithOptions`**

At the very top of `application(_:didFinishLaunchingWithOptions:)` (before the badge reset) add:

```swift
// Create the BLE stack and wake handler before anything else: when iOS
// relaunches the app for a completed pending connect (state
// restoration), these must exist to receive the events
_ = ConnectionPoolManager.shared
BackgroundBLEWakeService.shared.start()
```

(`UIApplicationDelegate` callbacks are MainActor in the current SDK, so the direct access compiles; if the compiler disagrees, wrap both lines in `MainActor.assumeIsolated { ... }`.)

- [x] **Step 5.2: Arm on entering background**

Replace `applicationDidEnterBackground` with:

```swift
func applicationDidEnterBackground(_ application: UIApplication) {
    schedulePlantMonitoringTask(source: .enterBackground)
    scheduleProcessingTask(source: .enterBackground)

    // One near-guaranteed fresh sample right after the user leaves the
    // app: arm pending connects, the BLE wake does the read
    Task { @MainActor in
        await BackgroundBLEWakeService.shared.armAll(source: .backgroundTask)
    }
}
```

- [x] **Step 5.3: Refresh task arms instead of fetching**

Replace the whole body of `handlePlantMonitoringTask(task:)` with:

```swift
private func handlePlantMonitoringTask(task: BGAppRefreshTask) {
    schedulePlantMonitoringTask(source: .afterExecution)

    // Arm-don't-fetch (spec 2026-06-12): only issue pending connects
    // here. The read happens on the BLE wake via BackgroundBLEWakeService,
    // so nothing races the ~30 s window.
    let armWork = Task { @MainActor in
        await BackgroundBLEWakeService.shared.armAll(source: .backgroundTask)
        task.setTaskCompleted(success: !Task.isCancelled)
    }

    task.expirationHandler = {
        armWork.cancel()
    }
}
```

- [x] **Step 5.4: Silent push arms instead of fetching**

Replace the `if isContentAvailable { ... }` block in `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` with:

```swift
if isContentAvailable {
    print("🔄 AppDelegate: Silent push — arming background connects")
    Task { @MainActor in
        await BackgroundBLEWakeService.shared.armAll(source: .backgroundPush)
        completionHandler(.newData)
    }
} else {
    print("ℹ️ AppDelegate: Non-silent notification received")
    completionHandler(.noData)
}
```

- [x] **Step 5.5: Processing task runs history sync**

Replace the whole body of `handleProcessingTask(task:)` with:

```swift
private func handleProcessingTask(task: BGProcessingTask) {
    scheduleProcessingTask(source: .afterExecution)

    print("📚 AppDelegate: Processing task — background history sync")

    let syncWork = Task { @MainActor in
        await BackgroundHistorySyncService.shared.syncAllDevices()
        task.setTaskCompleted(success: true)
    }

    task.expirationHandler = {
        // Suspends the in-flight flow (progress kept for resume) and
        // makes syncAllDevices return, which completes the task above
        Task { @MainActor in
            BackgroundHistorySyncService.shared.requestExpiration()
        }
        _ = syncWork
    }
}
```

- [x] **Step 5.6: Remove the legacy `fetch` background mode**

In `GrowGuard/Info.plist` delete the line `<string>fetch</string>` from `UIBackgroundModes` (the app never calls `setMinimumBackgroundFetchInterval`; `processing`, `bluetooth-central`, `remote-notification` stay).

- [x] **Step 5.7: Build**

Run: `xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build -quiet`
Expected: success. (`BackgroundSensorDataService` is now unreferenced from AppDelegate but still compiles — deleted in Task 6.)

- [x] **Step 5.8: Commit**

```bash
git add GrowGuard/AppDelegate.swift GrowGuard/Info.plist
git commit -m "Rewire background triggers to arm-don't-fetch, processing task syncs history"
```

---

### Task 6: Delete BackgroundSensorDataService, move BackgroundFetchResult, update docs

**Files:**
- Delete: `GrowGuard/Services/BackgroundSensorDataService.swift`
- Modify: `GrowGuard/Services/BackgroundTaskTracker.swift` (receives the struct)
- Modify: `GrowGuard.xcodeproj/project.pbxproj` (remove 4 entries)
- Modify: `BLE-Reliability.md`, `AGENTS.md`

- [x] **Step 6.1: Move `BackgroundFetchResult` into `BackgroundTaskTracker.swift`**

Add at the top of `BackgroundTaskTracker.swift` (after the imports):

```swift
/// Result of a background sensor read (today: one device per BLE wake)
struct BackgroundFetchResult {
    let successfulDevices: [String]
    let failedDevices: [String]
    let totalDataPoints: Int
    let duration: TimeInterval
}
```

- [x] **Step 6.2: Delete the old service**

```bash
git rm GrowGuard/Services/BackgroundSensorDataService.swift
```

Remove its 4 pbxproj entries (lines containing `BackgroundSensorDataService.swift`; IDs `56BGSD002EC7000000000001` / `56BGSD012EC7000000000001`).

Verify no dangling references: `grep -rn "BackgroundSensorDataService" GrowGuard GrowGuardTests GrowGuard.xcodeproj/project.pbxproj` → expected: no matches.

- [x] **Step 6.3: Update docs**

- `AGENTS.md`: replace the `BackgroundSensorDataService` mentions (services list and the "~25s time limits" line) with: `BackgroundBLEWakeService` (arm-don't-fetch live reads on BLE wakes) and `BackgroundHistorySyncService` (history sync in BGProcessingTask windows); background triggers only arm pending connects.
- `BLE-Reliability.md`: in the "Session contract" caller list, replace `BackgroundSensorDataService (background fetch)` with `BackgroundHistorySyncService (background history sync)`, and add a short section "Background arming (arm-don't-fetch)" documenting: `armBackgroundConnect` has no watchdog/retry budget by design, armed set persisted in UserDefaults key `ble_background_armed_devices`, wake handling never re-arms (wake-loop prevention), spec reference.

- [x] **Step 6.4: Full build + full unit suite**

Run both commands from the header. Expected: build succeeds, all tests pass.

- [x] **Step 6.5: Commit**

```bash
git add -A
git commit -m "Delete BackgroundSensorDataService, document arm-don't-fetch architecture"
```

---

### Task 7: Final verification

- [x] **Step 7.1: Full unit suite** (command from header) — all green, paste summary line.
- [x] **Step 7.2: Release-ish build check** — plain `build` succeeds with no new warnings about unused symbols.
- [x] **Step 7.3: Manual on-device checklist (user-run, document in PR):**
  1. Launch app with sensor in range, send app to background → within ~1 min a new sample with source `background_task` appears (check debug stats / log export).
  2. Force a BGTask via Xcode: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"pro.veit.GrowGuard.plantMonitor"]` → handler returns instantly, sample arrives on the following BLE wake.
  3. Same for `com.growguard.processing` → history entries appear (source `history_loading`).

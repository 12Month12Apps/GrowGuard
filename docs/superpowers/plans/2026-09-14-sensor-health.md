# Sensor Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the battery from every connection with a timestamp, detect sensors that went silent, show an honest battery/health state in the UI, and notify once per episode — per spec `docs/superpowers/specs/2026-09-14-sensor-health-design.md`.

**Architecture:** A pool-wide `deviceEventsPublisher` on `ConnectionPoolManager` feeds a new `SensorHealthMonitor` service that owns battery persistence, failed-contact bookkeeping and notifications. A pure `SensorHealth` enum turns a `FlowerDeviceDTO` (plus its peers) into a verdict consumed by both the monitor and the views. Four new Core Data attributes arrive in a new model version.

**Tech Stack:** Swift 5 mode, SwiftUI, Combine, Core Data (lightweight migration), Swift Testing (`@Suite`, `#expect`), SwiftGen 6.6 for `L10n`.

## Global Constraints

- Build/test target: `-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'`, scheme `GrowGuard`, test plan `GrowGuard`. Always pass `-test-timeouts-enabled YES -default-test-execution-time-allowance 60`.
- `GrowGuard.xcodeproj/project.pbxproj` is hand-maintained: every new file needs a `PBXBuildFile`, a `PBXFileReference`, a group `children` entry and a `Sources` build-phase entry. App target Sources phase id: `56AF11112BDED05900887073`. Test target Sources phase id: `56AF11242BDED05B00887073`. Test root group id: `56AF112B2BDED05B00887073`. Services group id: `568EA33D2EB625CE00F6BB25`. DeviceDetails `Componetns` group id: `568892062C83292D000E8FAE` (sic, the folder is really spelled `Componetns`).
- Files under `GrowGuard/Core/` are registered in the **Services** group with `name = X.swift; path = ../Core/X.swift;` (precedent: `NotificationService.swift`, pbxproj line 278).
- UI strings go through `L10n.*`. After editing `GrowGuard/Strings/Localizable.strings` run `swiftgen` from the repo root (installed at `/opt/homebrew/bin/swiftgen`) to regenerate `GrowGuard/Strings/Strings+Generated.swift`, and commit both.
- Thresholds live on `SensorHealth` only: `unreachableAfter = 48 h`, `unreachableAttempts = 3`, `lowBattery = 30`, `criticalBattery = 15`, `staleBatteryAfter = 7 d`. Monitor constants: `failureRateLimit = 1 h`, `newCellThreshold = 40`.
- `lastUpdate` is bumped by measurements only — never by a battery read, never by saving settings.
- Views stay untested. Everything else is TDD with Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). BLE-adjacent tests use `FakeCentral`/`FakeFlowerCarePeripheral`/`TestScheduler` from `GrowGuardTests/BLE/FakeBLETransport.swift` and pump with `await drainMainActor()`.
- Commit after every task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Deutsch or English in code comments is both fine (the codebase mixes them); new identifiers are English.

---

## File structure

| File | Responsibility |
|---|---|
| `GrowGuard/Database/CoreDataModels.xcdatamodeld/CoreDataModels 2.xcdatamodel/contents` (new) | Model version 2: four new `FlowerDevice` attributes |
| `GrowGuard/Database/CoreDataModels.xcdatamodeld/.xccurrentversion` (new) | Marks version 2 as current |
| `GrowGuard/Database/DTOs/FlowerDeviceDTO.swift` | New fields, `var` for mutable ones, `batteryReadAt`, `lastReading`, `normalizeLocation` |
| `GrowGuard/Database/Extensions/FlowerDevice+DTO.swift` | Map the four new attributes both ways |
| `GrowGuard/Database/Repositories/FlowerDeviceRepository.swift` | `modifyDevice(uuid:_:)` fetch-mutate-save helper |
| `GrowGuard/Core/SensorHealth.swift` (new) | Pure verdict enum + thresholds |
| `GrowGuard/BLE/ConnectionPoolManager.swift` | `DeviceEvent`, `deviceEventsPublisher` |
| `GrowGuard/Core/NotificationService.swift` | `SensorHealthNotifying` conformance: two notifications |
| `GrowGuard/Services/SensorHealthMonitor.swift` (new) | Persist battery, count contacts, notify once per episode |
| `GrowGuard/Services/BackgroundBLEWakeService.swift` | Two failed-contact hooks |
| `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` | Display-only battery refresh, peers, health, `modifyDevice` |
| `GrowGuard/OverviewList/OverviewListViewModel.swift` | `modifyDevice` |
| `GrowGuard/DeviceDetails/Settings/SettingsView.swift` | `location` + suggestions, `modifyDevice` |
| `GrowGuard/AddDevice/Details/AddDeviceDetails.swift` | `location` field, direct DTO mutation |
| `GrowGuard/DeviceDetails/Componetns/BatteryIndicator.swift` (new) | Battery chip (symbol, colour, stale caption) |
| `GrowGuard/DeviceDetails/Componetns/SensorHealthBanner.swift` (new) | Unreachable banner (overview line + details banner) |
| `GrowGuard/DeviceDetails/Componetns/LocationField.swift` (new) | Text field + suggestion chips |
| `GrowGuard/OverviewList/OverviewList.swift`, `GrowGuard/DeviceDetails/DeviceDetailsView.swift` | Integrate chip, banner, location caption |
| `GrowGuard/AppDelegate.swift` | `SensorHealthMonitor.shared.start()` |
| `GrowGuard/Strings/Localizable.strings` + `Strings+Generated.swift` | New keys |
| `GrowGuardTests/FlowerDeviceDTOTests.swift` (new) | DTO helpers + `modifyDevice` |
| `GrowGuardTests/SensorHealthTests.swift` (new) | Verdict logic |
| `GrowGuardTests/SensorHealthMonitorTests.swift` (new) | Monitor with fakes |
| `GrowGuardTests/BLE/ConnectionPoolManagerTests.swift`, `BackgroundWakeServiceTests.swift` | Event publisher, failed-contact hooks |

---

### Task 1: Core Data model version 2, DTO fields, mapping, `modifyDevice`

**Files:**
- Create: `GrowGuard/Database/CoreDataModels.xcdatamodeld/CoreDataModels 2.xcdatamodel/contents`
- Create: `GrowGuard/Database/CoreDataModels.xcdatamodeld/.xccurrentversion`
- Modify: `GrowGuard.xcodeproj/project.pbxproj` (PBXFileReference near line 241, XCVersionGroup near line 1559, plus test file registration)
- Modify: `GrowGuard/Database/DTOs/FlowerDeviceDTO.swift` (whole file)
- Modify: `GrowGuard/Database/Extensions/FlowerDevice+DTO.swift:70-98`
- Modify: `GrowGuard/Database/Repositories/FlowerDeviceRepository.swift`
- Create: `GrowGuardTests/FlowerDeviceDTOTests.swift`

**Interfaces:**
- Produces: `FlowerDeviceDTO.batteryUpdatedAt: Date?`, `.failedContactAttempts: Int16`, `.lastFailedContactAt: Date?`, `.location: String?`, `.batteryReadAt: Date?` (computed), `.lastReading: Date` (computed), `static func normalizeLocation(_ raw: String?) -> String?`. Mutable (`var`): `name`, `battery`, `batteryUpdatedAt`, `firmware`, `lastUpdate`, `failedContactAttempts`, `lastFailedContactAt`, `location`, `optimalRange`, `potSize`, `selectedFlower`.
- Produces: `FlowerDeviceRepository.modifyDevice(uuid: String, _ mutate: (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO?`

- [ ] **Step 1: Write the failing tests**

Create `GrowGuardTests/FlowerDeviceDTOTests.swift`:

```swift
//
//  FlowerDeviceDTOTests.swift
//  GrowGuardTests
//
//  Sensor-health helpers on the DTO (spec 2026-09-14-sensor-health-design.md)
//  and the repository's fetch-mutate-save helper.
//

import Testing
import Foundation
@testable import GrowGuard

struct FlowerDeviceDTOTests {

    private func device(battery: Int16 = 50,
                        batteryUpdatedAt: Date? = nil,
                        lastUpdate: Date = Date(timeIntervalSince1970: 1_000_000),
                        sensorDates: [Date] = []) -> FlowerDeviceDTO {
        FlowerDeviceDTO(
            name: "Rose",
            uuid: "DTO-TEST-1",
            battery: battery,
            batteryUpdatedAt: batteryUpdatedAt,
            lastUpdate: lastUpdate,
            sensorData: sensorDates.map {
                SensorDataDTO(temperature: 20, brightness: 100, moisture: 40, conductivity: 300, date: $0, deviceUUID: "DTO-TEST-1")
            }
        )
    }

    @Test("batteryReadAt prefers the stored timestamp")
    func batteryReadAtPrefersTimestamp() {
        let stamp = Date(timeIntervalSince1970: 2_000_000)
        #expect(device(battery: 25, batteryUpdatedAt: stamp).batteryReadAt == stamp)
    }

    @Test("Legacy device: no timestamp but a value falls back to lastUpdate")
    func batteryReadAtFallsBackToLastUpdate() {
        let lastUpdate = Date(timeIntervalSince1970: 1_500_000)
        #expect(device(battery: 25, lastUpdate: lastUpdate).batteryReadAt == lastUpdate)
    }

    @Test("Never read: no timestamp and value 0 → nil")
    func batteryReadAtNilWhenNeverRead() {
        #expect(device(battery: 0).batteryReadAt == nil)
    }

    @Test("lastReading is the later of lastUpdate and the newest sample")
    func lastReadingUsesNewestSample() {
        let lastUpdate = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 1_200_000)
        let older = Date(timeIntervalSince1970: 900_000)
        #expect(device(lastUpdate: lastUpdate, sensorDates: [older, newer]).lastReading == newer)
        #expect(device(lastUpdate: lastUpdate, sensorDates: [older]).lastReading == lastUpdate)
        #expect(device(lastUpdate: lastUpdate).lastReading == lastUpdate)
    }

    @Test("normalizeLocation trims and turns empty into nil")
    func normalizeLocation() {
        #expect(FlowerDeviceDTO.normalizeLocation("  Balcony \n") == "Balcony")
        #expect(FlowerDeviceDTO.normalizeLocation("   ") == nil)
        #expect(FlowerDeviceDTO.normalizeLocation("") == nil)
        #expect(FlowerDeviceDTO.normalizeLocation(nil) == nil)
    }
}

/// Runs against the shared Core Data store like OverviewListViewModelTests,
/// hence serialized and with its own UUID so leftovers cannot collide.
@Suite(.serialized)
struct FlowerDeviceRepositoryModifyTests {

    @Test("modifyDevice fetches, mutates and saves only what the closure touches")
    func modifyDevicePreservesOtherFields() async throws {
        let repo = RepositoryManager.shared.flowerDeviceRepository
        let uuid = "MODIFY-\(UUID().uuidString)"
        let lastUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        var seed = FlowerDeviceDTO(name: "Rose", uuid: uuid, battery: 25, lastUpdate: lastUpdate)
        seed.location = "  Balcony "
        seed.failedContactAttempts = 2
        try await repo.saveDevice(seed)

        let returned = try await repo.modifyDevice(uuid: uuid) { $0.name = "Renamed" }
        let reloaded = try await repo.getDevice(by: uuid)

        #expect(returned?.name == "Renamed")
        #expect(reloaded?.name == "Renamed")
        #expect(reloaded?.battery == 25)
        #expect(reloaded?.location == "Balcony", "location is stored trimmed")
        #expect(reloaded?.failedContactAttempts == 2)
        #expect(reloaded?.lastUpdate == lastUpdate)
        #expect(reloaded?.batteryUpdatedAt == nil)

        try await repo.deleteDevice(uuid: uuid)
    }

    @Test("modifyDevice returns nil for an unknown device and writes nothing")
    func modifyDeviceUnknown() async throws {
        let repo = RepositoryManager.shared.flowerDeviceRepository
        let result = try await repo.modifyDevice(uuid: "MODIFY-UNKNOWN-\(UUID().uuidString)") { $0.name = "x" }
        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Register the test file in the pbxproj**

Add these three lines (each in the matching section) to `GrowGuard.xcodeproj/project.pbxproj`:

In `/* Begin PBXBuildFile section */` (next to line 101):
```
		56SHDT012EC7000000000001 /* FlowerDeviceDTOTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHDT002EC7000000000001 /* FlowerDeviceDTOTests.swift */; };
```
In `/* Begin PBXFileReference section */`:
```
		56SHDT002EC7000000000001 /* FlowerDeviceDTOTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FlowerDeviceDTOTests.swift; sourceTree = "<group>"; };
```
In the `56AF112B2BDED05B00887073 /* GrowGuardTests */` group's `children`, after `MoistureAnomalyServiceTests.swift`:
```
				56SHDT002EC7000000000001 /* FlowerDeviceDTOTests.swift */,
```
In the test Sources phase `56AF11242BDED05B00887073 /* Sources */`, `files`:
```
				56SHDT012EC7000000000001 /* FlowerDeviceDTOTests.swift in Sources */,
```

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/FlowerDeviceDTOTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: compile errors — `extra argument 'batteryUpdatedAt' in call`, `value of type 'FlowerDeviceDTO' has no member 'batteryReadAt'`, `no member 'modifyDevice'`.

- [ ] **Step 4: Add model version 2**

Create `GrowGuard/Database/CoreDataModels.xcdatamodeld/CoreDataModels 2.xcdatamodel/contents` — identical to the version-1 `contents` except the `FlowerDevice` entity, which gains four attributes (kept alphabetically sorted; the other three entities are copied verbatim):

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="24233.13" systemVersion="25A5295e" minimumToolsVersion="Automatic" sourceLanguage="Swift" usedWithSwiftData="YES" userDefinedModelVersionIdentifier="">
    <entity name="FlowerDevice" representedClassName="FlowerDevice" syncable="YES" codeGenerationType="class">
        <attribute name="added" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="battery" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="batteryUpdatedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="failedContactAttempts" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="firmware" attributeType="String" defaultValueString=""/>
        <attribute name="isSensor" attributeType="Boolean" defaultValueString="YES" usesScalarValueType="YES"/>
        <attribute name="lastFailedContactAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="lastUpdate" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="location" optional="YES" attributeType="String"/>
        <attribute name="name" attributeType="String"/>
        <attribute name="peripheralID" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="selectedFlowerID" optional="YES" attributeType="Integer 64" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="selectedFlowerImageUrl" optional="YES" attributeType="String"/>
        <attribute name="selectedFlowerMaxMoisture" optional="YES" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="selectedFlowerMinMoisture" optional="YES" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="selectedFlowerName" optional="YES" attributeType="String"/>
        <attribute name="uuid" attributeType="String"/>
        <relationship name="optimalRange" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="OptimalRange" inverseName="device" inverseEntity="OptimalRange"/>
        <relationship name="potSize" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="PotSize" inverseName="device" inverseEntity="PotSize"/>
        <relationship name="sensorData" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="SensorData" inverseName="device" inverseEntity="SensorData"/>
    </entity>
    <entity name="OptimalRange" representedClassName="OptimalRange" syncable="YES" codeGenerationType="class">
        <attribute name="maxBrightness" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="maxConductivity" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="maxMoisture" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="maxTemperature" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <attribute name="minBrightness" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="minConductivity" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="minMoisture" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="minTemperature" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <relationship name="device" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="FlowerDevice" inverseName="optimalRange" inverseEntity="FlowerDevice"/>
    </entity>
    <entity name="PotSize" representedClassName="PotSize" syncable="YES" codeGenerationType="class">
        <attribute name="height" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <attribute name="volume" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <attribute name="width" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <relationship name="device" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="FlowerDevice" inverseName="potSize" inverseEntity="FlowerDevice"/>
    </entity>
    <entity name="SensorData" representedClassName="SensorData" syncable="YES" codeGenerationType="class">
        <attribute name="brightness" attributeType="Integer 32" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="conductivity" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="date" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="moisture" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="source" optional="YES" attributeType="String" defaultValueString="unknown"/>
        <attribute name="temperature" attributeType="Double" defaultValueString="0.0" usesScalarValueType="YES"/>
        <relationship name="device" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="FlowerDevice" inverseName="sensorData" inverseEntity="FlowerDevice"/>
    </entity>
</model>
```

Create `GrowGuard/Database/CoreDataModels.xcdatamodeld/.xccurrentversion`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>_XCCurrentVersionName</key>
	<string>CoreDataModels 2.xcdatamodel</string>
</dict>
</plist>
```

Do **not** touch the version-1 `contents`; it must stay in the bundle so lightweight migration can find the source model.

In `project.pbxproj`, add a file reference right after line 241:
```
		569417552E0DD9C000AE7587 /* CoreDataModels 2.xcdatamodel */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcdatamodel; path = "CoreDataModels 2.xcdatamodel"; sourceTree = "<group>"; };
```
and replace the XCVersionGroup block with:
```
		569417542E0DD9C000AE7586 /* CoreDataModels.xcdatamodeld */ = {
			isa = XCVersionGroup;
			children = (
				569417552E0DD9C000AE7587 /* CoreDataModels 2.xcdatamodel */,
				569417552E0DD9C000AE7586 /* CoreDataModels.xcdatamodel */,
			);
			currentVersion = 569417552E0DD9C000AE7587 /* CoreDataModels 2.xcdatamodel */;
			path = CoreDataModels.xcdatamodeld;
			sourceTree = "<group>";
			versionGroupType = wrapper.xcdatamodel;
		};
```

- [ ] **Step 5: Rewrite the DTO**

Replace `GrowGuard/Database/DTOs/FlowerDeviceDTO.swift` with:

```swift
import Foundation

struct FlowerDeviceDTO: Identifiable, Hashable {
    let id: String
    var name: String
    let uuid: String
    let peripheralID: UUID?
    var battery: Int16
    /// When `battery` was last read from the sensor. nil for devices stored
    /// before 2026-09 (see `batteryReadAt`) and for sensors never read.
    var batteryUpdatedAt: Date?
    var firmware: String
    let isSensor: Bool
    let added: Date
    /// Time of the last measurement. Never bumped by battery reads or settings.
    var lastUpdate: Date
    let lastHistoryIndex: Int
    /// Failed contact attempts since the last successful reading
    var failedContactAttempts: Int16
    /// When the last failed attempt was recorded (rate limiting + UI)
    var lastFailedContactAt: Date?
    /// User-named place. Sensors sharing a location are within Bluetooth
    /// range of each other. Stored trimmed; empty is nil.
    var location: String?
    var optimalRange: OptimalRangeDTO?
    var potSize: PotSizeDTO?
    var selectedFlower: VMSpecies?
    let sensorData: [SensorDataDTO]

    init(
        id: String = UUID().uuidString,
        name: String,
        uuid: String,
        peripheralID: UUID? = nil,
        battery: Int16 = 0,
        batteryUpdatedAt: Date? = nil,
        firmware: String = "",
        isSensor: Bool = true,
        added: Date = Date(),
        lastUpdate: Date = Date(),
        lastHistoryIndex: Int = 0,
        failedContactAttempts: Int16 = 0,
        lastFailedContactAt: Date? = nil,
        location: String? = nil,
        optimalRange: OptimalRangeDTO? = nil,
        potSize: PotSizeDTO? = nil,
        selectedFlower: VMSpecies? = nil,
        sensorData: [SensorDataDTO] = []
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.peripheralID = peripheralID
        self.battery = battery
        self.batteryUpdatedAt = batteryUpdatedAt
        self.firmware = firmware
        self.isSensor = isSensor
        self.added = added
        self.lastUpdate = lastUpdate
        self.lastHistoryIndex = lastHistoryIndex
        self.failedContactAttempts = failedContactAttempts
        self.lastFailedContactAt = lastFailedContactAt
        self.location = location
        self.optimalRange = optimalRange
        self.potSize = potSize
        self.selectedFlower = selectedFlower
        self.sensorData = sensorData
    }

    // MARK: - Sensor health helpers (spec 2026-09-14-sensor-health-design.md)

    /// When the battery value was read. Devices stored before the timestamp
    /// existed fall back to `lastUpdate` when they have a value: the old code
    /// wrote the battery only from an open detail screen with a live
    /// connection, and that same connection bumped `lastUpdate`.
    var batteryReadAt: Date? {
        if let batteryUpdatedAt { return batteryUpdatedAt }
        return battery > 0 ? lastUpdate : nil
    }

    /// The later of `lastUpdate` and the newest sample. Background saves do
    /// not always bump `lastUpdate`; the overview syncs it lazily.
    var lastReading: Date {
        let newestSample = sensorData.map(\.date).max() ?? .distantPast
        return max(lastUpdate, newestSample)
    }

    /// Trims whitespace; empty becomes nil. Applied on every read and write.
    static func normalizeLocation(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
```

- [ ] **Step 6: Map the new attributes**

In `GrowGuard/Database/Extensions/FlowerDevice+DTO.swift`, change the `return FlowerDeviceDTO(` call in `toDTO()` to:

```swift
        return FlowerDeviceDTO(
            id: objectIdString,
            name: self.name ?? "Unknown Device",
            uuid: deviceUUID,
            peripheralID: self.peripheralID,
            battery: self.battery,
            batteryUpdatedAt: self.batteryUpdatedAt,
            firmware: self.firmware ?? "Unknown",
            isSensor: self.isSensor,
            added: self.added ?? Date(),
            lastUpdate: self.lastUpdate ?? Date(),
            failedContactAttempts: self.failedContactAttempts,
            lastFailedContactAt: self.lastFailedContactAt,
            location: FlowerDeviceDTO.normalizeLocation(self.location),
            optimalRange: optimalRangeDTO,
            potSize: potSizeDTO,
            selectedFlower: selectedFlowerDTO,
            sensorData: sensorDataDTOs
        )
```

In `updateFromDTO(_:)`, after `lastUpdate = dto.lastUpdate` add:

```swift
        batteryUpdatedAt = dto.batteryUpdatedAt
        failedContactAttempts = dto.failedContactAttempts
        lastFailedContactAt = dto.lastFailedContactAt
        location = FlowerDeviceDTO.normalizeLocation(dto.location)
```

- [ ] **Step 7: Add `modifyDevice`**

Append to `GrowGuard/Database/Repositories/FlowerDeviceRepository.swift`:

```swift

extension FlowerDeviceRepository {
    /// Fetch → mutate → save. Callers change only the fields they own, so a
    /// stale full copy never overwrites what another writer (for example
    /// SensorHealthMonitor) just persisted. Returns nil for unknown devices.
    @discardableResult
    func modifyDevice(uuid: String, _ mutate: (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO? {
        guard var device = try await getDevice(by: uuid) else { return nil }
        mutate(&device)
        try await updateDevice(device)
        return device
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/FlowerDeviceDTOTests -only-testing:GrowGuardTests/FlowerDeviceRepositoryModifyTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`. If the build fails with "The model used to open the store is incompatible" on the simulator, that is the persisted test store from before this task: run `xcrun simctl uninstall booted pro.veit.GrowGuard` (or erase the simulator) once and re-run; the migration check for real stores happens in Task 10.

- [ ] **Step 9: Commit**

```bash
git add GrowGuard/Database GrowGuard.xcodeproj/project.pbxproj GrowGuardTests/FlowerDeviceDTOTests.swift
git commit -m "Add sensor-health fields to FlowerDevice (model v2) and modifyDevice helper

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Replace whole-DTO reconstruction with `modifyDevice`

**Files:**
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` (`updateDeviceLastUpdate` ~line 470, `saveSettings` ~line 606)
- Modify: `GrowGuard/OverviewList/OverviewListViewModel.swift:30-66`
- Modify: `GrowGuard/DeviceDetails/Settings/SettingsView.swift:166-206` (`SettingsViewModel.saveSettings`)
- Modify: `GrowGuard/AddDevice/Details/AddDeviceDetails.swift:85-110`

**Interfaces:**
- Consumes: `FlowerDeviceRepository.modifyDevice(uuid:_:)` from Task 1.
- Produces: `DeviceDetailsViewModel.saveSettings` no longer bumps `lastUpdate`; `SettingsViewModel.saveSettings` writes only `name` and `selectedFlower`.

- [ ] **Step 1: DeviceDetailsViewModel**

Replace `updateDeviceLastUpdate()` with:

```swift
    @MainActor
    private func updateDeviceLastUpdate() async {
        do {
            if let updated = try await repositoryManager.flowerDeviceRepository.modifyDevice(uuid: device.uuid, { $0.lastUpdate = Date() }) {
                self.device = updated
            }
        } catch {
            print("Error updating device: \(error.localizedDescription)")
        }
    }
```

In `saveSettings(deviceName:optimalRange:potSize:)` replace the whole `do { ... } catch { ... }` body with:

```swift
        do {
            // Fetch-mutate-save: keeps battery, contact counters and location
            // that other writers own. lastUpdate is a measurement timestamp
            // and is deliberately NOT bumped here.
            guard let updatedDevice = try await repositoryManager.flowerDeviceRepository.modifyDevice(uuid: device.uuid, { fresh in
                fresh.name = deviceName
                fresh.optimalRange = optimalRange
                fresh.potSize = potSize
            }) else {
                throw RepositoryError.deviceNotFound
            }

            // Update local device only after successful database save
            self.device = updatedDevice
            print("✅ DeviceDetailsViewModel: Settings saved successfully (name '\(self.device.name)')")
        } catch {
            print("❌ DeviceDetailsViewModel: Failed to save settings: \(error.localizedDescription)")
            throw error
        }
```

- [ ] **Step 2: OverviewListViewModel**

Replace the `for device in allSavedDevices { ... }` loop in `syncLastUpdateTimestamps()` with:

```swift
        for device in allSavedDevices {
            guard let latestSensorDate = device.sensorData.first?.date,
                  latestSensorDate > device.lastUpdate else { continue }
            do {
                try await repositoryManager.flowerDeviceRepository.modifyDevice(uuid: device.uuid) {
                    $0.lastUpdate = latestSensorDate
                }
            } catch {
                print("Error updating lastUpdate for \(device.name): \(error.localizedDescription)")
            }
        }
```

- [ ] **Step 3: SettingsViewModel**

In `SettingsViewModel.saveSettings()` (inside `SettingsView.swift`), replace everything from `// Now update the device with the selectedFlower and name in a single operation` through `try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)` with:

```swift
        // Only the fields this form owns; everything else stays as stored
        try await repositoryManager.flowerDeviceRepository.modifyDevice(uuid: deviceUUID) { fresh in
            fresh.name = deviceName
            fresh.selectedFlower = selectedFlower
        }
        print("🔧 Saved device name: \(deviceName), flower: \(selectedFlower?.name ?? "nil") (ID: \(selectedFlower?.id ?? 0))")
```

The preceding `guard let device = try await ... getDevice(by: deviceUUID)` line becomes unused: change it to `guard try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) != nil else {` so the not-found check stays.

- [ ] **Step 4: AddDeviceDetails**

In the `searchedFlower` `didSet` (around line 85), replace the `flower = FlowerDeviceDTO(...)` reconstruction with:

```swift
            flower.name = searched.name
            flower.optimalRange = optimalRange
            flower.selectedFlower = searched
```

- [ ] **Step 5: Build and run the existing view-model tests**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/OverviewListViewModelTests -only-testing:GrowGuardTests/AddDeviceViewModelTests -only-testing:GrowGuardTests/FlowerDeviceRepositoryModifyTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift GrowGuard/OverviewList/OverviewListViewModel.swift GrowGuard/DeviceDetails/Settings/SettingsView.swift GrowGuard/AddDevice/Details/AddDeviceDetails.swift
git commit -m "Write device changes through modifyDevice instead of stale full copies

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `SensorHealth` verdict

**Files:**
- Create: `GrowGuard/Core/SensorHealth.swift`
- Create: `GrowGuardTests/SensorHealthTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `FlowerDeviceDTO.lastReading`, `.batteryReadAt`, `.failedContactAttempts`, `.location`, `.isSensor` (Task 1).
- Produces:
  ```swift
  enum SensorHealth: Equatable {
      case ok, batteryUnknown
      case batteryLow(percent: Int), batteryCritical(percent: Int)
      case unreachable(since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool)
      static let unreachableAfter: TimeInterval, unreachableAttempts: Int16, lowBattery: Int, criticalBattery: Int, staleBatteryAfter: TimeInterval
      static func evaluate(_ device: FlowerDeviceDTO, peers: [FlowerDeviceDTO], now: Date) -> SensorHealth
      var isUnreachable: Bool; var isLowBattery: Bool
      static func daysSilent(since: Date, now: Date) -> Int
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `GrowGuardTests/SensorHealthTests.swift`:

```swift
//
//  SensorHealthTests.swift
//  GrowGuardTests
//
//  Pure verdict logic (spec 2026-09-14-sensor-health-design.md).
//

import Testing
import Foundation
@testable import GrowGuard

struct SensorHealthTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    private func sensor(uuid: String = "A",
                        battery: Int16 = 80,
                        batteryUpdatedAt: Date? = Date(timeIntervalSince1970: 1_799_990_000),
                        silentFor: TimeInterval = 0,
                        attempts: Int16 = 0,
                        location: String? = nil,
                        isSensor: Bool = true) -> FlowerDeviceDTO {
        FlowerDeviceDTO(
            name: uuid,
            uuid: uuid,
            battery: battery,
            batteryUpdatedAt: batteryUpdatedAt,
            isSensor: isSensor,
            lastUpdate: now.addingTimeInterval(-silentFor),
            failedContactAttempts: attempts,
            location: location
        )
    }

    private func evaluate(_ device: FlowerDeviceDTO, peers: [FlowerDeviceDTO] = []) -> SensorHealth {
        SensorHealth.evaluate(device, peers: peers, now: now)
    }

    // MARK: Gates

    @Test("47 h silent with many failures is not unreachable (time gate)")
    func timeGate() {
        #expect(evaluate(sensor(silentFor: 47 * hour, attempts: 10)) == .ok)
    }

    @Test("5 days silent with 2 failures is not unreachable (attempt gate)")
    func attemptGate() {
        #expect(evaluate(sensor(silentFor: 5 * 24 * hour, attempts: 2)) == .ok)
    }

    @Test("48 h and 3 failures → unreachable with last known battery")
    func unreachable() {
        let device = sensor(battery: 25, silentFor: 48 * hour, attempts: 3)
        #expect(evaluate(device) == .unreachable(since: device.lastReading, lastKnownBattery: 25, confirmedByPeer: false))
    }

    @Test("Unreachable without any battery read carries nil")
    func unreachableWithoutBattery() {
        let device = sensor(battery: 0, batteryUpdatedAt: nil, silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device) == .unreachable(since: device.lastReading, lastKnownBattery: nil, confirmedByPeer: false))
    }

    @Test("Unreachable wins over low battery")
    func unreachableBeatsLowBattery() {
        #expect(evaluate(sensor(battery: 10, silentFor: 3 * 24 * hour, attempts: 3)).isUnreachable)
    }

    @Test("lastReading counts the newest sample, not only lastUpdate")
    func usesNewestSample() {
        var device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        device = FlowerDeviceDTO(
            name: device.name, uuid: device.uuid, battery: device.battery,
            batteryUpdatedAt: device.batteryUpdatedAt, lastUpdate: device.lastUpdate,
            failedContactAttempts: device.failedContactAttempts,
            sensorData: [SensorDataDTO(temperature: 20, brightness: 1, moisture: 1, conductivity: 1,
                                       date: now.addingTimeInterval(-hour), deviceUUID: device.uuid)]
        )
        #expect(evaluate(device) == .ok)
    }

    // MARK: Peer witness

    @Test("A fresh peer at the same location confirms")
    func peerConfirms() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3, location: "Balcony")
        let peer = sensor(uuid: "B", silentFor: hour, location: "Balcony")
        #expect(evaluate(device, peers: [peer]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: true))
    }

    @Test("A fresh peer at another location does not confirm")
    func peerOtherLocation() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3, location: "Balcony")
        let peer = sensor(uuid: "B", silentFor: hour, location: "Living room")
        #expect(evaluate(device, peers: [peer]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("nil location matches only nil")
    func nilLocationGroup() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: hour)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: true))
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: hour, location: "Balcony")]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("A peer that is itself silent for 3 days is no witness")
    func silentPeer() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: 3 * 24 * hour)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("A non-sensor peer with a fresh lastUpdate is ignored")
    func nonSensorPeer() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: 0, isSensor: false)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("The device itself in the peer list is not its own witness")
    func selfIsNoWitness() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [device]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    // MARK: Battery

    @Test("Battery boundaries: 30 low, 31 ok, 15 critical, 16 low")
    func batteryBoundaries() {
        #expect(evaluate(sensor(battery: 30)) == .batteryLow(percent: 30))
        #expect(evaluate(sensor(battery: 31)) == .ok)
        #expect(evaluate(sensor(battery: 15)) == .batteryCritical(percent: 15))
        #expect(evaluate(sensor(battery: 16)) == .batteryLow(percent: 16))
    }

    @Test("Never read → unknown even when the value is 0")
    func neverRead() {
        #expect(evaluate(sensor(battery: 0, batteryUpdatedAt: nil)) == .batteryUnknown)
    }

    @Test("Legacy device: value without timestamp is evaluated, read-at falls back to lastUpdate")
    func legacyDevice() {
        let device = sensor(battery: 25, batteryUpdatedAt: nil)
        #expect(evaluate(device) == .batteryLow(percent: 25))
        #expect(device.batteryReadAt == device.lastUpdate)
    }

    @Test("Non-sensor devices are always ok")
    func nonSensor() {
        #expect(evaluate(sensor(battery: 0, batteryUpdatedAt: nil, silentFor: 30 * 24 * hour, attempts: 9, isSensor: false)) == .ok)
    }

    @Test("isLowBattery covers low and critical, daysSilent floors")
    func helpers() {
        #expect(SensorHealth.batteryLow(percent: 20).isLowBattery)
        #expect(SensorHealth.batteryCritical(percent: 5).isLowBattery)
        #expect(!SensorHealth.ok.isLowBattery)
        #expect(SensorHealth.daysSilent(since: now.addingTimeInterval(-2.9 * 24 * hour), now: now) == 2)
    }
}
```

- [ ] **Step 2: Register both files in the pbxproj**

PBXBuildFile section:
```
		56SHEA012EC7000000000001 /* SensorHealth.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHEA002EC7000000000001 /* SensorHealth.swift */; };
		56SHTS012EC7000000000001 /* SensorHealthTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHTS002EC7000000000001 /* SensorHealthTests.swift */; };
```
PBXFileReference section:
```
		56SHEA002EC7000000000001 /* SensorHealth.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = SensorHealth.swift; path = ../Core/SensorHealth.swift; sourceTree = "<group>"; };
		56SHTS002EC7000000000001 /* SensorHealthTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SensorHealthTests.swift; sourceTree = "<group>"; };
```
Services group `568EA33D2EB625CE00F6BB25` children: add `56SHEA002EC7000000000001 /* SensorHealth.swift */,`.
Test root group `56AF112B2BDED05B00887073` children: add `56SHTS002EC7000000000001 /* SensorHealthTests.swift */,`.
App Sources phase `56AF11112BDED05900887073` files: add `56SHEA012EC7000000000001 /* SensorHealth.swift in Sources */,`.
Test Sources phase `56AF11242BDED05B00887073` files: add `56SHTS012EC7000000000001 /* SensorHealthTests.swift in Sources */,`.

- [ ] **Step 3: Run to verify failure**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/SensorHealthTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: build error `cannot find 'SensorHealth' in scope` (the file reference points at a missing file; create it empty first if xcodebuild complains about the missing path).

- [ ] **Step 4: Implement**

Create `GrowGuard/Core/SensorHealth.swift`:

```swift
//
//  SensorHealth.swift
//  GrowGuard
//
//  Pure verdict for one sensor (spec docs/superpowers/specs/2026-09-14-sensor-health-design.md).
//  No BLE, no Core Data: a DTO plus its peers go in, a state comes out.
//

import Foundation

enum SensorHealth: Equatable {
    case ok
    /// Battery never read from this sensor
    case batteryUnknown
    case batteryLow(percent: Int)
    case batteryCritical(percent: Int)
    /// No reading for `unreachableAfter` AND `unreachableAttempts` failed
    /// contacts. `confirmedByPeer` is true when another sensor at the same
    /// location delivered a reading inside the window — the phone was in
    /// range, this sensor is dead. Otherwise it may just be out of range.
    case unreachable(since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool)

    // MARK: - Thresholds (the only place they live)

    static let unreachableAfter: TimeInterval = 48 * 60 * 60
    static let unreachableAttempts: Int16 = 3
    /// Percentages are an assumption: the reported failure was at 25 % and
    /// FlowerCare units with weak cells stop responding in the 20–30 % band.
    static let lowBattery = 30
    static let criticalBattery = 15
    /// Views caption the battery with its age beyond this
    static let staleBatteryAfter: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Evaluation

    /// `peers` are the other devices; only sensors at the same location act
    /// as witnesses. `nil` location matches only `nil`.
    static func evaluate(_ device: FlowerDeviceDTO, peers: [FlowerDeviceDTO], now: Date) -> SensorHealth {
        guard device.isSensor else { return .ok }

        let silentFor = now.timeIntervalSince(device.lastReading)
        if silentFor >= unreachableAfter && device.failedContactAttempts >= unreachableAttempts {
            let witnessed = peers.contains { peer in
                peer.isSensor
                    && peer.uuid != device.uuid
                    && peer.location == device.location
                    && now.timeIntervalSince(peer.lastReading) < unreachableAfter
            }
            let lastKnown = device.batteryReadAt == nil ? nil : Int(device.battery)
            return .unreachable(since: device.lastReading, lastKnownBattery: lastKnown, confirmedByPeer: witnessed)
        }

        guard device.batteryReadAt != nil else { return .batteryUnknown }
        let percent = Int(device.battery)
        if percent <= criticalBattery { return .batteryCritical(percent: percent) }
        if percent <= lowBattery { return .batteryLow(percent: percent) }
        return .ok
    }

    // MARK: - Helpers

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    var isLowBattery: Bool {
        switch self {
        case .batteryLow, .batteryCritical: return true
        default: return false
        }
    }

    /// Whole days since `since`, floored. Used in copy ("silent for 3 days").
    static func daysSilent(since: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(since) / (24 * 60 * 60)))
    }
}
```

- [ ] **Step 5: Run to verify pass**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/Core/SensorHealth.swift GrowGuardTests/SensorHealthTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add SensorHealth verdict with peer-witness rule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `ConnectionPoolManager.deviceEventsPublisher`

**Files:**
- Modify: `GrowGuard/BLE/ConnectionPoolManager.swift` (properties ~line 92, `getConnection` line 138, `handleAttemptFailure` line 245)
- Modify: `GrowGuardTests/BLE/ConnectionPoolManagerTests.swift` (append tests)

**Interfaces:**
- Produces:
  ```swift
  enum DeviceEvent: Equatable {
      case deviceInfo(uuid: String, info: DeviceConnection.DeviceInfo)
      case sensorData(uuid: String)
      case historicalData(uuid: String)
      case attemptGaveUp(uuid: String)
  }
  var ConnectionPoolManager.deviceEventsPublisher: AnyPublisher<DeviceEvent, Never>
  ```

- [ ] **Step 1: Write the failing tests**

Append inside `struct ConnectionPoolManagerTests` in `GrowGuardTests/BLE/ConnectionPoolManagerTests.swift` (before the closing brace):

```swift
    // MARK: - Device events (sensor health seam)

    @Test("deviceEventsPublisher relays battery/firmware and live data tagged with the UUID")
    func deviceEventsRelayInfoAndData() async {
        let pool = makePool()
        let sensor = makeSensor()
        let uuid = sensor.identifier.uuidString
        var events: [DeviceEvent] = []
        let subscription = pool.deviceEventsPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        pool.connect(to: uuid, autoStartHistoryFlow: false)
        await pump()
        scheduler.advance(by: 0.5)
        await pump()

        #expect(events.contains(.deviceInfo(uuid: uuid, info: .init(battery: 80, firmware: "3.2.9"))),
                "FakeFlowerCarePeripheral answers the firmware read with 80 % / 3.2.9")

        pool.getConnection(for: uuid).requestLiveData()
        scheduler.advance(by: 0.5)
        await pump()

        #expect(events.contains(.sensorData(uuid: uuid)))
        #expect(!events.contains(.attemptGaveUp(uuid: uuid)))
    }

    @Test("deviceEventsPublisher emits attemptGaveUp when the reconnect policy gives up")
    func deviceEventsGiveUp() async {
        let pool = makePool()
        let sensor = makeSensor()
        let uuid = sensor.identifier.uuidString
        central.connectSucceeds = false   // connect requests never complete → watchdog timeouts
        var events: [DeviceEvent] = []
        let subscription = pool.deviceEventsPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        pool.connect(to: uuid, autoStartHistoryFlow: false)
        for _ in 0..<40 {                 // 10 s timeout + backoff per attempt, 3 attempts
            await pump()
            scheduler.advance(by: 5)
        }
        await pump()

        #expect(events.filter { $0 == .attemptGaveUp(uuid: uuid) }.count == 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/ConnectionPoolManagerTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `cannot find type 'DeviceEvent' in scope`.

- [ ] **Step 3: Implement**

In `GrowGuard/BLE/ConnectionPoolManager.swift`, above `@MainActor class ConnectionPoolManager` add:

```swift
/// Pool-wide, UUID-tagged view of what the connections report. Consumed by
/// SensorHealthMonitor (spec 2026-09-14-sensor-health-design.md). Payload-
/// free cases carry only the UUID: the monitor needs "contact happened",
/// not the reading.
enum DeviceEvent: Equatable {
    case deviceInfo(uuid: String, info: DeviceConnection.DeviceInfo)
    case sensorData(uuid: String)
    case historicalData(uuid: String)
    /// A connect attempt exhausted the reconnect policy without a connection
    case attemptGaveUp(uuid: String)
}
```

Inside the class, after the `armedConnectionPublisher` computed property, add:

```swift
    // MARK: - Device events (sensor health seam)

    private let deviceEventsSubject = PassthroughSubject<DeviceEvent, Never>()
    private var deviceEventSubscriptions: [String: Set<AnyCancellable>] = [:]
    var deviceEventsPublisher: AnyPublisher<DeviceEvent, Never> {
        deviceEventsSubject.eraseToAnyPublisher()
    }

    /// Merges one connection's publishers into the pool-wide stream. Called
    /// once per connection, at creation.
    private func forwardDeviceEvents(from connection: DeviceConnection, uuid: String) {
        var subscriptions = Set<AnyCancellable>()
        connection.deviceInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.deviceEventsSubject.send(.deviceInfo(uuid: uuid, info: info)) }
            .store(in: &subscriptions)
        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.deviceEventsSubject.send(.sensorData(uuid: uuid)) }
            .store(in: &subscriptions)
        connection.historicalDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.deviceEventsSubject.send(.historicalData(uuid: uuid)) }
            .store(in: &subscriptions)
        deviceEventSubscriptions[uuid] = subscriptions
    }
```

In `getConnection(for:)`, after `connections[deviceUUID] = newConnection` add:

```swift
        forwardDeviceEvents(from: newConnection, uuid: deviceUUID)
```

In `handleAttemptFailure`, inside `case .giveUp:` after the `AppLogger.ble.bleError("⛔️ Max retries reached ...")` line add:

```swift
            deviceEventsSubject.send(.attemptGaveUp(uuid: deviceUUID))
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`. If `deviceEventsGiveUp` never sees the event, print `events` and increase the loop count — the reconnect backoff is defined in `ReconnectPolicy.delay(attempt:reason:)`; the loop must cover `3 × (10 s timeout + delay)`.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/BLE/ConnectionPoolManager.swift GrowGuardTests/BLE/ConnectionPoolManagerTests.swift
git commit -m "Expose a pool-wide device event stream for the sensor health monitor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Strings and the two notifications

**Files:**
- Modify: `GrowGuard/Strings/Localizable.strings` (append section)
- Regenerate: `GrowGuard/Strings/Strings+Generated.swift` via `swiftgen`
- Modify: `GrowGuard/Core/NotificationService.swift` (append extension)

**Interfaces:**
- Produces:
  ```swift
  protocol SensorHealthNotifying {
      func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async
      func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async
  }
  extension NotificationService: SensorHealthNotifying
  ```
- Produces `L10n.SensorHealth.*` and `L10n.Device.location`, `L10n.Device.locationFooter` (used in Tasks 8 and 9).

- [ ] **Step 1: Add the strings**

Append to `GrowGuard/Strings/Localizable.strings`:

```
/* Sensor Health */
"sensorHealth.notification.unreachable.title" = "🔋 %@ is not responding";
"sensorHealth.notification.unreachable.body" = "No readings for %d days. Were you near it? If so, check the battery.";
"sensorHealth.notification.unreachable.bodyLocation" = "No readings from %@ for %d days. Were you near it? If so, check the battery.";
"sensorHealth.notification.confirmed.title" = "🔋 %@ needs a new battery";
"sensorHealth.notification.confirmed.body" = "Your other sensors respond, this one has been silent for %d days.";
"sensorHealth.notification.confirmed.bodyLocation" = "Your other sensors at %@ respond, this one has been silent for %d days.";
"sensorHealth.notification.lastKnown" = " Last known level %d %%.";
"sensorHealth.notification.lowBattery.title" = "🔋 Replace the battery in %@";
"sensorHealth.notification.lowBattery.body" = "Battery is at %d %%. Cheap coin cells drop out without warning at this level.";
"sensorHealth.battery.unknown" = "–";
"sensorHealth.battery.readAgo" = "read %@";
"sensorHealth.banner.unconfirmed.title" = "Not responding for %d days";
"sensorHealth.banner.unconfirmed.text" = "If you are at home, check the battery.";
"sensorHealth.banner.unconfirmed.textLocation" = "Were you near %@? If so, check the battery.";
"sensorHealth.banner.confirmed.title" = "Silent for %d days · replace battery";
"sensorHealth.banner.confirmed.text" = "Your other sensors respond, this one does not.";
"sensorHealth.banner.confirmed.textLocation" = "Your other sensors at %@ respond, this one does not.";
"sensorHealth.banner.lastKnown" = "Last known battery %d %%";
"sensorHealth.banner.setLocation" = "Tell the app where this sensor is";
"device.location" = "Location";
"device.locationFooter" = "Sensors at the same location are within Bluetooth range of each other. Two floors are two locations.";
```

- [ ] **Step 2: Regenerate**

Run from the repo root:
```bash
swiftgen
```
Expected: `Strings+Generated.swift` now contains `internal enum SensorHealth` with nested `Notification`, `Battery`, `Banner` enums, e.g. `L10n.SensorHealth.Notification.Unreachable.title(_ p1: Any)`, `L10n.SensorHealth.Notification.Unreachable.bodyLocation(_ p1: Any, _ p2: Int)`, `L10n.SensorHealth.Notification.lastKnown(_ p1: Int)`, `L10n.SensorHealth.Banner.Confirmed.title(_ p1: Int)`, `L10n.SensorHealth.Battery.readAgo(_ p1: Any)`, `L10n.Device.location`, `L10n.Device.locationFooter`. Verify with:
```bash
grep -n "enum SensorHealth\|func readAgo\|static let location" GrowGuard/Strings/Strings+Generated.swift
```

- [ ] **Step 3: Add the notifier protocol and implementation**

Append to `GrowGuard/Core/NotificationService.swift`:

```swift

// MARK: - Sensor health (spec 2026-09-14-sensor-health-design.md)

/// Seam for SensorHealthMonitor; tests record calls instead of touching
/// UNUserNotificationCenter.
protocol SensorHealthNotifying {
    func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async
    func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async
}

extension NotificationService: SensorHealthNotifying {

    private enum SensorHealthIdentifier {
        // Identifiers contain the UUID so cancelNotifications(for:) sweeps them
        static func unreachable(for uuid: String) -> String { "sensor-unreachable-\(uuid)" }
        static func lowBattery(for uuid: String) -> String { "sensor-battery-\(uuid)" }
    }

    func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async {
        let days = SensorHealth.daysSilent(since: since, now: now)
        let content = UNMutableNotificationContent()
        var body: String
        if confirmedByPeer {
            content.title = L10n.SensorHealth.Notification.Confirmed.title(device.name)
            body = device.location.map { L10n.SensorHealth.Notification.Confirmed.bodyLocation($0, days) }
                ?? L10n.SensorHealth.Notification.Confirmed.body(days)
        } else {
            content.title = L10n.SensorHealth.Notification.Unreachable.title(device.name)
            body = device.location.map { L10n.SensorHealth.Notification.Unreachable.bodyLocation($0, days) }
                ?? L10n.SensorHealth.Notification.Unreachable.body(days)
        }
        if let lastKnownBattery {
            body += L10n.SensorHealth.Notification.lastKnown(lastKnownBattery)
        }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 0.8
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": confirmedByPeer ? "sensorUnreachableConfirmed" : "sensorUnreachable"
        ]

        let identifier = SensorHealthIdentifier.unreachable(for: device.uuid)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            print("📱 NotificationService: Sent unreachable notification (confirmed: \(confirmedByPeer)) for \(device.name)")
        } catch {
            print("❌ NotificationService: Failed to send unreachable notification: \(error)")
        }
    }

    func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.SensorHealth.Notification.LowBattery.title(device.name)
        content.body = L10n.SensorHealth.Notification.LowBattery.body(percent)
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 0.6
        content.userInfo = [
            "deviceUUID": device.uuid,
            "notificationType": "sensorLowBattery"
        ]

        let identifier = SensorHealthIdentifier.lowBattery(for: device.uuid)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            print("📱 NotificationService: Sent low battery notification (\(percent) %) for \(device.name)")
        } catch {
            print("❌ NotificationService: Failed to send low battery notification: \(error)")
        }
    }
}
```

`center` is `private let center: UNUserNotificationCenter` in the same file, so the extension in the same file can use it.

- [ ] **Step 4: Build**

Run:
```bash
xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build -quiet 2>&1 | grep -E "error|warning: unused" | head
```
Expected: no `error:` lines. If SwiftGen named a nested enum differently (e.g. `Lowbattery`), read the generated file and adjust the calls — do not edit the generated file by hand.

- [ ] **Step 5: Commit**

```bash
git add GrowGuard/Strings/Localizable.strings GrowGuard/Strings/Strings+Generated.swift GrowGuard/Core/NotificationService.swift
git commit -m "Add sensor health strings and the unreachable/low-battery notifications

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `SensorHealthMonitor`

**Files:**
- Create: `GrowGuard/Services/SensorHealthMonitor.swift`
- Create: `GrowGuardTests/SensorHealthMonitorTests.swift`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DeviceEvent`, `ConnectionPoolManager.deviceEventsPublisher` (Task 4), `SensorHealth` (Task 3), `SensorHealthNotifying` (Task 5), `FlowerDeviceRepository.modifyDevice` (Task 1).
- Produces:
  ```swift
  @MainActor final class SensorHealthMonitor {
      static let shared: SensorHealthMonitor
      static let failureRateLimit: TimeInterval   // 3600
      static let newCellThreshold: Int            // 40
      init(events: AnyPublisher<DeviceEvent, Never>? = nil, repository: FlowerDeviceRepository? = nil, notifier: SensorHealthNotifying? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init)
      func start()
      func handle(_ event: DeviceEvent) async
      func recordSuccessfulContact(_ uuid: String) async
      func recordFailedContact(_ uuid: String) async
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `GrowGuardTests/SensorHealthMonitorTests.swift`:

```swift
//
//  SensorHealthMonitorTests.swift
//  GrowGuardTests
//
//  Battery persistence, contact bookkeeping and once-per-episode
//  notifications (spec 2026-09-14-sensor-health-design.md). Fake repository,
//  fake notifier, injected clock — no BLE, no Core Data.
//

import Testing
import Combine
import Foundation
@testable import GrowGuard

@MainActor
@Suite(.serialized)
struct SensorHealthMonitorTests {

    // MARK: - Fakes

    final class InMemoryFlowerDeviceRepository: FlowerDeviceRepository {
        var devices: [String: FlowerDeviceDTO] = [:]
        func getAllDevices() async throws -> [FlowerDeviceDTO] { Array(devices.values).sorted { $0.uuid < $1.uuid } }
        func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? { devices[uuid] }
        func saveDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device }
        func deleteDevice(uuid: String) async throws { devices[uuid] = nil }
        func updateDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device }
    }

    final class RecordingNotifier: SensorHealthNotifying {
        struct Unreachable: Equatable { let uuid: String; let confirmed: Bool; let lastKnownBattery: Int? }
        var unreachable: [Unreachable] = []
        var lowBattery: [(uuid: String, percent: Int)] = []
        func notifyUnreachable(device: FlowerDeviceDTO, since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool, now: Date) async {
            unreachable.append(.init(uuid: device.uuid, confirmed: confirmedByPeer, lastKnownBattery: lastKnownBattery))
        }
        func notifyLowBattery(device: FlowerDeviceDTO, percent: Int) async {
            lowBattery.append((device.uuid, percent))
        }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    let repository = InMemoryFlowerDeviceRepository()
    let notifier = RecordingNotifier()
    let clock = Clock()
    let events = PassthroughSubject<DeviceEvent, Never>()
    let defaults = UserDefaults(suiteName: "SensorHealthMonitorTests-\(UUID().uuidString)")!
    let hour: TimeInterval = 3600

    private func makeMonitor() -> SensorHealthMonitor {
        SensorHealthMonitor(events: events.eraseToAnyPublisher(),
                            repository: repository,
                            notifier: notifier,
                            defaults: defaults,
                            now: { [clock] in clock.now })
    }

    /// Sensor whose last reading is `silentFor` seconds before the clock
    private func seed(_ uuid: String,
                      battery: Int16 = 80,
                      batteryUpdatedAt: Date? = nil,
                      silentFor: TimeInterval = 0,
                      attempts: Int16 = 0,
                      lastFailedAt: Date? = nil,
                      location: String? = nil) {
        repository.devices[uuid] = FlowerDeviceDTO(
            name: uuid,
            uuid: uuid,
            battery: battery,
            batteryUpdatedAt: batteryUpdatedAt ?? clock.now.addingTimeInterval(-silentFor),
            lastUpdate: clock.now.addingTimeInterval(-silentFor),
            failedContactAttempts: attempts,
            lastFailedContactAt: lastFailedAt,
            location: location
        )
    }

    // MARK: - Battery persistence

    @Test("deviceInfo persists battery, firmware and batteryUpdatedAt, leaves lastUpdate alone")
    func deviceInfoPersistsBattery() async {
        seed("A", battery: 80, silentFor: 5 * hour)
        let lastUpdateBefore = repository.devices["A"]!.lastUpdate
        let monitor = makeMonitor()

        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 42, firmware: "3.3.6")))

        let stored = repository.devices["A"]!
        #expect(stored.battery == 42)
        #expect(stored.firmware == "3.3.6")
        #expect(stored.batteryUpdatedAt == clock.now)
        #expect(stored.lastUpdate == lastUpdateBefore)
    }

    @Test("deviceInfo for an unknown device is ignored")
    func deviceInfoUnknownDevice() async {
        let monitor = makeMonitor()
        await monitor.handle(.deviceInfo(uuid: "GHOST", info: .init(battery: 42, firmware: "x")))
        #expect(repository.devices.isEmpty)
        #expect(notifier.lowBattery.isEmpty)
    }

    // MARK: - Contact bookkeeping

    @Test("sensorData resets failed attempts and clears the unreachable marker")
    func successResetsAttempts() async {
        seed("A", silentFor: 3 * 24 * hour, attempts: 5, lastFailedAt: clock.now.addingTimeInterval(-hour))
        defaults.set("unconfirmed", forKey: "sensorHealth.unreachableNotified.A")
        let monitor = makeMonitor()

        await monitor.handle(.sensorData(uuid: "A"))

        #expect(repository.devices["A"]!.failedContactAttempts == 0)
        #expect(repository.devices["A"]!.lastFailedContactAt == nil)
        #expect(defaults.string(forKey: "sensorHealth.unreachableNotified.A") == nil)
    }

    @Test("historicalData counts as a successful contact too")
    func historicalDataIsSuccess() async {
        seed("A", attempts: 2)
        let monitor = makeMonitor()
        await monitor.handle(.historicalData(uuid: "A"))
        #expect(repository.devices["A"]!.failedContactAttempts == 0)
    }

    @Test("Failures 10 min apart count once; 61 min apart count twice")
    func failureRateLimit() async {
        seed("A")
        let monitor = makeMonitor()

        await monitor.recordFailedContact("A")
        clock.advance(10 * 60)
        await monitor.recordFailedContact("A")
        #expect(repository.devices["A"]!.failedContactAttempts == 1)

        clock.advance(51 * 60)
        await monitor.recordFailedContact("A")
        #expect(repository.devices["A"]!.failedContactAttempts == 2)
        #expect(repository.devices["A"]!.lastFailedContactAt == clock.now)
    }

    @Test("attemptGaveUp event records a failed contact")
    func gaveUpEventIsFailure() async {
        seed("A")
        let monitor = makeMonitor()
        await monitor.handle(.attemptGaveUp(uuid: "A"))
        #expect(repository.devices["A"]!.failedContactAttempts == 1)
    }

    // MARK: - Unreachable notifications

    @Test("Crossing into unreachable notifies once; a further failure does not")
    func unreachableNotifiesOnce() async {
        seed("A", battery: 25, silentFor: 3 * 24 * hour, attempts: 2)
        let monitor = makeMonitor()

        await monitor.recordFailedContact("A")
        #expect(notifier.unreachable == [.init(uuid: "A", confirmed: false, lastKnownBattery: 25)])

        clock.advance(2 * hour)
        await monitor.recordFailedContact("A")
        #expect(notifier.unreachable.count == 1)
        #expect(defaults.string(forKey: "sensorHealth.unreachableNotified.A") == "unconfirmed")
    }

    @Test("Success then another crossing notifies again")
    func newEpisodeNotifiesAgain() async {
        seed("A", silentFor: 3 * 24 * hour, attempts: 2)
        let monitor = makeMonitor()
        await monitor.recordFailedContact("A")
        #expect(notifier.unreachable.count == 1)

        // Sensor answers → episode over
        await monitor.handle(.sensorData(uuid: "A"))
        // …but lastReading in the fake stays old (no sample saved); simulate
        // the reading by moving lastUpdate to now, then go silent again
        repository.devices["A"]!.lastUpdate = clock.now
        clock.advance(3 * 24 * hour)
        for _ in 0..<3 {
            await monitor.recordFailedContact("A")
            clock.advance(2 * hour)
        }
        #expect(notifier.unreachable.count == 2)
    }

    @Test("An unconfirmed episode upgrades to confirmed exactly once when a peer answers")
    func upgradeToConfirmedOnce() async {
        seed("A", silentFor: 3 * 24 * hour, attempts: 2)
        seed("B", silentFor: 3 * 24 * hour, attempts: 0)
        let monitor = makeMonitor()

        await monitor.recordFailedContact("A")
        #expect(notifier.unreachable == [.init(uuid: "A", confirmed: false, lastKnownBattery: 80)])

        // B delivers a reading: it becomes A's witness
        repository.devices["B"]!.lastUpdate = clock.now
        await monitor.handle(.sensorData(uuid: "B"))
        #expect(notifier.unreachable == [
            .init(uuid: "A", confirmed: false, lastKnownBattery: 80),
            .init(uuid: "A", confirmed: true, lastKnownBattery: 80)
        ])
        #expect(defaults.string(forKey: "sensorHealth.unreachableNotified.A") == "confirmed")

        // B delivers again → no third notification for A
        await monitor.handle(.sensorData(uuid: "B"))
        #expect(notifier.unreachable.count == 2)
    }

    @Test("A confirmed episode never downgrades or re-notifies when the peer goes silent")
    func noDowngrade() async {
        seed("A", silentFor: 3 * 24 * hour, attempts: 3)
        seed("B", silentFor: hour)
        defaults.set("confirmed", forKey: "sensorHealth.unreachableNotified.A")
        let monitor = makeMonitor()

        repository.devices["B"]!.lastUpdate = clock.now.addingTimeInterval(-3 * 24 * hour)
        clock.advance(2 * hour)
        await monitor.recordFailedContact("A")

        #expect(notifier.unreachable.isEmpty)
        #expect(defaults.string(forKey: "sensorHealth.unreachableNotified.A") == "confirmed")
    }

    @Test("Peer witness respects location")
    func witnessRespectsLocation() async {
        seed("A", silentFor: 3 * 24 * hour, attempts: 2, location: "Balcony")
        seed("B", silentFor: 0, location: "Living room")
        let monitor = makeMonitor()

        await monitor.recordFailedContact("A")
        #expect(notifier.unreachable == [.init(uuid: "A", confirmed: false, lastKnownBattery: 80)])
    }

    // MARK: - Low battery notifications

    @Test("Low battery notifies once at 30 %, not again at 28 %, again after a new cell drops to 29 %")
    func lowBatteryOncePerCell() async {
        seed("A", battery: 80)
        let monitor = makeMonitor()

        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 30, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30])

        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 28, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30])

        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 95, firmware: "f")))
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 29, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30, 29])
    }

    @Test("Critical battery is a low-battery notification as well")
    func criticalNotifies() async {
        seed("A", battery: 80)
        let monitor = makeMonitor()
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 9, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [9])
    }

    // MARK: - Subscription

    @Test("start() subscribes to the event stream")
    func startSubscribes() async {
        seed("A", attempts: 2)
        let monitor = makeMonitor()
        monitor.start()

        events.send(.sensorData(uuid: "A"))
        await drainMainActor()
        await drainMainActor()

        #expect(repository.devices["A"]!.failedContactAttempts == 0)
    }
}
```

- [ ] **Step 2: Register both files in the pbxproj**

PBXBuildFile section:
```
		56SHMO012EC7000000000001 /* SensorHealthMonitor.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHMO002EC7000000000001 /* SensorHealthMonitor.swift */; };
		56SHMT012EC7000000000001 /* SensorHealthMonitorTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHMT002EC7000000000001 /* SensorHealthMonitorTests.swift */; };
```
PBXFileReference section:
```
		56SHMO002EC7000000000001 /* SensorHealthMonitor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SensorHealthMonitor.swift; sourceTree = "<group>"; };
		56SHMT002EC7000000000001 /* SensorHealthMonitorTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SensorHealthMonitorTests.swift; sourceTree = "<group>"; };
```
Services group children: `56SHMO002EC7000000000001 /* SensorHealthMonitor.swift */,`. Test root group children: `56SHMT002EC7000000000001 /* SensorHealthMonitorTests.swift */,`. App Sources phase: `56SHMO012EC7000000000001 /* SensorHealthMonitor.swift in Sources */,`. Test Sources phase: `56SHMT012EC7000000000001 /* SensorHealthMonitorTests.swift in Sources */,`.

- [ ] **Step 3: Run to verify failure**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/SensorHealthMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `cannot find 'SensorHealthMonitor' in scope`.

- [ ] **Step 4: Implement**

Create `GrowGuard/Services/SensorHealthMonitor.swift`:

```swift
//
//  SensorHealthMonitor.swift
//  GrowGuard
//
//  Owns battery persistence, failed-contact bookkeeping and the once-per-
//  episode sensor health notifications (spec
//  docs/superpowers/specs/2026-09-14-sensor-health-design.md). Listens to the
//  pool-wide DeviceEvent stream so background wakes count as much as an open
//  detail screen. No CoreBluetooth in here.
//

import Foundation
import Combine

@MainActor
final class SensorHealthMonitor {

    static let shared = SensorHealthMonitor()

    /// Failures closer together than this count once. Background triggers
    /// (push, BGAppRefresh, enter-background) can fire minutes apart.
    static let failureRateLimit: TimeInterval = 60 * 60
    /// A battery read above this clears the low-battery marker: new cell.
    static let newCellThreshold = 40

    // MARK: - Dependencies (tests inject)

    private let events: AnyPublisher<DeviceEvent, Never>
    private let repository: FlowerDeviceRepository
    private let notifier: SensorHealthNotifying
    private let defaults: UserDefaults
    private let now: () -> Date
    private var subscription: AnyCancellable?

    private enum DefaultsKey {
        static func unreachableNotified(for uuid: String) -> String { "sensorHealth.unreachableNotified.\(uuid)" }
        static func lowBatteryNotified(for uuid: String) -> String { "sensorHealth.lowBatteryNotified.\(uuid)" }
    }

    private enum UnreachableFlavour: String {
        case unconfirmed, confirmed
    }

    init(events: AnyPublisher<DeviceEvent, Never>? = nil,
         repository: FlowerDeviceRepository? = nil,
         notifier: SensorHealthNotifying? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.events = events ?? ConnectionPoolManager.shared.deviceEventsPublisher
        self.repository = repository ?? RepositoryManager.shared.flowerDeviceRepository
        self.notifier = notifier ?? NotificationService.shared
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Lifecycle

    /// Call once from didFinishLaunching, after the pool exists
    func start() {
        guard subscription == nil else { return }
        subscription = events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                Task { @MainActor in await self?.handle(event) }
            }
    }

    // MARK: - Events

    func handle(_ event: DeviceEvent) async {
        switch event {
        case .deviceInfo(let uuid, let info):
            await persistBattery(uuid: uuid, battery: info.battery, firmware: info.firmware)
        case .sensorData(let uuid), .historicalData(let uuid):
            await recordSuccessfulContact(uuid)
        case .attemptGaveUp(let uuid):
            await recordFailedContact(uuid)
        }
    }

    /// Any received reading ends the silence: counter to 0, marker cleared.
    /// Also re-evaluates every other sensor — this device may be the witness
    /// that upgrades a neighbour's verdict from unconfirmed to confirmed.
    func recordSuccessfulContact(_ uuid: String) async {
        do {
            guard try await repository.modifyDevice(uuid: uuid, { device in
                device.failedContactAttempts = 0
                device.lastFailedContactAt = nil
            }) != nil else { return }
            defaults.removeObject(forKey: DefaultsKey.unreachableNotified(for: uuid))

            let others = try await repository.getAllDevices().filter { $0.uuid != uuid && $0.isSensor }
            for other in others {
                await evaluateAndNotify(uuid: other.uuid)
            }
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to record contact for \(uuid): \(error.localizedDescription)")
        }
    }

    /// A contact attempt ended without a reading. Rate-limited to one per
    /// `failureRateLimit` so a burst of triggers cannot exhaust the attempt
    /// gate in an evening.
    func recordFailedContact(_ uuid: String) async {
        let now = self.now()
        do {
            var counted = false
            let updated = try await repository.modifyDevice(uuid: uuid) { device in
                if let last = device.lastFailedContactAt, now.timeIntervalSince(last) < Self.failureRateLimit {
                    return
                }
                device.failedContactAttempts += 1
                device.lastFailedContactAt = now
                counted = true
            }
            guard let updated, counted else { return }
            AppLogger.sensor.info("🔋 \(updated.name): failed contact #\(updated.failedContactAttempts) (silent \(SensorHealth.daysSilent(since: updated.lastReading, now: now)) d)")
            await evaluateAndNotify(uuid: uuid)
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to record failure for \(uuid): \(error.localizedDescription)")
        }
    }

    // MARK: - Battery

    private func persistBattery(uuid: String, battery: Int, firmware: String) async {
        let now = self.now()
        do {
            guard let updated = try await repository.modifyDevice(uuid: uuid, { device in
                device.battery = Int16(clamping: battery)
                device.firmware = firmware
                device.batteryUpdatedAt = now
                // lastUpdate untouched: a battery read is not a measurement
            }) else { return }
            AppLogger.sensor.info("🔋 \(updated.name): battery \(battery) %, firmware \(firmware) persisted")

            if battery > Self.newCellThreshold {
                defaults.removeObject(forKey: DefaultsKey.lowBatteryNotified(for: uuid))
            }
            await evaluateAndNotify(uuid: uuid)
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to persist battery for \(uuid): \(error.localizedDescription)")
        }
    }

    // MARK: - Verdict → notification

    private func evaluateAndNotify(uuid: String) async {
        let now = self.now()
        let all: [FlowerDeviceDTO]
        do {
            all = try await repository.getAllDevices()
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to load devices: \(error.localizedDescription)")
            return
        }
        guard let device = all.first(where: { $0.uuid == uuid }) else { return }
        let peers = all.filter { $0.uuid != uuid }
        let health = SensorHealth.evaluate(device, peers: peers, now: now)

        switch health {
        case .unreachable(let since, let lastKnownBattery, let confirmedByPeer):
            let key = DefaultsKey.unreachableNotified(for: uuid)
            let prior = defaults.string(forKey: key).flatMap(UnreachableFlavour.init(rawValue:))
            let flavour: UnreachableFlavour = confirmedByPeer ? .confirmed : .unconfirmed
            // Notify on the first crossing, and once more on the upgrade
            // unconfirmed → confirmed. Never on a downgrade, never twice.
            let shouldNotify = prior == nil || (prior == .unconfirmed && flavour == .confirmed)
            guard shouldNotify else { return }
            AppLogger.sensor.warning("🔋 \(device.name): unreachable (\(flavour.rawValue)), \(device.failedContactAttempts) attempts, silent \(SensorHealth.daysSilent(since: since, now: now)) d, battery \(lastKnownBattery.map(String.init) ?? "unknown")")
            await notifier.notifyUnreachable(device: device, since: since, lastKnownBattery: lastKnownBattery, confirmedByPeer: confirmedByPeer, now: now)
            defaults.set(flavour.rawValue, forKey: key)

        case .batteryLow(let percent), .batteryCritical(let percent):
            let key = DefaultsKey.lowBatteryNotified(for: uuid)
            guard !defaults.bool(forKey: key) else { return }
            AppLogger.sensor.warning("🔋 \(device.name): battery low (\(percent) %)")
            await notifier.notifyLowBattery(device: device, percent: percent)
            defaults.set(true, forKey: key)

        case .ok, .batteryUnknown:
            break
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Same command as Step 3. Expected: `** TEST SUCCEEDED **`. `newEpisodeNotifiesAgain` depends on the fake keeping `lastUpdate` old until the test moves it; if it fails, check that `recordSuccessfulContact` does **not** touch `lastUpdate` (it must not).

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/Services/SensorHealthMonitor.swift GrowGuardTests/SensorHealthMonitorTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add SensorHealthMonitor: persist battery, count contacts, notify per episode

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Wire the monitor in — app start, wake-service hooks, detail view model

**Files:**
- Modify: `GrowGuard/AppDelegate.swift:25`
- Modify: `GrowGuard/Services/BackgroundBLEWakeService.swift` (dependencies, `init`, `armAll`, `finishRead`)
- Modify: `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift`
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift` (`init`, deviceInfo subscription ~line 151, delete `updateDeviceInfo` ~line 431)

**Interfaces:**
- Consumes: `SensorHealthMonitor.shared.start()`, `.recordFailedContact(_:)` (Task 6); `SensorHealth.evaluate` (Task 3).
- Produces: `BackgroundBLEWakeService.init(..., recordFailedContact: ((String) async -> Void)? = nil, ...)`; `DeviceDetailsViewModel.peers: [FlowerDeviceDTO]`, `DeviceDetailsViewModel.health: SensorHealth`.

- [ ] **Step 1: Write the failing wake-service tests**

In `GrowGuardTests/BLE/BackgroundWakeServiceTests.swift`:

Add `var failedContacts: [String] = []` to `final class Recorder`.

In `makeService`, add the argument after `runStatusCheck:`:
```swift
            recordFailedContact: { uuid in recorder.failedContacts.append(uuid) },
```

Append these tests before the struct's closing brace:

```swift
    @Test("A device still armed from the previous trigger counts one failed contact on the next armAll")
    func stillArmedCountsFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.peripheralsAreInRetrieveCache = false   // never advertises: no connect, stays armed
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts.isEmpty, "First trigger: nothing to judge yet")
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString))

        await service.armAll(source: .backgroundPush)
        await pump()
        #expect(recorder.failedContacts == [sensor.identifier.uuidString])
        #expect(pool.isBackgroundArmed(sensor.identifier.uuidString), "Re-armed as before")
    }

    @Test("A wake read that ends without data counts one failed contact")
    func failedWakeReadCountsFailedContact() async {
        let pool = makePool()
        let sensor = makeSensor()
        central.connectSucceeds = false
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundTask)
        await pump()
        central.simulateConnectCompletion(of: sensor.identifier)
        await pump()
        central.simulateDisconnect(of: sensor.identifier, error: nil)
        await settle(seconds: 1.0)

        #expect(recorder.failedContacts == [sensor.identifier.uuidString])
    }

    @Test("A successful wake read records no failed contact")
    func successfulWakeReadNoFailure() async {
        let pool = makePool()
        let sensor = makeSensor()
        let service = makeService(pool: pool, deviceUUIDs: [sensor.identifier.uuidString])

        await service.armAll(source: .backgroundPush)
        await settle(seconds: 2.0)

        #expect(recorder.saved.count == 1)
        #expect(recorder.failedContacts.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/BackgroundWakeServiceTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `extra argument 'recordFailedContact' in call`.

- [ ] **Step 3: Wake-service hooks**

In `GrowGuard/Services/BackgroundBLEWakeService.swift`:

Add a dependency after `runStatusCheck`:
```swift
    /// Sensor health bookkeeping: a contact attempt ended without a reading
    private let recordFailedContact: (String) async -> Void
```

Add the init parameter after `runStatusCheck:` and its default:
```swift
         recordFailedContact: ((String) async -> Void)? = nil,
```
```swift
        self.recordFailedContact = recordFailedContact ?? { uuid in
            await SensorHealthMonitor.shared.recordFailedContact(uuid)
        }
```

Replace the body of `armAll(source:)` with:
```swift
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("🛡 Background arm: \(uuids.count) sensor(s), source \(source.rawValue)")
        for uuid in uuids {
            // Still armed from the previous trigger = the sensor never woke us.
            // A dead (non-advertising) sensor produces no CoreBluetooth
            // callback at all; this is the only place that silence is visible.
            if pool.isBackgroundArmed(uuid) && activeReads[uuid] == nil {
                AppLogger.sensor.info("🔋 \(uuid) still armed from the previous trigger — counting a failed contact")
                await recordFailedContact(uuid)
            }
            armSources[uuid] = source
            pool.armBackgroundConnect(for: uuid)
        }
```

In `finishRead(for:success:)`, replace the `if success { ... }` block with:
```swift
        if success {
            BackgroundTaskTracker.shared.recordRefreshTaskExecution(result: BackgroundFetchResult(
                successfulDevices: [deviceUUID],
                failedDevices: [],
                totalDataPoints: 1,
                duration: 0
            ))
        } else {
            Task { @MainActor in
                await self.recordFailedContact(deviceUUID)
            }
        }
```

- [ ] **Step 4: Run the wake tests**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`. If `failedWakeReadCountsFailedContact` sees an empty list, the `Task` in `finishRead` has not run yet — the test's `settle(seconds: 1.0)` pumps the main actor; add one more `await pump()` before the expectation.

- [ ] **Step 5: Start the monitor at launch**

In `GrowGuard/AppDelegate.swift`, directly after `BackgroundBLEWakeService.shared.start()` (line 25) add:
```swift
        SensorHealthMonitor.shared.start()
```

- [ ] **Step 6: Detail view model: display-only battery, peers, health**

In `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift`:

Add properties after `var device: FlowerDeviceDTO`:
```swift
    /// Other devices; witnesses for the peer rule (loaded in init)
    var peers: [FlowerDeviceDTO] = []
    var health: SensorHealth {
        SensorHealth.evaluate(device, peers: peers, now: Date())
    }
```

In `init(device:)`, inside the existing `Task { try await PlantMonitorService.shared.checkDeviceStatus(device: device) ... }` add at the top of that task:
```swift
            if let all = try? await self.repositoryManager.flowerDeviceRepository.getAllDevices() {
                await MainActor.run { self.peers = all.filter { $0.uuid != device.uuid } }
            }
```

Replace the deviceInfo subscription with:
```swift
        // Batterie/Firmware: nur die Anzeige-Kopie aktualisieren. Persistiert
        // wird pool-weit vom SensorHealthMonitor (Spec 2026-09-14).
        poolDeviceInfoSubscription = connection.deviceInfoPublisher.sink { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                self.device.battery = Int16(clamping: info.battery)
                self.device.firmware = info.firmware
                self.device.batteryUpdatedAt = Date()
            }
        }
```

Delete the whole `updateDeviceInfo(battery:firmware:)` method and its doc comment.

- [ ] **Step 7: Build and run the touched suites**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/BackgroundWakeServiceTests -only-testing:GrowGuardTests/BackgroundArmTests -only-testing:GrowGuardTests/SensorHealthMonitorTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add GrowGuard/AppDelegate.swift GrowGuard/Services/BackgroundBLEWakeService.swift GrowGuardTests/BLE/BackgroundWakeServiceTests.swift GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift
git commit -m "Wire SensorHealthMonitor: launch start, wake-service failure hooks, display-only battery in details

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Battery chip and unreachable banner in the UI

**Files:**
- Create: `GrowGuard/DeviceDetails/Componetns/BatteryIndicator.swift`
- Create: `GrowGuard/DeviceDetails/Componetns/SensorHealthBanner.swift`
- Modify: `GrowGuard/OverviewList/OverviewList.swift` (`ForEach` ~line 126, `DeviceCard` ~line 310-420)
- Modify: `GrowGuard/DeviceDetails/DeviceDetailsView.swift:36-62`
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SensorHealth`, `FlowerDeviceDTO.batteryReadAt`, `L10n.SensorHealth.*` (Task 5), `DeviceDetailsViewModel.health` (Task 7).
- Produces: `BatteryIndicator(device:health:style:)` with `enum Style { case compact, chip }`; `SensorHealthBanner(device:health:style:onSetLocation:)` with `enum Style { case line, banner }`, `onSetLocation: (() -> Void)?`.

- [ ] **Step 1: BatteryIndicator**

Create `GrowGuard/DeviceDetails/Componetns/BatteryIndicator.swift`:

```swift
//
//  BatteryIndicator.swift
//  GrowGuard
//
//  Honest battery chip: symbol and colour by level, "–" when never read,
//  age caption when the read is older than SensorHealth.staleBatteryAfter.
//

import SwiftUI

struct BatteryIndicator: View {
    enum Style {
        /// Overview row: caption-sized, no background
        case compact
        /// Details header: padded chip with tinted background
        case chip
    }

    let device: FlowerDeviceDTO
    let health: SensorHealth
    let style: Style

    private var readAt: Date? { device.batteryReadAt }

    private var isStale: Bool {
        guard let readAt else { return false }
        return Date().timeIntervalSince(readAt) > SensorHealth.staleBatteryAfter
    }

    private var symbolName: String {
        guard readAt != nil else { return "battery.0percent" }
        switch Int(device.battery) {
        case 88...: return "battery.100percent"
        case 63...87: return "battery.75percent"
        case 38...62: return "battery.50percent"
        case 13...37: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var color: Color {
        switch health {
        case .batteryCritical: return .red
        case .batteryLow: return .orange
        case .batteryUnknown: return .secondary
        case .unreachable(_, let lastKnown, _):
            guard let lastKnown else { return .secondary }
            return lastKnown <= SensorHealth.criticalBattery ? .red : (lastKnown <= SensorHealth.lowBattery ? .orange : .green)
        case .ok: return .green
        }
    }

    private var valueText: String {
        readAt == nil ? L10n.SensorHealth.Battery.unknown : "\(Int(device.battery)) %"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: style == .chip ? 6 : 4) {
                Image(systemName: symbolName)
                    .font(style == .chip ? .body : .caption2)
                    .foregroundColor(color)
                Text(valueText)
                    .font(style == .chip ? .subheadline : .caption)
                    .fontWeight(style == .chip ? .medium : .regular)
            }
            if isStale, let readAt {
                Text(L10n.SensorHealth.Battery.readAgo(readAt.formatted(.relative(presentation: .named))))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, style == .chip ? 16 : 0)
        .padding(.vertical, style == .chip ? 10 : 0)
        .background(style == .chip ? color.opacity(0.1) : Color.clear)
        .cornerRadius(style == .chip ? 10 : 0)
    }
}
```

- [ ] **Step 2: SensorHealthBanner**

Create `GrowGuard/DeviceDetails/Componetns/SensorHealthBanner.swift`:

```swift
//
//  SensorHealthBanner.swift
//  GrowGuard
//
//  Unreachable state. `.line` replaces the connection-status line in the
//  overview row; `.banner` is the full-width block in the details header.
//  Renders nothing unless health is .unreachable.
//

import SwiftUI

struct SensorHealthBanner: View {
    enum Style { case line, banner }

    let device: FlowerDeviceDTO
    let health: SensorHealth
    let style: Style
    /// Shown as "Tell the app where this sensor is" when the verdict is
    /// unconfirmed, the device has no location and other sensors exist.
    var onSetLocation: (() -> Void)? = nil

    var body: some View {
        if case .unreachable(let since, let lastKnown, let confirmed) = health {
            let days = SensorHealth.daysSilent(since: since, now: Date())
            switch style {
            case .line:
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(confirmed ? L10n.SensorHealth.Banner.Confirmed.title(days)
                                   : L10n.SensorHealth.Banner.Unconfirmed.title(days))
                        .font(.caption)
                }
                .foregroundColor(.red)

            case .banner:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(confirmed ? L10n.SensorHealth.Banner.Confirmed.title(days)
                                       : L10n.SensorHealth.Banner.Unconfirmed.title(days))
                            .fontWeight(.semibold)
                    }
                    Text(explanation(confirmed: confirmed))
                        .font(.subheadline)
                    if let lastKnown {
                        Text(L10n.SensorHealth.Banner.lastKnown(lastKnown))
                            .font(.caption)
                    }
                    if !confirmed, device.location == nil, let onSetLocation {
                        Button(L10n.SensorHealth.Banner.setLocation, action: onSetLocation)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }

    private func explanation(confirmed: Bool) -> String {
        switch (confirmed, device.location) {
        case (true, let location?): return L10n.SensorHealth.Banner.Confirmed.textLocation(location)
        case (true, nil): return L10n.SensorHealth.Banner.Confirmed.text
        case (false, let location?): return L10n.SensorHealth.Banner.Unconfirmed.textLocation(location)
        case (false, nil): return L10n.SensorHealth.Banner.Unconfirmed.text
        }
    }
}
```

- [ ] **Step 3: Register both files in the pbxproj**

PBXBuildFile section:
```
		56SHBI012EC7000000000001 /* BatteryIndicator.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHBI002EC7000000000001 /* BatteryIndicator.swift */; };
		56SHBN012EC7000000000001 /* SensorHealthBanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHBN002EC7000000000001 /* SensorHealthBanner.swift */; };
```
PBXFileReference section:
```
		56SHBI002EC7000000000001 /* BatteryIndicator.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BatteryIndicator.swift; sourceTree = "<group>"; };
		56SHBN002EC7000000000001 /* SensorHealthBanner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SensorHealthBanner.swift; sourceTree = "<group>"; };
```
`Componetns` group `568892062C83292D000E8FAE` children: add both file references. App Sources phase `56AF11112BDED05900887073`: add both build files.

- [ ] **Step 4: Overview row**

In `GrowGuard/OverviewList/OverviewList.swift`:

In the `ForEach`, pass peers:
```swift
                            ForEach(viewModel.allSavedDevices) { device in
                                DeviceCard(device: device,
                                           peers: viewModel.allSavedDevices.filter { $0.uuid != device.uuid }) {
                                    NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                                }
```

In `struct DeviceCard`, add after `let device: FlowerDeviceDTO`:
```swift
    let peers: [FlowerDeviceDTO]
```
and a computed property after `latestSensorData`:
```swift
    private var health: SensorHealth {
        SensorHealth.evaluate(device, peers: peers, now: Date())
    }
```

Replace the battery `HStack(spacing: 4) { Image(systemName: "battery.75percent") ... Text(device.battery, format: .percent) ... }` with:
```swift
                            BatteryIndicator(device: device, health: health, style: .compact)
                                .foregroundColor(.secondary)
```

Replace the `if isLoadingHistory { ... } else { HStack(spacing: 4) { Circle().fill(connectionColor) ... } }` block with:
```swift
                            if isLoadingHistory {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 6, height: 6)
                                    Text("Loading History...")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            } else if health.isUnreachable {
                                SensorHealthBanner(device: device, health: health, style: .line)
                            } else {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(connectionColor)
                                        .frame(width: 6, height: 6)
                                    Text(connectionLabel)
                                        .font(.caption)
                                        .foregroundColor(connectionColor)
                                }
                            }
```

The `.frame(height: CGFloat(viewModel.allSavedDevices.count) * 110)` on the list assumes a fixed row height; the stale caption adds one line. Change `110` to `124`.

- [ ] **Step 5: Details header**

In `GrowGuard/DeviceDetails/DeviceDetailsView.swift`, replace the `// Battery indicator` `HStack(spacing: 6) { ... }.cornerRadius(10)` block with:
```swift
                            BatteryIndicator(device: viewModel.device, health: viewModel.health, style: .chip)
```

Directly after the "Device name and last update" `VStack(spacing: 8) { ... }` (the one ending with `.frame(maxWidth: .infinity, alignment: .leading)` after the clock row) add:
```swift
                    if viewModel.device.isSensor {
                        SensorHealthBanner(device: viewModel.device,
                                           health: viewModel.health,
                                           style: .banner,
                                           onSetLocation: viewModel.peers.isEmpty ? nil : { showSetting = true })
                    }
```

- [ ] **Step 6: Build**

Run:
```bash
xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build -quiet 2>&1 | grep -E "error" | head
```
Expected: no output.

- [ ] **Step 7: Look at it once**

Run the app on the booted iPhone 17 simulator (`xcodebuild ... build` then `xcrun simctl install booted <path to GrowGuard.app in DerivedData>` and `xcrun simctl launch booted pro.veit.GrowGuard`, or via the `run` skill) and confirm on the overview: a sensor row shows the battery symbol in colour, a device without a battery read shows "–". Nothing else is verifiable without a silent sensor; the unreachable path is covered by the monitor tests.

- [ ] **Step 8: Commit**

```bash
git add GrowGuard/DeviceDetails/Componetns/BatteryIndicator.swift GrowGuard/DeviceDetails/Componetns/SensorHealthBanner.swift GrowGuard/OverviewList/OverviewList.swift GrowGuard/DeviceDetails/DeviceDetailsView.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Show honest battery level and unreachable banner in overview and details

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Location field

**Files:**
- Create: `GrowGuard/DeviceDetails/Componetns/LocationField.swift`
- Modify: `GrowGuard/DeviceDetails/Settings/SettingsView.swift` (`SettingsViewModel` properties, `loadDeviceName`, `saveSettings`, form ~line 577)
- Modify: `GrowGuard/AddDevice/Details/AddDeviceDetails.swift` (view model computed, form ~line 274)
- Modify: `GrowGuard/OverviewList/OverviewList.swift` (name row in `DeviceCard`)
- Modify: `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `FlowerDeviceDTO.location`, `normalizeLocation`, `modifyDevice`, `L10n.Device.location`, `L10n.Device.locationFooter`.
- Produces: `LocationField(location: Binding<String>, suggestions: [String])`; `SettingsViewModel.location: String`, `.existingLocations: [String]`.

- [ ] **Step 1: LocationField**

Create `GrowGuard/DeviceDetails/Componetns/LocationField.swift`:

```swift
//
//  LocationField.swift
//  GrowGuard
//
//  "Location" form section: one text field plus tappable chips with the
//  locations other devices already use. The chips are the whole
//  de-duplication mechanism ("Balcony" vs "balcony").
//

import SwiftUI

struct LocationField: View {
    @Binding var location: String
    let suggestions: [String]

    private var chips: [String] {
        suggestions.filter { $0 != location.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var body: some View {
        Section {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.blue)
                    .frame(width: 30)
                TextField(L10n.Device.location, text: $location)
                    .autocorrectionDisabled()
            }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Button(chip) { location = chip }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.Device.location)
        } footer: {
            Text(L10n.Device.locationFooter)
        }
    }
}
```

Register in the pbxproj — PBXBuildFile:
```
		56SHLF012EC7000000000001 /* LocationField.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56SHLF002EC7000000000001 /* LocationField.swift */; };
```
PBXFileReference:
```
		56SHLF002EC7000000000001 /* LocationField.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LocationField.swift; sourceTree = "<group>"; };
```
`Componetns` group children and app Sources phase: add the respective entries.

- [ ] **Step 2: SettingsViewModel**

In `SettingsViewModel` (inside `SettingsView.swift`) add after `var deviceName: String = ""`:
```swift
    var location: String = ""
    /// Distinct locations of the other devices, for the suggestion chips
    var existingLocations: [String] = []
```

Replace `loadDeviceName()` with:
```swift
    @MainActor
    private func loadDeviceName() async {
        do {
            let all = try await repositoryManager.flowerDeviceRepository.getAllDevices()
            if let device = all.first(where: { $0.uuid == deviceUUID }) {
                self.deviceName = device.name
                self.location = device.location ?? ""
                print("  Loaded Device Name: \(device.name), location: \(device.location ?? "nil")")
            } else {
                print("  Device not found for UUID: \(deviceUUID)")
                self.deviceName = ""
            }
            self.existingLocations = Array(Set(all.filter { $0.uuid != deviceUUID }.compactMap(\.location))).sorted()
        } catch {
            print("❌ SettingsViewModel: Failed to load device name: \(error)")
            self.deviceName = ""
        }
    }
```

In `saveSettings()`, extend the `modifyDevice` closure from Task 2:
```swift
        try await repositoryManager.flowerDeviceRepository.modifyDevice(uuid: deviceUUID) { fresh in
            fresh.name = deviceName
            fresh.selectedFlower = selectedFlower
            fresh.location = FlowerDeviceDTO.normalizeLocation(location)
        }
```

In the form, directly after the `Section(header: Text("Device Name")) { ... }` block add:
```swift
                if isSensor {
                    LocationField(location: $viewModel.location, suggestions: viewModel.existingLocations)
                }
```

- [ ] **Step 3: AddDeviceDetails**

In the add-device view model (the class holding `var flower: FlowerDeviceDTO` and `allSavedDevices`, around line 81) add:
```swift
    var existingLocations: [String] {
        Array(Set(allSavedDevices.compactMap(\.location))).sorted()
    }
```

In `save()`, before `try await repositoryManager.flowerDeviceRepository.saveDevice(flower)` add:
```swift
                flower.location = FlowerDeviceDTO.normalizeLocation(flower.location)
```

In the form, directly after the `Section(header: Text("Device Name")) { ... }` block add:
```swift
                LocationField(location: Binding(
                    get: { viewModel.flower.location ?? "" },
                    set: { viewModel.flower.location = $0 }
                ), suggestions: viewModel.existingLocations)
```

- [ ] **Step 4: Overview caption**

In `DeviceCard` (`OverviewList.swift`), replace
```swift
                    Text(device.name ?? "Unknown Plant")
                        .font(.headline)
                        .foregroundColor(.primary)
```
with
```swift
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if let location = device.location {
                            Text("· \(location)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
```

- [ ] **Step 5: Build and run the settings test**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/SettingsViewModelTests -only-testing:GrowGuardTests/AddDeviceViewModelTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -quiet 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/DeviceDetails/Componetns/LocationField.swift GrowGuard/DeviceDetails/Settings/SettingsView.swift GrowGuard/AddDevice/Details/AddDeviceDetails.swift GrowGuard/OverviewList/OverviewList.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Let the user assign a location per sensor (settings, add flow, overview caption)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Full verification and migration check

**Files:** none new.

- [ ] **Step 1: Full unit suite**

Run:
```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -test-timeouts-enabled YES -default-test-execution-time-allowance 60 2>&1 | grep -E "Test Suite|Executed|error:|failed|SUCCEEDED|FAILED" | tail -30
```
Expected: `** TEST SUCCEEDED **`, no failing tests. `BLEPerformanceTests` budgets are unaffected (no protocol constant changed); if a budget assertion trips, the pool's event forwarding added traffic — it must not, investigate rather than raise the budget.

- [ ] **Step 2: Migration check against a pre-change store**

This guards the unversioned-model crash and cannot run in the unit suite.

```bash
git stash list >/dev/null; git worktree add /tmp/growguard-main main
xcodebuild -project /tmp/growguard-main/GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath /tmp/growguard-main-dd build -quiet
xcrun simctl uninstall booted pro.veit.GrowGuard
xcrun simctl install booted /tmp/growguard-main-dd/Build/Products/Debug-iphonesimulator/GrowGuard.app
xcrun simctl launch booted pro.veit.GrowGuard
```
In the running old build add a device (any name; "Add without Sensor" is enough). Then:
```bash
xcodebuild -project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath /tmp/growguard-new-dd build -quiet
xcrun simctl install booted /tmp/growguard-new-dd/Build/Products/Debug-iphonesimulator/GrowGuard.app
xcrun simctl launch booted pro.veit.GrowGuard
```
Expected: the app opens and the device is still listed. A crash on launch with "The model used to open the store is incompatible with the one used to create the store" means the version-1 model is missing from the bundle — check that `CoreDataModels.xcdatamodel` is still a child of the XCVersionGroup. Clean up:
```bash
git worktree remove --force /tmp/growguard-main; rm -rf /tmp/growguard-main-dd /tmp/growguard-new-dd
```
(The bundle id `pro.veit.GrowGuard` is from the central manager's restore identifier; confirm with `grep PRODUCT_BUNDLE_IDENTIFIER GrowGuard.xcodeproj/project.pbxproj | head -1` before running.)

- [ ] **Step 3: Update AGENTS.md**

In `AGENTS.md` under "Background tasks" in the Conventions section add one line:
```
- **Sensor health:** `SensorHealthMonitor` (spec `docs/superpowers/specs/2026-09-14-sensor-health-design.md`) persists battery + counts failed contacts from the pool-wide `deviceEventsPublisher`; `SensorHealth.evaluate` is the single verdict for UI and notifications. Device writes go through `FlowerDeviceRepository.modifyDevice` — never rebuild a full DTO from a stale copy.
```
And under "Build Notes" add:
```
- **Core Data model is versioned** (`CoreDataModels.xcdatamodeld`, current: `CoreDataModels 2`). Schema changes need a new version; editing the current one in place breaks existing stores.
```

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "Document sensor health monitor and Core Data model versioning

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

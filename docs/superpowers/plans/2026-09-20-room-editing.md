# Room Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user rename a room, choose its icon, and delete it — per the "Editing rooms" section of `docs/superpowers/specs/2026-09-20-rooms-ui-design.md`.

**Architecture:** Rooms stay plain `location` strings. A `RoomEditor` performs the bulk rename/merge/delete through `modifyDevice`; an `@Observable` `RoomIconStore` (UserDefaults) holds optional custom icons keyed by the folded room name; `RoomCatalog.symbolName` asks the store first. A `RoomEditView` sheet is opened from a "…" menu and swipe actions on the picker's room rows.

**Tech Stack:** Swift 5 mode, SwiftUI (iOS 17+, Observation), Swift Testing, SwiftGen `L10n`.

## Global Constraints

- Build/test: `-project GrowGuard.xcodeproj -scheme GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'`; tests add `-testPlan GrowGuard -test-timeouts-enabled YES -default-test-execution-time-allowance 60`; pipe test logs through `grep -aE "Test run with|Executed|failed|error:|SUCCEEDED|FAILED"` (binary bytes in the log).
- `project.pbxproj` is hand-maintained: each new file needs `PBXBuildFile`, `PBXFileReference`, group `children`, `Sources` phase. App Sources `56AF11112BDED05900887073`; test Sources `56AF11242BDED05B00887073`; test root group `56AF112B2BDED05B00887073`; Services group `568EA33D2EB625CE00F6BB25` (files under `GrowGuard/Core/` go there with `name = X.swift; path = ../Core/X.swift;`); components group `568892062C83292D000E8FAE /* Componetns */` (folder really spelled `Componetns`).
- Strings via `L10n`: edit `GrowGuard/Strings/Localizable.strings`, run `swiftgen` (repo root), commit both, never hand-edit the generated file.
- Device writes only through `FlowerDeviceRepository.modifyDevice(uuid:_:)`, mutating only `location`. Plants are never deleted by room operations.
- Names go through `FlowerDeviceDTO.normalizeLocation(_:)`; comparisons through `RoomCatalog.fold(_:)`.
- Views untested (convention); `RoomIconStore`, `RoomEditor`, `RoomCatalog` are TDD with Swift Testing.
- Every commit message ends with exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (never another model name). Explicit `git add` paths; `.superpowers/` is untracked scratch.

---

### Task 1: `RoomIconStore`, `RoomEditor`, store-aware symbols

**Files:**
- Create: `GrowGuard/Core/RoomIconStore.swift`, `GrowGuard/Services/RoomEditor.swift`, `GrowGuardTests/RoomEditingTests.swift`
- Modify: `GrowGuard/Core/RoomCatalog.swift`, `GrowGuardTests/RoomCatalogTests.swift`, `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces (produced):**
```swift
@Observable final class RoomIconStore {
    static let shared: RoomIconStore
    static let choices: [String]                       // SF Symbol names offered in the UI
    init(defaults: UserDefaults = .standard)
    func symbol(for roomName: String) -> String?
    func setSymbol(_ symbol: String?, for roomName: String)   // nil = automatic
    func move(from oldName: String, to newName: String, keepingExistingTarget: Bool)
    func remove(_ roomName: String)
}
struct RoomEditor {
    enum RenameOutcome: Equatable { case invalid, unchanged, renamed(to: String, plants: Int), merged(into: String, plants: Int) }
    init(repository: FlowerDeviceRepository = RepositoryManager.shared.flowerDeviceRepository, icons: RoomIconStore = .shared)
    func mergeTarget(renaming oldName: String, to proposed: String) async throws -> String?
    @discardableResult func rename(_ oldName: String, to proposed: String) async throws -> RenameOutcome
    @discardableResult func delete(_ roomName: String) async throws -> Int
}
// RoomCatalog
static func fold(_ text: String) -> String                                   // now internal
static func symbolName(for name: String?, icons: RoomIconStore = .shared) -> String
static func defaultSymbolName(for name: String) -> String                     // keyword mapping only
```

- [ ] **Step 1: Write the failing tests**

Create `GrowGuardTests/RoomEditingTests.swift`:

```swift
//
//  RoomEditingTests.swift
//  GrowGuardTests
//
//  Rename / merge / delete of rooms and the custom icon store
//  (spec 2026-09-20-rooms-ui-design.md, "Editing rooms").
//

import Testing
import Foundation
@testable import GrowGuard

private final class InMemoryDeviceRepository: FlowerDeviceRepository {
    var devices: [String: FlowerDeviceDTO] = [:]
    var updateCount = 0
    func getAllDevices() async throws -> [FlowerDeviceDTO] { devices.values.sorted { $0.uuid < $1.uuid } }
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? { devices[uuid] }
    func saveDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device }
    func deleteDevice(uuid: String) async throws { devices[uuid] = nil }
    func updateDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device; updateCount += 1 }
}

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "RoomEditingTests-\(UUID().uuidString)")!
}

struct RoomIconStoreTests {

    @Test("A custom symbol is stored per folded room name and survives a new store instance")
    func setAndPersist() {
        let defaults = makeDefaults()
        let store = RoomIconStore(defaults: defaults)
        #expect(store.symbol(for: "Küche") == nil)

        store.setSymbol("flame.fill", for: "Küche")
        #expect(store.symbol(for: "  kuche ") == "flame.fill")
        #expect(RoomIconStore(defaults: defaults).symbol(for: "Küche") == "flame.fill")
    }

    @Test("nil means automatic: the entry is removed")
    func automatic() {
        let store = RoomIconStore(defaults: makeDefaults())
        store.setSymbol("flame.fill", for: "Küche")
        store.setSymbol(nil, for: "Küche")
        #expect(store.symbol(for: "Küche") == nil)
    }

    @Test("move carries the icon along; a merge keeps the target's own icon")
    func move() {
        let store = RoomIconStore(defaults: makeDefaults())
        store.setSymbol("flame.fill", for: "Küche")
        store.move(from: "Küche", to: "Kochnische", keepingExistingTarget: false)
        #expect(store.symbol(for: "Küche") == nil)
        #expect(store.symbol(for: "Kochnische") == "flame.fill")

        store.setSymbol("sun.max.fill", for: "Balkon")
        store.move(from: "Kochnische", to: "Balkon", keepingExistingTarget: true)
        #expect(store.symbol(for: "Balkon") == "sun.max.fill", "target keeps its icon")
        #expect(store.symbol(for: "Kochnische") == nil)

        store.setSymbol("leaf.fill", for: "Flur")
        store.move(from: "Flur", to: "Diele", keepingExistingTarget: true)
        #expect(store.symbol(for: "Diele") == "leaf.fill", "a target without an icon inherits")
    }

    @Test("A case-only move keeps the entry; remove deletes it")
    func caseOnlyMoveAndRemove() {
        let store = RoomIconStore(defaults: makeDefaults())
        store.setSymbol("flame.fill", for: "küche")
        store.move(from: "küche", to: "Küche", keepingExistingTarget: false)
        #expect(store.symbol(for: "Küche") == "flame.fill")
        store.remove("KÜCHE")
        #expect(store.symbol(for: "Küche") == nil)
    }

    @Test("symbolName asks the store first, falls back to keywords, ignores the store for nil")
    func symbolNameUsesStore() {
        let store = RoomIconStore(defaults: makeDefaults())
        #expect(RoomCatalog.symbolName(for: "Balkon", icons: store) == "sun.max.fill")
        store.setSymbol("leaf.fill", for: "Balkon")
        #expect(RoomCatalog.symbolName(for: "balkon", icons: store) == "leaf.fill")
        #expect(RoomCatalog.defaultSymbolName(for: "Balkon") == "sun.max.fill")
        #expect(RoomCatalog.symbolName(for: nil, icons: store) == "mappin.slash")
    }
}

struct RoomEditorTests {

    private func setUp(_ rooms: [(String, String?)]) -> (InMemoryDeviceRepository, RoomIconStore, RoomEditor) {
        let repo = InMemoryDeviceRepository()
        for (name, room) in rooms {
            repo.devices["uuid-\(name)"] = FlowerDeviceDTO(name: name, uuid: "uuid-\(name)", battery: 50, location: room)
        }
        let icons = RoomIconStore(defaults: makeDefaults())
        return (repo, icons, RoomEditor(repository: repo, icons: icons))
    }

    @Test("Rename rewrites location on every plant of the room and nothing else")
    func rename() async throws {
        let (repo, icons, editor) = setUp([("Tomate", "Balkon"), ("Basilikum", "Balkon"), ("Monstera", "Wohnzimmer"), ("Orchidee", nil)])
        icons.setSymbol("leaf.fill", for: "Balkon")

        let outcome = try await editor.rename("Balkon", to: "  Terrasse ")

        #expect(outcome == .renamed(to: "Terrasse", plants: 2))
        #expect(repo.devices["uuid-Tomate"]?.location == "Terrasse")
        #expect(repo.devices["uuid-Basilikum"]?.location == "Terrasse")
        #expect(repo.devices["uuid-Monstera"]?.location == "Wohnzimmer")
        #expect(repo.devices["uuid-Orchidee"]?.location == nil)
        #expect(repo.devices["uuid-Tomate"]?.battery == 50)
        #expect(repo.updateCount == 2)
        #expect(icons.symbol(for: "Terrasse") == "leaf.fill")
        #expect(icons.symbol(for: "Balkon") == nil)
    }

    @Test("Renaming onto another existing room merges and the existing spelling wins")
    func merge() async throws {
        let (repo, icons, editor) = setUp([("Tomate", "Balkon"), ("Monstera", "Wohnzimmer"), ("Ficus", "Wohnzimmer")])
        icons.setSymbol("sofa.fill", for: "Wohnzimmer")
        icons.setSymbol("leaf.fill", for: "Balkon")

        #expect(try await editor.mergeTarget(renaming: "Balkon", to: "wohnzimmer") == "Wohnzimmer")
        let outcome = try await editor.rename("Balkon", to: "wohnzimmer")

        #expect(outcome == .merged(into: "Wohnzimmer", plants: 1))
        #expect(repo.devices["uuid-Tomate"]?.location == "Wohnzimmer")
        #expect(icons.symbol(for: "Wohnzimmer") == "sofa.fill", "target keeps its icon")
        #expect(icons.symbol(for: "Balkon") == nil)
    }

    @Test("A case-only change of the same room is a plain rename, not a merge")
    func caseOnlyRename() async throws {
        let (repo, _, editor) = setUp([("Tomate", "balkon")])
        #expect(try await editor.mergeTarget(renaming: "balkon", to: "Balkon") == nil)
        #expect(try await editor.rename("balkon", to: "Balkon") == .renamed(to: "Balkon", plants: 1))
        #expect(repo.devices["uuid-Tomate"]?.location == "Balkon")
    }

    @Test("Empty and unchanged names write nothing")
    func invalidAndUnchanged() async throws {
        let (repo, _, editor) = setUp([("Tomate", "Balkon")])
        #expect(try await editor.rename("Balkon", to: "   ") == .invalid)
        #expect(try await editor.rename("Balkon", to: "Balkon") == .unchanged)
        #expect(try await editor.mergeTarget(renaming: "Balkon", to: "") == nil)
        #expect(repo.updateCount == 0)
    }

    @Test("Delete clears the room on its plants, keeps the plants, removes the icon")
    func delete() async throws {
        let (repo, icons, editor) = setUp([("Tomate", "Balkon"), ("Basilikum", "Balkon"), ("Monstera", "Wohnzimmer")])
        icons.setSymbol("leaf.fill", for: "Balkon")

        let count = try await editor.delete("Balkon")

        #expect(count == 2)
        #expect(repo.devices.count == 3, "plants are never deleted")
        #expect(repo.devices["uuid-Tomate"]?.location == nil)
        #expect(repo.devices["uuid-Monstera"]?.location == "Wohnzimmer")
        #expect(icons.symbol(for: "Balkon") == nil)
    }
}
```

In `GrowGuardTests/RoomCatalogTests.swift`, make the `symbols` test independent of the developer's stored icons: add `let icons = RoomIconStore(defaults: UserDefaults(suiteName: "RoomCatalogTests-\(UUID().uuidString)")!)` as its first line and change every `RoomCatalog.symbolName(for: X)` in that test to `RoomCatalog.symbolName(for: X, icons: icons)`.

- [ ] **Step 2: Register the three new files in the pbxproj**

```
		56RMIS012EC7000000000001 /* RoomIconStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56RMIS002EC7000000000001 /* RoomIconStore.swift */; };
		56RMED012EC7000000000001 /* RoomEditor.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56RMED002EC7000000000001 /* RoomEditor.swift */; };
		56RMET012EC7000000000001 /* RoomEditingTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 56RMET002EC7000000000001 /* RoomEditingTests.swift */; };
		56RMIS002EC7000000000001 /* RoomIconStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = RoomIconStore.swift; path = ../Core/RoomIconStore.swift; sourceTree = "<group>"; };
		56RMED002EC7000000000001 /* RoomEditor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomEditor.swift; sourceTree = "<group>"; };
		56RMET002EC7000000000001 /* RoomEditingTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RoomEditingTests.swift; sourceTree = "<group>"; };
```
Services group children: `RoomIconStore.swift`, `RoomEditor.swift`. Test root group children: `RoomEditingTests.swift`. App Sources phase: the two app build files. Test Sources phase: the test build file.

- [ ] **Step 3: Run to verify failure**

```bash
xcodebuild test -project GrowGuard.xcodeproj -scheme GrowGuard -testPlan GrowGuard -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:GrowGuardTests/RoomIconStoreTests -only-testing:GrowGuardTests/RoomEditorTests -only-testing:GrowGuardTests/RoomCatalogTests -test-timeouts-enabled YES -default-test-execution-time-allowance 60 2>&1 | grep -aE "Test run with|Executed|failed|error:|SUCCEEDED|FAILED" | head
```
Expected: `cannot find 'RoomIconStore' in scope` (create empty source files first if xcodebuild refuses missing references).

- [ ] **Step 4: Implement**

`GrowGuard/Core/RoomIconStore.swift`:

```swift
//
//  RoomIconStore.swift
//  GrowGuard
//
//  Optional custom SF Symbol per room (spec 2026-09-20-rooms-ui-design.md,
//  "Editing rooms"). Rooms are plain strings, so the icon lives beside them in
//  UserDefaults, keyed by the folded room name. @Observable: views that read a
//  symbol during `body` refresh when it changes.
//

import Foundation
import Observation

@Observable
final class RoomIconStore {
    static let shared = RoomIconStore()

    /// Symbols offered in the edit sheet
    static let choices: [String] = [
        "sofa.fill", "bed.double.fill", "fork.knife", "shower.fill", "desktopcomputer",
        "door.left.hand.closed", "stairs", "sun.max.fill", "tree.fill", "leaf.fill",
        "house.fill", "building.2.fill", "lamp.desk.fill", "books.vertical.fill", "tv.fill",
        "washer.fill", "car.fill", "cup.and.saucer.fill", "snowflake", "flame.fill"
    ]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "rooms.customIcons"
    private var icons: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.icons = (defaults.dictionary(forKey: "rooms.customIcons") as? [String: String]) ?? [:]
    }

    func symbol(for roomName: String) -> String? {
        icons[RoomCatalog.fold(roomName)]
    }

    /// nil = automatic (keyword mapping)
    func setSymbol(_ symbol: String?, for roomName: String) {
        icons[RoomCatalog.fold(roomName)] = symbol
        persist()
    }

    /// Rename: the icon follows. With `keepingExistingTarget` (a merge) the
    /// target's own icon wins; a target without one inherits.
    func move(from oldName: String, to newName: String, keepingExistingTarget: Bool) {
        let from = RoomCatalog.fold(oldName)
        let to = RoomCatalog.fold(newName)
        guard from != to, let moving = icons.removeValue(forKey: from) else {
            if from != to { persist() }
            return
        }
        if !(keepingExistingTarget && icons[to] != nil) {
            icons[to] = moving
        }
        persist()
    }

    func remove(_ roomName: String) {
        icons[RoomCatalog.fold(roomName)] = nil
        persist()
    }

    private func persist() {
        defaults.set(icons, forKey: key)
    }
}
```

`GrowGuard/Services/RoomEditor.swift`:

```swift
//
//  RoomEditor.swift
//  GrowGuard
//
//  Bulk operations on a room. A room is only the `location` string its
//  plants share, so renaming and deleting mean rewriting that one field on
//  every member — through modifyDevice, touching nothing else. Plants are
//  never deleted here.
//

import Foundation

struct RoomEditor {
    enum RenameOutcome: Equatable {
        /// Empty after trimming
        case invalid
        case unchanged
        case renamed(to: String, plants: Int)
        /// The name belonged to another room; that room's spelling won
        case merged(into: String, plants: Int)
    }

    private let repository: FlowerDeviceRepository
    private let icons: RoomIconStore

    init(repository: FlowerDeviceRepository = RepositoryManager.shared.flowerDeviceRepository,
         icons: RoomIconStore = .shared) {
        self.repository = repository
        self.icons = icons
    }

    /// The existing OTHER room a rename would merge into (its spelling), or
    /// nil. A case-only change of the same room is not a merge.
    func mergeTarget(renaming oldName: String, to proposed: String) async throws -> String? {
        guard let newName = FlowerDeviceDTO.normalizeLocation(proposed) else { return nil }
        let key = RoomCatalog.fold(newName)
        guard key != RoomCatalog.fold(oldName) else { return nil }
        return try await repository.getAllDevices()
            .compactMap(\.location)
            .first { $0 != oldName && RoomCatalog.fold($0) == key }
    }

    @discardableResult
    func rename(_ oldName: String, to proposed: String) async throws -> RenameOutcome {
        guard let newName = FlowerDeviceDTO.normalizeLocation(proposed) else { return .invalid }
        guard newName != oldName else { return .unchanged }

        let target = try await mergeTarget(renaming: oldName, to: newName)
        let finalName = target ?? newName
        let members = try await repository.getAllDevices().filter { $0.location == oldName }
        for member in members {
            try await repository.modifyDevice(uuid: member.uuid) { $0.location = finalName }
        }
        icons.move(from: oldName, to: finalName, keepingExistingTarget: target != nil)
        return target == nil
            ? .renamed(to: finalName, plants: members.count)
            : .merged(into: finalName, plants: members.count)
    }

    /// Clears the room on its plants. Returns how many plants were affected.
    @discardableResult
    func delete(_ roomName: String) async throws -> Int {
        let members = try await repository.getAllDevices().filter { $0.location == roomName }
        for member in members {
            try await repository.modifyDevice(uuid: member.uuid) { $0.location = nil }
        }
        icons.remove(roomName)
        return members.count
    }
}
```

In `GrowGuard/Core/RoomCatalog.swift`: remove `private` from `static func fold`, and replace `symbolName(for:)` with:

```swift
    /// The room's icon: a custom choice from the store, else the keyword mapping
    static func symbolName(for name: String?, icons: RoomIconStore = .shared) -> String {
        guard let name else { return "mappin.slash" }
        return icons.symbol(for: name) ?? defaultSymbolName(for: name)
    }

    /// Keyword → SF Symbol only ("Automatic" in the edit sheet)
    static func defaultSymbolName(for name: String) -> String {
        let key = fold(name)
        return symbolKeywords.first { entry in entry.keywords.contains { key.contains($0) } }?.symbol
            ?? "mappin.circle.fill"
    }
```
Update the file header comment: the catalog stays free of Core Data/BLE; the icon lookup is injectable.

- [ ] **Step 5: Run to verify pass**, then the full suite once (drop `-only-testing`). Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/Core/RoomIconStore.swift GrowGuard/Services/RoomEditor.swift GrowGuard/Core/RoomCatalog.swift GrowGuardTests/RoomEditingTests.swift GrowGuardTests/RoomCatalogTests.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Add RoomEditor (rename, merge, delete) and a custom room icon store

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Edit sheet, row menu and swipe actions in the picker

**Files:**
- Create: `GrowGuard/DeviceDetails/Componetns/RoomEditView.swift`
- Modify: `GrowGuard/DeviceDetails/Componetns/RoomPickerView.swift`, `GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift`, `GrowGuard/DeviceDetails/DeviceDetailsView.swift`, `GrowGuard/DeviceDetails/Settings/SettingsView.swift`, `GrowGuard/AddDevice/Details/AddDeviceDetails.swift`, `GrowGuard/Strings/Localizable.strings` (+ regenerated `Strings+Generated.swift`), `GrowGuard.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 1's `RoomEditor`, `RoomIconStore`, `RoomCatalog.symbolName(for:icons:)`, `.defaultSymbolName(for:)`.
- Produces: `RoomEditView(room:devices:onFinished:)`; `RoomPickerView(selection:devices:onRoomsChanged:)`; `RoomFormSection(location:devices:onRoomsChanged:)`; `DeviceDetailsViewModel.reloadRooms() async`; `SettingsViewModel.reloadDevices() async`.

- [ ] **Step 1: Strings**

Append to the `/* Rooms */` block of `Localizable.strings`, then run `swiftgen`:
```
"room.action.edit" = "Edit";
"room.action.more" = "More";
"room.edit.title" = "Edit room";
"room.edit.name" = "Name";
"room.edit.icon" = "Icon";
"room.edit.iconAutomatic" = "Automatic";
"room.edit.plants" = "Plants in this room";
"room.edit.delete" = "Delete room";
"room.edit.deleteConfirm.title" = "Delete “%@”?";
"room.edit.deleteConfirm.one" = "1 plant will have no room. The plant itself stays.";
"room.edit.deleteConfirm.other" = "%d plants will have no room. The plants themselves stay.";
"room.edit.mergeConfirm.title" = "Merge into “%@”?";
"room.edit.mergeConfirm.message" = "A room with that name already exists. The plants of both rooms will be together.";
"room.edit.merge" = "Merge";
"room.edit.failed" = "The room could not be changed. Try again.";
```
Verify the generated member names (`grep -n "enum Edit\|enum Action\|enum DeleteConfirm\|enum MergeConfirm" GrowGuard/Strings/Strings+Generated.swift`) and adapt the Swift below if SwiftGen names them differently.

- [ ] **Step 2: RoomEditView**

Create `GrowGuard/DeviceDetails/Componetns/RoomEditView.swift` and register it (ids `56RMEV002EC7000000000001` / `56RMEV012EC7000000000001`, `Componetns` group, app Sources phase):

```swift
//
//  RoomEditView.swift
//  GrowGuard
//
//  Rename a room, choose its icon, delete it. Presented as a sheet from the
//  room picker. All data work is RoomEditor / RoomIconStore.
//

import SwiftUI

struct RoomEditView: View {
    let room: Room
    let devices: [FlowerDeviceDTO]
    /// The room's name after the change; nil when it was deleted
    let onFinished: (String?) -> Void

    private let editor = RoomEditor()
    private let icons = RoomIconStore.shared

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// nil = automatic
    @State private var symbol: String?
    @State private var mergeTarget: String?
    @State private var showDeleteConfirm = false
    @State private var showError = false
    @State private var isWorking = false

    private let originalName: String
    private let originalSymbol: String?

    init(room: Room, devices: [FlowerDeviceDTO], onFinished: @escaping (String?) -> Void) {
        self.room = room
        self.devices = devices
        self.onFinished = onFinished
        let roomName = room.name ?? ""
        let stored = RoomIconStore.shared.symbol(for: roomName)
        self.originalName = roomName
        self.originalSymbol = stored
        _name = State(initialValue: roomName)
        _symbol = State(initialValue: stored)
    }

    private var members: [FlowerDeviceDTO] {
        devices.filter { $0.location == originalName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trimmedName: String? { FlowerDeviceDTO.normalizeLocation(name) }

    private var previewSymbol: String {
        symbol ?? RoomCatalog.defaultSymbolName(for: trimmedName ?? originalName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(L10n.Room.Edit.name)) {
                    HStack(spacing: 12) {
                        Image(systemName: previewSymbol)
                            .foregroundColor(.green)
                            .frame(width: 34, height: 34)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Circle())
                        TextField(L10n.Room.Edit.name, text: $name)
                            .autocorrectionDisabled()
                    }
                }

                Section(header: Text(L10n.Room.Edit.icon)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        iconCell(symbolName: nil)
                        ForEach(RoomIconStore.choices, id: \.self) { choice in
                            iconCell(symbolName: choice)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !members.isEmpty {
                    Section(header: Text(L10n.Room.Edit.plants)) {
                        ForEach(members) { plant in
                            Label(plant.name, systemImage: plant.isSensor ? "sensor.fill" : "leaf.fill")
                        }
                    }
                }

                Section {
                    Button(L10n.Room.Edit.delete, role: .destructive) { showDeleteConfirm = true }
                }
            }
            .disabled(isWorking)
            .navigationTitle(L10n.Room.Edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Alert.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Alert.save) { Task { await save(confirmedMerge: false) } }
                        .disabled(trimmedName == nil || isWorking)
                }
            }
            .alert(L10n.Room.Edit.MergeConfirm.title(mergeTarget ?? ""),
                   isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } })) {
                Button(L10n.Alert.cancel, role: .cancel) { mergeTarget = nil }
                Button(L10n.Room.Edit.merge) { Task { await save(confirmedMerge: true) } }
            } message: {
                Text(L10n.Room.Edit.MergeConfirm.message)
            }
            .confirmationDialog(L10n.Room.Edit.DeleteConfirm.title(originalName),
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button(L10n.Room.Edit.delete, role: .destructive) { Task { await delete() } }
                Button(L10n.Alert.cancel, role: .cancel) {}
            } message: {
                Text(members.count == 1 ? L10n.Room.Edit.DeleteConfirm.one
                                        : L10n.Room.Edit.DeleteConfirm.other(members.count))
            }
            .alert(L10n.Alert.error, isPresented: $showError) {
                Button(L10n.Alert.ok) {}
            } message: {
                Text(L10n.Room.Edit.failed)
            }
        }
    }

    /// One cell of the icon grid; `nil` is "Automatic"
    private func iconCell(symbolName: String?) -> some View {
        let isSelected = symbol == symbolName
        return Button {
            symbol = symbolName
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbolName ?? RoomCatalog.defaultSymbolName(for: trimmedName ?? originalName))
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .foregroundColor(isSelected ? .white : .green)
                    .background(isSelected ? Color.green : Color.green.opacity(0.15))
                    .clipShape(Circle())
                if symbolName == nil {
                    Text(L10n.Room.Edit.iconAutomatic)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbolName ?? L10n.Room.Edit.iconAutomatic)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save(confirmedMerge: Bool) async {
        guard let newName = trimmedName else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if !confirmedMerge, let target = try await editor.mergeTarget(renaming: originalName, to: newName) {
                mergeTarget = target
                return
            }
            mergeTarget = nil
            let finalName: String
            switch try await editor.rename(originalName, to: newName) {
            case .invalid: return
            case .unchanged: finalName = originalName
            case .renamed(let to, _): finalName = to
            case .merged(let into, _): finalName = into
            }
            if symbol != originalSymbol {
                icons.setSymbol(symbol, for: finalName)
            }
            onFinished(finalName)
            dismiss()
        } catch {
            showError = true
        }
    }

    private func delete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await editor.delete(originalName)
            onFinished(nil)
            dismiss()
        } catch {
            showError = true
        }
    }
}
```

- [ ] **Step 3: Picker — live device list, row menu, swipe actions**

In `RoomPickerView.swift`:

`RoomPickerView` gains, after `let devices: [FlowerDeviceDTO]`:
```swift
    /// Lets the host refresh its own copy after a room was renamed or deleted
    var onRoomsChanged: (() async -> Void)? = nil

    /// Reloaded after an edit; nil until then (use the host's snapshot)
    @State private var reloadedDevices: [FlowerDeviceDTO]?
    @State private var editingRoom: Room?
    @State private var roomPendingDeletion: Room?

    private var currentDevices: [FlowerDeviceDTO] { reloadedDevices ?? devices }
```
and `catalog` reads `currentDevices`.

In the "Your rooms" section, replace each row's `Button { pick(room.name) } label: { row(...) }` with a row whose main area picks and whose trailing menu edits:
```swift
                        HStack(spacing: 4) {
                            Button { pick(room.name) } label: {
                                row(symbol: RoomCatalog.symbolName(for: room.name),
                                    title: room.name ?? L10n.Room.none,
                                    subtitle: "\(RoomText.plants(room.plantCount)) · \(RoomText.sensors(room.sensorCount))",
                                    tint: .green,
                                    isSelected: room.name == selection)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button { editingRoom = room } label: { Label(L10n.Room.Action.edit, systemImage: "pencil") }
                                Button(role: .destructive) { roomPendingDeletion = room } label: { Label(L10n.Alert.delete, systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.Room.Action.more)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { roomPendingDeletion = room } label: { Label(L10n.Alert.delete, systemImage: "trash") }
                            Button { editingRoom = room } label: { Label(L10n.Room.Action.edit, systemImage: "pencil") }
                                .tint(.blue)
                        }
```
(`.plain` + `.borderless` keep the two controls separate tap targets inside one List row.)

On the `List`, next to `.navigationTitle`, add:
```swift
        .sheet(item: $editingRoom) { room in
            RoomEditView(room: room, devices: currentDevices) { newName in
                Task { await roomChanged(from: room.name, to: newName) }
            }
        }
        .confirmationDialog(L10n.Room.Edit.DeleteConfirm.title(roomPendingDeletion?.name ?? ""),
                            isPresented: Binding(get: { roomPendingDeletion != nil }, set: { if !$0 { roomPendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.Room.Edit.delete, role: .destructive) {
                if let room = roomPendingDeletion, let name = room.name {
                    Task {
                        try? await RoomEditor().delete(name)
                        await roomChanged(from: name, to: nil)
                    }
                }
            }
            Button(L10n.Alert.cancel, role: .cancel) {}
        } message: {
            let count = roomPendingDeletion?.plantCount ?? 0
            Text(count == 1 ? L10n.Room.Edit.DeleteConfirm.one : L10n.Room.Edit.DeleteConfirm.other(count))
        }
```
and the handler:
```swift
    /// A room was renamed (new name) or deleted (nil): keep the selection on
    /// it, reload the list, tell the host. The picker stays open.
    private func roomChanged(from oldName: String?, to newName: String?) async {
        if selection == oldName {
            selection = newName
        }
        reloadedDevices = try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
        await onRoomsChanged?()
    }
```
Note for the add-device flow: the plant being added is not in the repository yet, so after a reload it is simply not counted — acceptable.

`RoomFormSection` gains `var onRoomsChanged: (() async -> Void)? = nil` and passes it to `RoomPickerView(selection:devices:onRoomsChanged:)`.

- [ ] **Step 4: Hosts refresh their copy**

`DeviceDetailsViewModel.swift`, next to `setRoom`:
```swift
    /// After a room was renamed or deleted in the picker: refresh the peers and
    /// this plant's own room from the store.
    @MainActor
    func reloadRooms() async {
        guard let all = try? await repositoryManager.flowerDeviceRepository.getAllDevices() else { return }
        peers = all.filter { $0.uuid != device.uuid }
        if let me = all.first(where: { $0.uuid == device.uuid }) {
            device.location = me.location
        }
    }
```
`DeviceDetailsView.swift`: in the room-picker sheet pass `onRoomsChanged: { await viewModel.reloadRooms() }`. Careful with the selection binding there: its setter calls `viewModel.setRoom(room)`; after a rename the picker sets the selection to the new name, which writes the same value the bulk rename already wrote — harmless.

`SettingsView.swift` (`SettingsViewModel`):
```swift
    @MainActor
    func reloadDevices() async {
        if let all = try? await repositoryManager.flowerDeviceRepository.getAllDevices() {
            allDevices = all
        }
    }
```
and `RoomFormSection(location: $viewModel.location, devices: viewModel.allDevices, onRoomsChanged: { await viewModel.reloadDevices() })`.

`AddDeviceDetails.swift`: `RoomFormSection(..., devices: viewModel.allSavedDevices, onRoomsChanged: { await viewModel.fetchSavedDevices() })`.

- [ ] **Step 5: Build, suite, visual pass**

Build and run the full suite (commands in Global Constraints). Then look at it in the simulator. The unit suite WIPES the simulator's devices, so seed AFTER running tests: terminate the app, locate the newest `CoreDataModels.sqlite` with `find ~/Library/Developer/CoreSimulator/Devices/<booted udid>/data/Containers/Data/Application -name CoreDataModels.sqlite -print0 | xargs -0 ls -t | head -1` (the path contains a space — quote it), run `/tmp/rooms-seed.sql` through `sed -E "s/[0-9]{9}-/$(( $(date +%s) - 978307200 ))-/g"` into `sqlite3`, install the fresh build (`-derivedDataPath /tmp/rooms-dd`), launch `pro.veit.GrowGuard`. With the iOS Simulator control tool: open "Tomate" → room row → picker; screenshot the picker with the "…" buttons; open Edit for "Balkon" (screenshot); choose an icon, rename to "Terrasse", Save (screenshot of picker: renamed, selection moved, icon changed); go back and screenshot the details room row and the overview chip bar ("Terrasse 2"); edit "Terrasse" → rename to "wohnzimmer" → expect the merge alert (screenshot), confirm → "Wohnzimmer 4"; delete "Büro" via swipe or menu → confirmation (screenshot) → Kaktus shows "No room". Check dark mode once (`xcrun simctl ui booted appearance dark`, then back to `light`). Fix anything visibly broken before committing; describe every screenshot in the report. Re-seed at the end so the simulator is left with the six demo plants.

- [ ] **Step 6: Commit**

```bash
git add GrowGuard/DeviceDetails/Componetns/RoomEditView.swift GrowGuard/DeviceDetails/Componetns/RoomPickerView.swift GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift GrowGuard/DeviceDetails/DeviceDetailsView.swift GrowGuard/DeviceDetails/Settings/SettingsView.swift GrowGuard/AddDevice/Details/AddDeviceDetails.swift GrowGuard/Strings/Localizable.strings GrowGuard/Strings/Strings+Generated.swift GrowGuard.xcodeproj/project.pbxproj
git commit -m "Edit rooms from the picker: rename, merge, icon, delete

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

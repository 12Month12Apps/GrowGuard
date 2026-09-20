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

private struct RepositoryFailure: Error {}

private final class InMemoryDeviceRepository: FlowerDeviceRepository {
    var devices: [String: FlowerDeviceDTO] = [:]
    var updateCount = 0
    /// Throw on the n-th `updateDevice` (1-based) — a bulk edit that dies
    /// halfway, the way a Core Data save can.
    var failOnUpdateNumber: Int?
    func getAllDevices() async throws -> [FlowerDeviceDTO] { devices.values.sorted { $0.uuid < $1.uuid } }
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? { devices[uuid] }
    func saveDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device }
    func deleteDevice(uuid: String) async throws { devices[uuid] = nil }
    func updateDevice(_ device: FlowerDeviceDTO) async throws {
        updateCount += 1
        if updateCount == failOnUpdateNumber { throw RepositoryFailure() }
        devices[device.uuid] = device
    }
}

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "RoomEditingTests-\(UUID().uuidString)")!
}

// @MainActor: RoomIconStore and RoomEditor are main-actor isolated.
@MainActor
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

    @Test("move carries the icon along; a merge leaves the target's look untouched")
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
        #expect(store.symbol(for: "Diele") == nil, "a merge target keeps its automatic look")
        #expect(store.symbol(for: "Flur") == nil)
    }

    @Test("A plain rename decides the destination's icon on its own, orphan entry or not")
    func plainRenameOwnsTheDestination() {
        let store = RoomIconStore(defaults: makeDefaults())
        // "Diele" vanished when its last plant moved away, but its icon stayed
        // behind. Renaming an icon-less "Flur" onto that key must not inherit it.
        store.setSymbol("sofa.fill", for: "Diele")
        store.move(from: "Flur", to: "Diele", keepingExistingTarget: false)
        #expect(store.symbol(for: "Diele") == nil, "the renamed room had no custom icon")

        store.setSymbol("leaf.fill", for: "Flur")
        store.setSymbol("sofa.fill", for: "Diele")
        store.move(from: "Flur", to: "Diele", keepingExistingTarget: false)
        #expect(store.symbol(for: "Diele") == "leaf.fill", "the renamed room's own icon wins")
        #expect(store.symbol(for: "Flur") == nil)
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

@MainActor
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

    @Test("A legacy case-duplicate is a merge, not a rename: it needs the confirmation")
    func caseDuplicateIsAMergeNotARename() async throws {
        let (repo, _, editor) = setUp([("Tomate", "balkon"), ("Basilikum", "Balkon")])
        #expect(try await editor.mergeTarget(renaming: "balkon", to: "Balkon") == "Balkon")
        #expect(try await editor.rename("balkon", to: "Balkon") == .merged(into: "Balkon", plants: 1))
        #expect(repo.devices["uuid-Tomate"]?.location == "Balkon")
        #expect(repo.devices["uuid-Basilikum"]?.location == "Balkon")
    }

    @Test("The merge target is deterministic: the exact typed spelling wins, else the one with the most plants")
    func mergeTargetIsDeterministic() async throws {
        let (_, _, editor) = setUp([("Ficus", "BALKON"),
                                    ("Monstera", "Balkon"), ("Efeu", "Balkon"),
                                    ("Minze", "balkon"),
                                    ("Tomate", "Terrasse")])
        #expect(try await editor.mergeTarget(renaming: "Terrasse", to: "balkon") == "balkon",
                "an existing room spelled exactly as typed wins")
        #expect(try await editor.mergeTarget(renaming: "Terrasse", to: "BaLkOn") == "Balkon",
                "no exact match: the spelling the most plants use")
    }

    @Test("rename uses a confirmed merge target instead of recomputing it")
    func renameUsesTheConfirmedTarget() async throws {
        let (repo, _, editor) = setUp([("Ficus", "BALKON"), ("Monstera", "Balkon"), ("Tomate", "Terrasse")])
        let outcome = try await editor.rename("Terrasse", to: "balkon", mergingInto: "Balkon")
        #expect(outcome == .merged(into: "Balkon", plants: 1))
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

    @Test("A rename that fails halfway leaves the icon put and converges when it is retried")
    func renameConvergesAfterPartialFailure() async throws {
        let (repo, icons, editor) = setUp([("Basilikum", "Balkon"), ("Minze", "Balkon"), ("Tomate", "Balkon")])
        icons.setSymbol("leaf.fill", for: "Balkon")
        repo.failOnUpdateNumber = 2

        await #expect(throws: (any Error).self) { try await editor.rename("Balkon", to: "Terrasse") }

        var all = try await repo.getAllDevices()
        #expect(all.filter { $0.location == "Terrasse" }.count == 1)
        #expect(all.filter { $0.location == "Balkon" }.count == 2)
        #expect(icons.symbol(for: "Balkon") == "leaf.fill", "the icon only moves once every plant did")
        #expect(icons.symbol(for: "Terrasse") == nil)

        repo.failOnUpdateNumber = nil
        // The half-migrated "Terrasse" is a real room now, so the retry is a
        // merge into it — and by the merge rule the target keeps the look it
        // has, which is automatic. The plants converge; the custom icon does
        // not come back.
        let outcome = try await editor.rename("Balkon", to: "Terrasse")

        #expect(outcome == .merged(into: "Terrasse", plants: 2))
        all = try await repo.getAllDevices()
        #expect(all.allSatisfy { $0.location == "Terrasse" })
        #expect(icons.symbol(for: "Balkon") == nil)
        #expect(icons.symbol(for: "Terrasse") == nil)
    }

    @Test("A delete that fails halfway keeps the icon and converges when it is retried")
    func deleteConvergesAfterPartialFailure() async throws {
        let (repo, icons, editor) = setUp([("Basilikum", "Balkon"), ("Minze", "Balkon"), ("Tomate", "Balkon")])
        icons.setSymbol("leaf.fill", for: "Balkon")
        repo.failOnUpdateNumber = 2

        await #expect(throws: (any Error).self) { try await editor.delete("Balkon") }

        var all = try await repo.getAllDevices()
        #expect(all.filter { $0.location == nil }.count == 1)
        #expect(all.filter { $0.location == "Balkon" }.count == 2)
        #expect(icons.symbol(for: "Balkon") == "leaf.fill")

        repo.failOnUpdateNumber = nil
        #expect(try await editor.delete("Balkon") == 2)

        all = try await repo.getAllDevices()
        #expect(all.allSatisfy { $0.location == nil })
        #expect(all.count == 3, "plants are never deleted")
        #expect(icons.symbol(for: "Balkon") == nil)
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

//
//  RoomCatalogTests.swift
//  GrowGuardTests
//
//  Pure room derivation (spec 2026-09-20-rooms-ui-design.md).
//

import Testing
import Foundation
@testable import GrowGuard

struct RoomCatalogTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plant(_ name: String,
                       room: String?,
                       isSensor: Bool = true,
                       silentDays: Double = 0,
                       attempts: Int16 = 0) -> FlowerDeviceDTO {
        FlowerDeviceDTO(
            name: name,
            uuid: "uuid-\(name)",
            battery: 80,
            batteryUpdatedAt: now,
            isSensor: isSensor,
            lastUpdate: now.addingTimeInterval(-silentDays * 86_400),
            failedContactAttempts: attempts,
            location: room
        )
    }

    private var home: [FlowerDeviceDTO] {
        [plant("Monstera", room: "Wohnzimmer"),
         plant("Ficus", room: "Wohnzimmer"),
         plant("Efeu", room: "Wohnzimmer", isSensor: false),
         plant("Tomate", room: "Balkon", silentDays: 3, attempts: 3),
         plant("Basilikum", room: "Balkon"),
         plant("Kaktus", room: "Büro"),
         plant("Orchidee", room: nil)]
    }

    @Test("Rooms are counted and sorted by name; sensors counted separately")
    func countsAndSorting() {
        let catalog = RoomCatalog(devices: home, now: now)
        #expect(catalog.rooms.map(\.name) == ["Balkon", "Büro", "Wohnzimmer"])
        #expect(catalog.rooms.map(\.plantCount) == [2, 1, 3])
        #expect(catalog.rooms.map(\.sensorCount) == [2, 1, 2])
        #expect(catalog.totalCount == 7)
    }

    @Test("Plants without a room form the unassigned bucket; absent when every plant has a room")
    func unassignedBucket() {
        #expect(RoomCatalog(devices: home, now: now).unassigned == Room(name: nil, plantCount: 1, sensorCount: 1, hasSilentSensor: false))
        #expect(RoomCatalog(devices: [plant("A", room: "X")], now: now).unassigned == nil)
        #expect(RoomCatalog(devices: [], now: now).rooms.isEmpty)
    }

    @Test("A room with an unreachable sensor is flagged; others are not")
    func silentFlag() {
        let catalog = RoomCatalog(devices: home, now: now)
        #expect(catalog.room(named: "Balkon")?.hasSilentSensor == true)
        #expect(catalog.room(named: "Wohnzimmer")?.hasSilentSensor == false)
    }

    @Test("room(named:) and search ignore case and diacritics")
    func foldedLookup() {
        let catalog = RoomCatalog(devices: home + [plant("Petersilie", room: "Küche")], now: now)
        #expect(catalog.room(named: "  balkon ")?.name == "Balkon")
        #expect(catalog.room(named: "kuche")?.name == "Küche")
        #expect(catalog.search("kuc").map(\.name) == ["Küche"])
        #expect(catalog.search("B").map(\.name) == ["Balkon", "Büro"])
        #expect(catalog.search("").count == 4)
        #expect(catalog.search("xyz").isEmpty)
    }

    @Test("Create is offered only for a non-empty name without an exact match, normalized")
    func createRule() {
        let catalog = RoomCatalog(devices: home, now: now)
        #expect(catalog.nameToCreate(from: "  Küche  ") == "Küche")
        #expect(catalog.nameToCreate(from: "balkon") == nil, "existing spelling wins")
        #expect(catalog.nameToCreate(from: "Bal") == "Bal", "a prefix is not an exact match")
        #expect(catalog.nameToCreate(from: "   ") == nil)
    }

    @Test("Suggestions exclude existing rooms and follow the query")
    func suggestions() {
        let catalog = RoomCatalog(devices: home, now: now)
        let defaults = ["Wohnzimmer", "Küche", "Schlafzimmer", "Keller"]
        #expect(catalog.suggestions(for: "", defaults: defaults) == ["Küche", "Schlafzimmer", "Keller"])
        #expect(catalog.suggestions(for: "ku", defaults: defaults) == ["Küche"])
        #expect(catalog.suggestions(for: "Küche", defaults: defaults) == ["Küche"])
        #expect(catalog.suggestions(for: "zzz", defaults: defaults).isEmpty)
    }

    @Test("Symbols follow keywords in German and English, with fallbacks")
    func symbols() {
        #expect(RoomCatalog.symbolName(for: "Wohnzimmer") == "sofa.fill")
        #expect(RoomCatalog.symbolName(for: "Living room") == "sofa.fill")
        #expect(RoomCatalog.symbolName(for: "Balkon Süd") == "sun.max.fill")
        #expect(RoomCatalog.symbolName(for: "Küche") == "fork.knife")
        #expect(RoomCatalog.symbolName(for: "Schlafzimmer") == "bed.double.fill")
        #expect(RoomCatalog.symbolName(for: "Badezimmer") == "shower.fill")
        #expect(RoomCatalog.symbolName(for: "Büro") == "desktopcomputer")
        #expect(RoomCatalog.symbolName(for: "Garten") == "tree.fill")
        #expect(RoomCatalog.symbolName(for: "Flur") == "door.left.hand.closed")
        #expect(RoomCatalog.symbolName(for: "Keller") == "stairs")
        #expect(RoomCatalog.symbolName(for: "Wintergarten") == "tree.fill")
        #expect(RoomCatalog.symbolName(for: "Oben links") == "mappin.circle.fill")
        #expect(RoomCatalog.symbolName(for: nil) == "mappin.slash")
    }

    @Test("Companions are the other plants in the same room, sorted; none without a room")
    func companions() {
        let tomate = home[3]
        #expect(RoomCatalog.companions(of: tomate, in: home) == ["Basilikum"])
        #expect(RoomCatalog.companions(of: home[0], in: home) == ["Efeu", "Ficus"])
        #expect(RoomCatalog.companions(of: home[5], in: home).isEmpty)
        #expect(RoomCatalog.companions(of: home[6], in: home).isEmpty, "no room, no companions")
    }

    @Test("RoomFilter.includes and resolve")
    func filter() {
        let catalog = RoomCatalog(devices: home, now: now)
        #expect(RoomFilter.all.includes(home[6]))
        #expect(RoomFilter.room("Balkon").includes(home[3]))
        #expect(!RoomFilter.room("Balkon").includes(home[0]))
        #expect(RoomFilter.unassigned.includes(home[6]))
        #expect(!RoomFilter.unassigned.includes(home[0]))
        #expect(catalog.resolve(.room("Balkon")) == .room("Balkon"))
        #expect(catalog.resolve(.room("Dachboden")) == .all, "a vanished room falls back to all")
        #expect(RoomCatalog(devices: [plant("A", room: "X")], now: now).resolve(.unassigned) == .all)
    }
}

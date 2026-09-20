//
//  RoomCatalog.swift
//  GrowGuard
//
//  Rooms as the UI shows them, derived from the devices' `location` strings
//  (spec docs/superpowers/specs/2026-09-20-rooms-ui-design.md). A room is
//  never stored on its own: it exists for as long as a plant uses it.
//  Pure: DTOs in, value types out — no Core Data, no BLE. The one lookup that
//  needs stored state, the custom room icon, is injected (`RoomIconStore`),
//  so tests can pass a store of their own.
//

import Foundation

struct Room: Identifiable, Equatable {
    /// nil = the bucket of plants without a room
    let name: String?
    let plantCount: Int
    let sensorCount: Int
    /// At least one sensor here is `.unreachable`
    let hasSilentSensor: Bool

    var id: String { name ?? "\u{0}unassigned" }
}

enum RoomFilter: Hashable {
    case all
    case room(String)
    case unassigned

    func includes(_ device: FlowerDeviceDTO) -> Bool {
        switch self {
        case .all: return true
        case .room(let name): return device.location == name
        case .unassigned: return device.location == nil
        }
    }
}

struct RoomCatalog: Equatable {
    /// Named rooms, sorted the way Finder sorts names
    let rooms: [Room]
    /// nil when every plant has a room
    let unassigned: Room?
    let totalCount: Int

    init(devices: [FlowerDeviceDTO], now: Date) {
        func makeRoom(_ name: String?, _ members: [FlowerDeviceDTO]) -> Room {
            let silent = members.contains { member in
                // No peers: they only set `confirmedByPeer`, never `isUnreachable`.
                SensorHealth.evaluate(member, peers: [], now: now).isUnreachable
            }
            return Room(name: name,
                        plantCount: members.count,
                        sensorCount: members.filter(\.isSensor).count,
                        hasSilentSensor: silent)
        }

        let grouped = Dictionary(grouping: devices, by: \.location)
        rooms = grouped
            .compactMap { name, members in name.map { makeRoom($0, members) } }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        unassigned = grouped[nil].map { makeRoom(nil, $0) }
        totalCount = devices.count
    }

    // MARK: - Lookup

    /// Exact match ignoring case, diacritics and surrounding whitespace
    func room(named query: String) -> Room? {
        let key = Self.fold(query)
        guard !key.isEmpty else { return nil }
        return rooms.first { Self.fold($0.name ?? "") == key }
    }

    /// Rooms whose name contains the query; everything for an empty query
    func search(_ query: String) -> [Room] {
        let key = Self.fold(query)
        guard !key.isEmpty else { return rooms }
        return rooms.filter { Self.fold($0.name ?? "").contains(key) }
    }

    /// The normalized name "Create" would use, or nil when the query is empty
    /// or a room with that name exists — the existing spelling always wins.
    func nameToCreate(from query: String) -> String? {
        guard let name = FlowerDeviceDTO.normalizeLocation(query), room(named: name) == nil else { return nil }
        return name
    }

    /// Common room names that are not rooms yet, narrowed by the query
    func suggestions(for query: String, defaults: [String] = RoomCatalog.defaultSuggestions) -> [String] {
        let key = Self.fold(query)
        return defaults.filter { suggestion in
            room(named: suggestion) == nil && (key.isEmpty || Self.fold(suggestion).contains(key))
        }
    }

    /// A filter pointing at a room that no longer exists falls back to `.all`
    func resolve(_ filter: RoomFilter) -> RoomFilter {
        switch filter {
        case .all: return .all
        case .room(let name): return rooms.contains { $0.name == name } ? filter : .all
        case .unassigned: return unassigned == nil ? .all : filter
        }
    }

    // MARK: - Presentation helpers

    static var defaultSuggestions: [String] {
        [L10n.Room.Suggestion.livingRoom, L10n.Room.Suggestion.kitchen, L10n.Room.Suggestion.bedroom,
         L10n.Room.Suggestion.bathroom, L10n.Room.Suggestion.hallway, L10n.Room.Suggestion.office,
         L10n.Room.Suggestion.balcony, L10n.Room.Suggestion.terrace, L10n.Room.Suggestion.garden,
         L10n.Room.Suggestion.basement]
    }

    /// Keyword → SF Symbol. First match wins, so more specific keywords come
    /// first ("garten" before "wohn" makes "Wintergarten" a tree).
    private static let symbolKeywords: [(keywords: [String], symbol: String)] = [
        (["garten", "garden", "yard", "hof"], "tree.fill"),
        (["balkon", "balcon", "terrass", "terrace", "patio", "veranda"], "sun.max.fill"),
        (["schlaf", "bed"], "bed.double.fill"),
        (["kuch", "kitchen"], "fork.knife"),
        (["bad", "bath", "dusch", "wc"], "shower.fill"),
        (["buro", "office", "arbeit", "study"], "desktopcomputer"),
        (["flur", "diele", "hall", "eingang", "entrance"], "door.left.hand.closed"),
        (["keller", "basement", "cellar"], "stairs"),
        (["wohn", "living", "lounge"], "sofa.fill")
    ]

    /// The room's icon: a custom choice from the store, else the keyword
    /// mapping. @MainActor because it reads the main-actor icon store; its
    /// callers are SwiftUI `body`s. `defaultSymbolName` stays pure and free.
    @MainActor
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

    /// Names of the other plants in the same room, sorted. Empty without a room.
    static func companions(of device: FlowerDeviceDTO, in devices: [FlowerDeviceDTO]) -> [String] {
        guard let room = device.location else { return [] }
        return devices
            .filter { $0.uuid != device.uuid && $0.location == room }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Lookup key for a room name. Internal: `RoomIconStore` and `RoomEditor`
    /// key on exactly the same folding.
    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            // locale: nil — folding is a lookup key, not display text. Under a
            // Turkish locale "I" would fold to dotless "ı" and break search.
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

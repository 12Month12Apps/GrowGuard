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

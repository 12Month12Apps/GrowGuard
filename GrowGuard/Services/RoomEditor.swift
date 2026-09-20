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

/// @MainActor: every caller is a view or a main-actor view model, and the
/// icon store these methods mutate is main-actor state. Without it the
/// nonisolated `async` methods would run on the global executor and write
/// the store while `body` reads it.
@MainActor
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

    /// Two initializers rather than `icons: RoomIconStore = .shared`: a
    /// default argument is evaluated in a nonisolated context in Swift 5
    /// mode, so naming the main-actor shared store there warns.
    init(repository: FlowerDeviceRepository = RepositoryManager.shared.flowerDeviceRepository) {
        self.init(repository: repository, icons: .shared)
    }

    init(repository: FlowerDeviceRepository, icons: RoomIconStore) {
        self.repository = repository
        self.icons = icons
    }

    /// The existing OTHER room a rename would merge into (its spelling), or
    /// nil. Only the source spelling itself is excluded — a legacy
    /// case-duplicate ("Balkon" next to "balkon") is a real second room and
    /// must be confirmed like any other merge. With no other spelling left,
    /// a case-only change is a plain rename.
    ///
    /// Deterministic when several spellings fold alike: an existing room
    /// spelled exactly as the user typed wins, otherwise the spelling the
    /// most plants use, ties by name.
    func mergeTarget(renaming oldName: String, to proposed: String) async throws -> String? {
        guard let newName = FlowerDeviceDTO.normalizeLocation(proposed) else { return nil }
        let key = RoomCatalog.fold(newName)
        var counts: [String: Int] = [:]
        for location in try await repository.getAllDevices().compactMap(\.location)
        where location != oldName && RoomCatalog.fold(location) == key {
            counts[location, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        if counts[newName] != nil { return newName }
        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    : lhs.value > rhs.value
            }
            .first?.key
    }

    /// `mergingInto` is the target the user already confirmed: it is used as
    /// the final name verbatim, so the alert and the write can never disagree
    /// about which spelling wins.
    @discardableResult
    func rename(_ oldName: String, to proposed: String, mergingInto confirmedTarget: String? = nil) async throws -> RenameOutcome {
        guard let newName = FlowerDeviceDTO.normalizeLocation(proposed) else { return .invalid }
        guard newName != oldName else { return .unchanged }

        let target: String?
        if let confirmedTarget {
            target = confirmedTarget
        } else {
            target = try await mergeTarget(renaming: oldName, to: newName)
        }
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

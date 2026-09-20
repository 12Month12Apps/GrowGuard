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

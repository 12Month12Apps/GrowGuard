//
//  FlowerDeviceDTOTests.swift
//  GrowGuardTests
//
//  Sensor-health helpers on the DTO (spec 2026-09-14-sensor-health-design.md)
//  and the repository's fetch-mutate-save helper.
//

import Testing
import Foundation
import CoreData
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

/// Each test builds its own in-memory store, so nothing here touches the shared
/// Core Data store that other suites read and wipe.
@Suite(.serialized)
struct FlowerDeviceRepositoryModifyTests {

    /// Isolated in-memory store so parallel suites that wipe the shared store
    /// (OverviewListViewModelTests.deleteAllDevices) cannot race this one.
    ///
    /// The container reuses `DataService.shared`'s already-loaded
    /// `NSManagedObjectModel` instance rather than loading a second copy of the
    /// same model: two live model instances would both claim the `FlowerDevice`
    /// class, so `+[FlowerDevice entity]` can no longer find a unique match and
    /// `FlowerDevice(context:)` resolves its entity nondeterministically. Only
    /// the *store* needs to be isolated here, not the model.
    private func makeIsolatedRepository() throws -> FlowerDeviceRepository {
        let container = NSPersistentContainer(
            name: "CoreDataModelsTest",
            managedObjectModel: DataService.shared.persistentContainer.managedObjectModel
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let context = container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return CoreDataFlowerDeviceRepository(context: context)
    }

    @Test("modifyDevice fetches, mutates and saves only what the closure touches")
    func modifyDevicePreservesOtherFields() async throws {
        let repo = try makeIsolatedRepository()
        let uuid = "MODIFY-\(UUID().uuidString)"
        let lastUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        // Two distinct stamps so a swapped mapping in updateFromDTO fails here.
        let batteryUpdatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let lastFailedContactAt = Date(timeIntervalSince1970: 1_700_000_200)
        var seed = FlowerDeviceDTO(name: "Rose", uuid: uuid, battery: 25, lastUpdate: lastUpdate)
        seed.location = "  Balcony "
        seed.failedContactAttempts = 2
        seed.batteryUpdatedAt = batteryUpdatedAt
        seed.lastFailedContactAt = lastFailedContactAt
        try await repo.saveDevice(seed)

        let returned = try await repo.modifyDevice(uuid: uuid) { $0.name = "Renamed" }
        let reloaded = try await repo.getDevice(by: uuid)

        #expect(returned?.name == "Renamed")
        #expect(reloaded?.name == "Renamed")
        #expect(reloaded?.battery == 25)
        #expect(reloaded?.location == "Balcony", "location is stored trimmed")
        #expect(reloaded?.failedContactAttempts == 2)
        #expect(reloaded?.lastUpdate == lastUpdate)
        #expect(reloaded?.batteryUpdatedAt == batteryUpdatedAt)
        #expect(reloaded?.lastFailedContactAt == lastFailedContactAt)
    }

    /// A BLE battery event from `SensorHealthMonitor` can land while a settings
    /// save is in flight. A fetch → mutate → save built from three separate
    /// awaits lets both sides read the same row and write it back, so whichever
    /// finishes last silently drops the other's field. The Core Data
    /// implementation does the whole read-modify-write inside one
    /// `context.perform`, which the queue-confined context serializes against
    /// every other `modifyDevice`/`saveDevice`.
    @Test("Concurrent modifications on one device never lose an update")
    func concurrentModificationsDoNotLoseUpdates() async throws {
        let repo = try makeIsolatedRepository()
        let uuid = "MODIFY-CONCURRENT-\(UUID().uuidString)"
        try await repo.saveDevice(FlowerDeviceDTO(name: "Rose", uuid: uuid, battery: 25))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await repo.modifyDevice(uuid: uuid) { $0.failedContactAttempts += 1 }
                }
                group.addTask {
                    try await repo.modifyDevice(uuid: uuid) { $0.battery = 77 }
                }
            }
            try await group.waitForAll()
        }

        let reloaded = try await repo.getDevice(by: uuid)
        #expect(reloaded?.failedContactAttempts == 50, "every increment has to survive")
        #expect(reloaded?.battery == 77, "the interleaved writer's field survives too")
    }

    @Test("modifyDevice returns nil for an unknown device and writes nothing")
    func modifyDeviceUnknown() async throws {
        let repo = try makeIsolatedRepository()
        let uuid = "MODIFY-UNKNOWN-\(UUID().uuidString)"
        let result = try await repo.modifyDevice(uuid: uuid) { $0.name = "x" }
        #expect(result == nil)
        #expect(try await repo.getDevice(by: uuid) == nil)
    }
}

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
        /// Counts writes so a doubled subscription is visible: each handled
        /// event performs exactly one write.
        var updateCount = 0
        func getAllDevices() async throws -> [FlowerDeviceDTO] { Array(devices.values).sorted { $0.uuid < $1.uuid } }
        func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? { devices[uuid] }
        func saveDevice(_ device: FlowerDeviceDTO) async throws { devices[device.uuid] = device }
        func deleteDevice(uuid: String) async throws { devices[uuid] = nil }
        func updateDevice(_ device: FlowerDeviceDTO) async throws {
            updateCount += 1
            devices[device.uuid] = device
        }
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

    /// A history sync replays thousands of entries, each one a
    /// `.historicalData` event. Without coalescing every single one drove a
    /// `modifyDevice` + `getAllDevices()` + an evaluation of self and every
    /// peer — the whole store re-read ~3000× per sync.
    @Test("Successes inside the coalesce window collapse into one write")
    func successesWithinWindowCoalesce() async {
        seed("A", attempts: 2)
        let monitor = makeMonitor()

        await monitor.handle(.historicalData(uuid: "A"))
        clock.advance(10)
        await monitor.handle(.historicalData(uuid: "A"))
        clock.advance(10)
        await monitor.handle(.historicalData(uuid: "A"))
        #expect(repository.updateCount == 1)

        // Past the window the next contact is recorded again
        clock.advance(61)
        await monitor.handle(.historicalData(uuid: "A"))
        #expect(repository.updateCount == 2)
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

        // B delivers again → no third notification for A. Past the coalesce
        // window, so this reading really is processed and not collapsed away.
        clock.advance(61)
        repository.devices["B"]!.lastUpdate = clock.now
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
        await waitUntil { self.repository.devices["A"]!.failedContactAttempts == 0 }

        #expect(repository.devices["A"]!.failedContactAttempts == 0)
    }

    @Test("start() twice subscribes once: one event is handled once")
    func startSubscribesOnce() async {
        seed("A", battery: 80)
        let monitor = makeMonitor()
        monitor.start()
        monitor.start()

        events.send(.deviceInfo(uuid: "A", info: .init(battery: 42, firmware: "f")))
        await waitUntil { self.repository.updateCount >= 1 }
        // Give a second (wrongly subscribed) handler every chance to write too
        await drainMainActor()
        await drainMainActor()

        #expect(repository.updateCount == 1)
    }

    // MARK: - New-cell threshold

    @Test("Only a reading strictly above the new-cell threshold clears the marker")
    func newCellThresholdBoundary() async {
        seed("A", battery: 80)
        let monitor = makeMonitor()

        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 30, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30])

        // Exactly the threshold: a cell this weak is not a fresh one
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 40, firmware: "f")))
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 29, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30])

        // One above the threshold: new cell, marker cleared
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 41, firmware: "f")))
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 29, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [30, 29])
    }

    // MARK: - Rate limiting

    @Test("A rate-limited failure neither counts nor evaluates")
    func rateLimitedFailureDoesNotEvaluate() async {
        seed("A",
             silentFor: 3 * 24 * hour,
             attempts: 2,
             lastFailedAt: clock.now.addingTimeInterval(-10 * 60))
        let monitor = makeMonitor()

        await monitor.recordFailedContact("A")

        #expect(repository.devices["A"]!.failedContactAttempts == 2)
        #expect(notifier.unreachable.isEmpty)
    }

    // MARK: - Marker sweep on delete

    @Test("forgetDevice removes both markers so a re-paired sensor starts clean")
    func forgetDeviceClearsMarkers() async {
        defaults.set("confirmed", forKey: "sensorHealth.unreachableNotified.A")
        defaults.set(true, forKey: "sensorHealth.lowBatteryNotified.A")
        let monitor = makeMonitor()

        monitor.forgetDevice("A")

        #expect(defaults.string(forKey: "sensorHealth.unreachableNotified.A") == nil)
        #expect(defaults.bool(forKey: "sensorHealth.lowBatteryNotified.A") == false)

        // A re-paired sensor with the same uuid notifies again
        seed("A", battery: 80)
        await monitor.handle(.deviceInfo(uuid: "A", info: .init(battery: 20, firmware: "f")))
        #expect(notifier.lowBattery.map(\.percent) == [20])
    }
}

// MARK: - Notification identifier scoping

/// `cancelNotifications(for:kinds:)` runs on every wake read from the watering
/// paths. Before the kind filter it swept *every* identifier containing the
/// uuid, which deleted the just-delivered sensor-health alerts while their
/// once-per-episode markers stayed set — the alert was never posted again.
/// Pure identifier arithmetic: no UNUserNotificationCenter.
struct NotificationScopingTests {

    let pending = [
        "watering-daily-A",
        "watering-predictive-A",
        "watering-daily-B"
    ]
    let delivered = [
        "watering-immediate-A",
        "sensor-battery-A",
        "sensor-unreachable-A",
        "sensor-battery-B"
    ]

    private func cancel(_ kinds: Set<NotificationKind>, uuid: String = "A") -> Set<String> {
        Set(NotificationService.identifiersToCancel(
            pending: pending,
            delivered: delivered,
            deviceUUID: uuid,
            kinds: kinds
        ))
    }

    @Test("Cancelling watering notifications leaves the sensor-health alerts in place")
    func wateringOnlyLeavesSensorHealthAlone() {
        let removed = cancel([.watering])
        #expect(!removed.contains("sensor-battery-A"))
        #expect(!removed.contains("sensor-unreachable-A"))
    }

    @Test("Watering matches the immediate, daily and predictive identifiers of that device")
    func wateringMatchesEveryWateringIdentifier() {
        #expect(cancel([.watering]) == [
            "watering-daily-A",
            "watering-predictive-A",
            "watering-immediate-A"
        ])
    }

    @Test("Both kinds remove watering and sensor-health identifiers")
    func bothKindsRemoveEverythingForTheDevice() {
        #expect(cancel([.watering, .sensorHealth]) == [
            "watering-daily-A",
            "watering-predictive-A",
            "watering-immediate-A",
            "sensor-battery-A",
            "sensor-unreachable-A"
        ])
    }

    @Test("Sensor health alone touches no watering identifier")
    func sensorHealthOnly() {
        #expect(cancel([.sensorHealth]) == ["sensor-battery-A", "sensor-unreachable-A"])
    }

    @Test("Another device's notifications are never touched")
    func otherDeviceIsNeverTouched() {
        let removed = cancel([.watering, .sensorHealth], uuid: "A")
        #expect(!removed.contains("watering-daily-B"))
        #expect(!removed.contains("sensor-battery-B"))
    }

    @Test("An empty kind set removes nothing")
    func noKindsRemovesNothing() {
        #expect(cancel([]).isEmpty)
    }
}

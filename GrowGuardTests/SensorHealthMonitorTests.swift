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

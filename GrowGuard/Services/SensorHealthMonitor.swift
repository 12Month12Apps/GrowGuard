//
//  SensorHealthMonitor.swift
//  GrowGuard
//
//  Owns battery persistence, failed-contact bookkeeping and the once-per-
//  episode sensor health notifications (spec
//  docs/superpowers/specs/2026-09-14-sensor-health-design.md). Listens to the
//  pool-wide DeviceEvent stream so background wakes count as much as an open
//  detail screen. No CoreBluetooth in here.
//

import Foundation
import Combine

@MainActor
final class SensorHealthMonitor {

    static let shared = SensorHealthMonitor()

    /// Failures closer together than this count once. Background triggers
    /// (push, BGAppRefresh, enter-background) can fire minutes apart.
    static let failureRateLimit: TimeInterval = 60 * 60
    /// A battery read above this clears the low-battery marker: new cell.
    static let newCellThreshold = 40

    // MARK: - Dependencies (tests inject)

    private let events: AnyPublisher<DeviceEvent, Never>
    private let repository: FlowerDeviceRepository
    private let notifier: SensorHealthNotifying
    private let defaults: UserDefaults
    private let now: () -> Date
    private var subscription: AnyCancellable?

    private enum DefaultsKey {
        static func unreachableNotified(for uuid: String) -> String { "sensorHealth.unreachableNotified.\(uuid)" }
        static func lowBatteryNotified(for uuid: String) -> String { "sensorHealth.lowBatteryNotified.\(uuid)" }
    }

    private enum UnreachableFlavour: String {
        case unconfirmed, confirmed
    }

    init(events: AnyPublisher<DeviceEvent, Never>? = nil,
         repository: FlowerDeviceRepository? = nil,
         notifier: SensorHealthNotifying? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.events = events ?? ConnectionPoolManager.shared.deviceEventsPublisher
        self.repository = repository ?? RepositoryManager.shared.flowerDeviceRepository
        self.notifier = notifier ?? NotificationService.shared
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Lifecycle

    /// Call once from didFinishLaunching, after the pool exists
    func start() {
        guard subscription == nil else { return }
        subscription = events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                Task { @MainActor in await self?.handle(event) }
            }
    }

    // MARK: - Events

    func handle(_ event: DeviceEvent) async {
        switch event {
        case .deviceInfo(let uuid, let info):
            await persistBattery(uuid: uuid, battery: info.battery, firmware: info.firmware)
        case .sensorData(let uuid), .historicalData(let uuid):
            await recordSuccessfulContact(uuid)
        case .attemptGaveUp(let uuid):
            await recordFailedContact(uuid)
        }
    }

    /// Any received reading ends the silence: counter to 0, marker cleared.
    /// Also re-evaluates every other sensor — this device may be the witness
    /// that upgrades a neighbour's verdict from unconfirmed to confirmed.
    func recordSuccessfulContact(_ uuid: String) async {
        do {
            guard try await repository.modifyDevice(uuid: uuid, { device in
                device.failedContactAttempts = 0
                device.lastFailedContactAt = nil
            }) != nil else { return }
            defaults.removeObject(forKey: DefaultsKey.unreachableNotified(for: uuid))

            let others = try await repository.getAllDevices().filter { $0.uuid != uuid && $0.isSensor }
            for other in others {
                await evaluateAndNotify(uuid: other.uuid)
            }
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to record contact for \(uuid): \(error.localizedDescription)")
        }
    }

    /// A contact attempt ended without a reading. Rate-limited to one per
    /// `failureRateLimit` so a burst of triggers cannot exhaust the attempt
    /// gate in an evening.
    func recordFailedContact(_ uuid: String) async {
        let now = self.now()
        do {
            var counted = false
            let updated = try await repository.modifyDevice(uuid: uuid) { device in
                if let last = device.lastFailedContactAt, now.timeIntervalSince(last) < Self.failureRateLimit {
                    return
                }
                device.failedContactAttempts += 1
                device.lastFailedContactAt = now
                counted = true
            }
            guard let updated, counted else { return }
            AppLogger.sensor.info("🔋 \(updated.name): failed contact #\(updated.failedContactAttempts) (silent \(SensorHealth.daysSilent(since: updated.lastReading, now: now)) d)")
            await evaluateAndNotify(uuid: uuid)
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to record failure for \(uuid): \(error.localizedDescription)")
        }
    }

    // MARK: - Battery

    private func persistBattery(uuid: String, battery: Int, firmware: String) async {
        let now = self.now()
        do {
            guard let updated = try await repository.modifyDevice(uuid: uuid, { device in
                device.battery = Int16(clamping: battery)
                device.firmware = firmware
                device.batteryUpdatedAt = now
                // lastUpdate untouched: a battery read is not a measurement
            }) else { return }
            AppLogger.sensor.info("🔋 \(updated.name): battery \(battery) %, firmware \(firmware) persisted")

            if battery > Self.newCellThreshold {
                defaults.removeObject(forKey: DefaultsKey.lowBatteryNotified(for: uuid))
            }
            await evaluateAndNotify(uuid: uuid)
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to persist battery for \(uuid): \(error.localizedDescription)")
        }
    }

    // MARK: - Verdict → notification

    private func evaluateAndNotify(uuid: String) async {
        let now = self.now()
        let all: [FlowerDeviceDTO]
        do {
            all = try await repository.getAllDevices()
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to load devices: \(error.localizedDescription)")
            return
        }
        guard let device = all.first(where: { $0.uuid == uuid }) else { return }
        let peers = all.filter { $0.uuid != uuid }
        let health = SensorHealth.evaluate(device, peers: peers, now: now)

        switch health {
        case .unreachable(let since, let lastKnownBattery, let confirmedByPeer):
            let key = DefaultsKey.unreachableNotified(for: uuid)
            let prior = defaults.string(forKey: key).flatMap(UnreachableFlavour.init(rawValue:))
            let flavour: UnreachableFlavour = confirmedByPeer ? .confirmed : .unconfirmed
            // Notify on the first crossing, and once more on the upgrade
            // unconfirmed → confirmed. Never on a downgrade, never twice.
            let shouldNotify = prior == nil || (prior == .unconfirmed && flavour == .confirmed)
            guard shouldNotify else { return }
            AppLogger.sensor.warning("🔋 \(device.name): unreachable (\(flavour.rawValue)), \(device.failedContactAttempts) attempts, silent \(SensorHealth.daysSilent(since: since, now: now)) d, battery \(lastKnownBattery.map(String.init) ?? "unknown")")
            await notifier.notifyUnreachable(device: device, since: since, lastKnownBattery: lastKnownBattery, confirmedByPeer: confirmedByPeer, now: now)
            defaults.set(flavour.rawValue, forKey: key)

        case .batteryLow(let percent), .batteryCritical(let percent):
            let key = DefaultsKey.lowBatteryNotified(for: uuid)
            guard !defaults.bool(forKey: key) else { return }
            AppLogger.sensor.warning("🔋 \(device.name): battery low (\(percent) %)")
            await notifier.notifyLowBattery(device: device, percent: percent)
            defaults.set(true, forKey: key)

        case .ok, .batteryUnknown:
            break
        }
    }
}

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
    /// Successful contacts closer together than this count once. A history
    /// sync replays thousands of entries as `.historicalData` events within
    /// seconds; each one would otherwise write the device and re-read the
    /// whole store to evaluate every peer. The bookkeeping a success performs
    /// — counter to 0, marker cleared — is idempotent, so collapsing a burst
    /// into its first event loses nothing.
    static let successCoalesceWindow: TimeInterval = 60

    // MARK: - Dependencies (tests inject)

    private let events: AnyPublisher<DeviceEvent, Never>
    private let repository: FlowerDeviceRepository
    private let notifier: SensorHealthNotifying
    private let defaults: UserDefaults
    private let now: () -> Date
    private var subscription: AnyCancellable?
    /// Tail of the chain of in-flight event handlers, **per device**. The
    /// handlers suspend at their `await`s and `@MainActor` does not serialize
    /// across a suspension point, so two unchained tasks for the same uuid
    /// could both read a nil marker and both notify. Each new task awaits its
    /// predecessor for the same uuid, which also preserves arrival order.
    ///
    /// Keyed by uuid rather than global: a slow handler for one device (a
    /// history sync hammering the store) must not block the events of every
    /// other device behind it. Devices share no mutable state here — each
    /// device's markers and counters are its own.
    private var pending: [String: Task<Void, Never>] = [:]
    /// Last recorded successful contact per device, for the coalesce window.
    private var lastSuccessAt: [String: Date] = [:]

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
                guard let self else { return }
                let uuid = event.uuid
                let previous = self.pending[uuid]
                self.pending[uuid] = Task { @MainActor [weak self] in
                    await previous?.value
                    await self?.handle(event)
                }
            }
    }

    /// Forget a device's notification markers. Call when the device is deleted;
    /// a re-paired sensor keeps its peripheral UUID and must start clean.
    func forgetDevice(_ uuid: String) {
        defaults.removeObject(forKey: DefaultsKey.unreachableNotified(for: uuid))
        defaults.removeObject(forKey: DefaultsKey.lowBatteryNotified(for: uuid))
        lastSuccessAt[uuid] = nil
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
    /// Evaluates this device — a sensor coming back at 20 % is `.batteryLow`
    /// right away — and then every other sensor, because this device may be
    /// the witness that upgrades a neighbour's verdict to confirmed.
    ///
    /// Coalesced per `successCoalesceWindow`: the gate is checked before any
    /// repository call so a history sync's burst costs one write, not one per
    /// replayed entry.
    func recordSuccessfulContact(_ uuid: String) async {
        let now = self.now()
        if let last = lastSuccessAt[uuid], now.timeIntervalSince(last) < Self.successCoalesceWindow {
            return
        }
        lastSuccessAt[uuid] = now

        do {
            guard try await repository.modifyDevice(uuid: uuid, { device in
                device.failedContactAttempts = 0
                device.lastFailedContactAt = nil
            }) != nil else { return }
            defaults.removeObject(forKey: DefaultsKey.unreachableNotified(for: uuid))

            // One fetch for self and every peer verdict
            let all = try await repository.getAllDevices()
            await evaluateAndNotify(uuid: uuid, devices: all)
            for other in all where other.uuid != uuid && other.isSensor {
                await evaluateAndNotify(uuid: other.uuid, devices: all)
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
            await evaluateAndNotify(uuid: uuid, devices: try await repository.getAllDevices())
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
            await evaluateAndNotify(uuid: uuid, devices: try await repository.getAllDevices())
        } catch {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: failed to persist battery for \(uuid): \(error.localizedDescription)")
        }
    }

    // MARK: - Verdict → notification

    /// `devices` is the caller's single snapshot of the store, taken after its
    /// own write: evaluating a device and its peers must not re-fetch per peer.
    private func evaluateAndNotify(uuid: String, devices: [FlowerDeviceDTO]) async {
        let now = self.now()
        guard let device = devices.first(where: { $0.uuid == uuid }) else { return }
        let peers = devices.filter { $0.uuid != uuid }
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

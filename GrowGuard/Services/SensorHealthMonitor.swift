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
    /// Tail of the chain of in-flight event handlers. Each new task awaits its
    /// predecessor's `.value` before handling its own event, which serializes
    /// every handler and preserves arrival order.
    ///
    /// The chain is **global, not per device**. `@MainActor` does not serialize
    /// across a suspension point, and `evaluateAndNotify` reads a device's
    /// notification marker, suspends at `await notifier…`, then writes it. A
    /// success does not only evaluate its own device: `recordSuccessfulContact`
    /// evaluates every peer, because the delivering sensor may be the witness
    /// that upgrades a neighbour's verdict. So a handler for device A touches
    /// device C's marker, and a handler for device B touches it too — two
    /// sensors delivering in one wake would both read C's nil marker inside
    /// that suspension and both notify. Devices therefore do share mutable
    /// state and one FIFO is the only correct chain.
    ///
    /// Cheap enough: the 60 s success coalescing already collapses a history
    /// sync's thousands of replayed entries into one handled event, so the
    /// queue this chain serializes is short.
    private var pending: Task<Void, Never>?
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
                _ = self.enqueue { [weak self] in await self?.handle(event) }
            }
    }

    /// Runs `work` after everything already queued. External callers (the wake
    /// service) must come through here; `handle(_:)` already runs ON the chain
    /// and therefore calls the unchained internals — enqueueing from inside a
    /// chained task would await itself.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        pending = task
        return task
    }

    /// Chained variant of `recordFailedContact` for callers outside the event
    /// stream. Returns when the record has been processed — the wake service
    /// holds its background-task assertion until then.
    func enqueueFailedContact(_ uuid: String) async {
        await enqueue { [weak self] in await self?.recordFailedContact(uuid) }.value
    }

    /// Chained variant of `forgetDevice` for the delete path. A handler can be
    /// suspended mid-notify for this device and would write its marker back
    /// after an immediate forget; queued behind it, the forget wins. Await it
    /// before cancelling the device's notifications.
    func enqueueForgetDevice(_ uuid: String) async {
        await enqueue { [weak self] in self?.forgetDevice(uuid) }.value
    }

    /// Forget a device's notification markers: a re-paired sensor keeps its
    /// peripheral UUID and must start clean. Unchained internal — the delete
    /// path calls `enqueueForgetDevice`.
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

        do {
            guard try await repository.modifyDevice(uuid: uuid, { device in
                device.failedContactAttempts = 0
                device.lastFailedContactAt = nil
            }) != nil else { return }
            // Stamped only now: the window means "a success was persisted".
            // Stamping before the write let an unknown device or a throwing
            // store swallow the next minute of real successes. Handlers are
            // serialized on one chain, so nothing slips through the gate
            // while this write is in flight.
            lastSuccessAt[uuid] = now
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
        // The decoder hands up a raw UInt8, so a garbled read can say 255.
        // Rejected, not clamped: a clamped 255 would be stored as a healthy
        // 100 % *and* pass the raw new-cell check, clearing the low-battery
        // marker and silencing the real alert. Out of range = no reading.
        guard (0...100).contains(battery) else {
            AppLogger.sensor.error("🔋 SensorHealthMonitor: ignoring out-of-range battery \(battery) for \(uuid)")
            return
        }
        do {
            guard let updated = try await repository.modifyDevice(uuid: uuid, { device in
                device.battery = Int16(battery)
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
            // Marker only on a real submission: it means "the user has been
            // told". Setting it after a failed `center.add` swallowed the
            // alert for the whole episode.
            guard await notifier.notifyUnreachable(device: device, since: since, lastKnownBattery: lastKnownBattery, confirmedByPeer: confirmedByPeer, now: now) else {
                AppLogger.sensor.warning("🔋 \(device.name): unreachable notification was not submitted — marker left unset, will retry")
                return
            }
            defaults.set(flavour.rawValue, forKey: key)

        case .batteryLow(let percent), .batteryCritical(let percent):
            let key = DefaultsKey.lowBatteryNotified(for: uuid)
            guard !defaults.bool(forKey: key) else { return }
            AppLogger.sensor.warning("🔋 \(device.name): battery low (\(percent) %)")
            guard await notifier.notifyLowBattery(device: device, percent: percent) else {
                AppLogger.sensor.warning("🔋 \(device.name): low-battery notification was not submitted — marker left unset, will retry")
                return
            }
            defaults.set(true, forKey: key)

        case .ok, .batteryUnknown:
            break
        }
    }
}

//
//  BackgroundBLEWakeService.swift
//  GrowGuard
//
//  Handles BLE wakes from background-armed pending connects (spec:
//  docs/superpowers/specs/2026-06-12-background-ble-design.md).
//  Triggers (BGTask / silent push / enter-background) only ARM pending
//  connects via ConnectionPoolManager; when iOS completes one and wakes
//  the app, this service does auth → live read → save → dry-plant check
//  → disconnect → disarm. It never re-arms (wake-loop prevention).
//

import Foundation
import Combine
import UIKit

@MainActor
final class BackgroundBLEWakeService {

    static let shared = BackgroundBLEWakeService()

    // MARK: - Injected dependencies (tests override)

    private let pool: ConnectionPoolManager
    private let scheduler: BLEScheduler
    private let loadSensorDeviceUUIDs: () async -> [String]
    /// Returns true if the sample was valid and stored
    private let saveSample: (SensorDataTemp, String, SensorDataSource) async -> Bool
    /// Dry-plant notification check for one device
    private let runStatusCheck: (String) async -> Void
    /// Sensor health bookkeeping: a contact attempt ended without a reading
    private let recordFailedContact: (String) async -> Void
    private let beginBackgroundTask: () -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private let notificationCenter: NotificationCenter

    // MARK: - State

    /// Arm source per device so saved samples carry the right SensorDataSource
    private var armSources: [String: SensorDataSource] = [:]
    private var activeReads: [String: WakeRead] = [:]
    private var armedConnectionSubscription: AnyCancellable?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    /// iOS grants ~10 s after a BLE wake; auth alone can take 4 s
    private let wakeReadTimeout: TimeInterval = 9.0

    private final class WakeRead {
        var cancellables: Set<AnyCancellable> = []
        var timeoutTask: BLEScheduledTask?
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var liveDataRequested = false
        var finished = false
    }

    init(pool: ConnectionPoolManager? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         loadSensorDeviceUUIDs: (() async -> [String])? = nil,
         saveSample: ((SensorDataTemp, String, SensorDataSource) async -> Bool)? = nil,
         runStatusCheck: ((String) async -> Void)? = nil,
         recordFailedContact: ((String) async -> Void)? = nil,
         beginBackgroundTask: (() -> UIBackgroundTaskIdentifier)? = nil,
         endBackgroundTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil,
         notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.pool = pool ?? ConnectionPoolManager.shared
        self.scheduler = scheduler
        self.loadSensorDeviceUUIDs = loadSensorDeviceUUIDs ?? {
            let devices = (try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()) ?? []
            return devices.filter { $0.isSensor }.map { $0.uuid }
        }
        self.saveSample = saveSample ?? { data, uuid, source in
            (try? await PlantMonitorService.shared.validateSensorData(data, deviceUUID: uuid, source: source)) != nil
        }
        self.runStatusCheck = runStatusCheck ?? { uuid in
            guard let device = try? await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: uuid) else { return }
            try? await PlantMonitorService.shared.checkDeviceStatus(device: device)
        }
        self.recordFailedContact = recordFailedContact ?? { uuid in
            await SensorHealthMonitor.shared.recordFailedContact(uuid)
        }
        self.beginBackgroundTask = beginBackgroundTask ?? {
            var id: UIBackgroundTaskIdentifier = .invalid
            id = UIApplication.shared.beginBackgroundTask(withName: "ble-wake-read") {
                UIApplication.shared.endBackgroundTask(id)
            }
            return id
        }
        self.endBackgroundTask = endBackgroundTask ?? { id in
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: - Lifecycle

    /// Must be called in didFinishLaunching, right after the pool exists,
    /// so wakes via state restoration are handled
    func start() {
        guard armedConnectionSubscription == nil else { return }

        armedConnectionSubscription = pool.armedConnectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceUUID in
                self?.handleArmedConnection(deviceUUID)
            }

        foregroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.disarmAll()
            }
        }

        // SwiftUI scene lifecycle: UIKit never calls the app delegate's
        // applicationDidEnterBackground — the UIApplication notification is
        // posted in every lifecycle, so arming hangs off it instead
        backgroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.armAll(source: .backgroundTask)
            }
        }
    }

    /// Arms pending connects for all sensors. Cheap (~1 s) — call from
    /// BGAppRefreshTask, silent push, and applicationDidEnterBackground.
    func armAll(source: SensorDataSource) async {
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("🛡 Background arm: \(uuids.count) sensor(s), source \(source.rawValue)")
        // Arm every device first, do the bookkeeping afterwards: arming is the
        // time-critical part (the didEnterBackground path has ~1 s) and must
        // not wait on a repository write for an earlier device. Only the
        // *reading* of the armed flag has to happen before arming —
        // armBackgroundConnect re-inserts an already-armed device, so the flag
        // is no longer distinguishable once the loop has passed it.
        var silentSincePreviousTrigger: [String] = []
        for uuid in uuids {
            // A connect iOS actually held open since the previous trigger,
            // which never completed, is the dead-sensor signature: a dead
            // (non-advertising) sensor produces no CoreBluetooth callback at
            // all, and this is the only place that silence is visible. Merely
            // *armed* is not enough — a device stays armed when the radio was
            // off or the peripheral was not in the retrieve cache, and then
            // the app never asked it anything.
            if pool.hasPendingBackgroundConnect(uuid) && activeReads[uuid] == nil {
                silentSincePreviousTrigger.append(uuid)
            }
            armSources[uuid] = source
            pool.armBackgroundConnect(for: uuid)
        }

        for uuid in silentSincePreviousTrigger {
            AppLogger.sensor.info("🔋 \(uuid) still armed from the previous trigger — counting a failed contact")
            await recordFailedContact(uuid)
        }
    }

    func disarmAll() {
        pool.disarmAllBackgroundConnects()
        armSources.removeAll()
    }

    // MARK: - Wake handling

    private func handleArmedConnection(_ deviceUUID: String) {
        guard activeReads[deviceUUID] == nil else { return }

        AppLogger.ble.info("🛡 BLE wake: armed connect completed for \(deviceUUID)")
        let read = WakeRead()
        read.backgroundTaskID = beginBackgroundTask()
        activeReads[deviceUUID] = read

        let connection = pool.getConnection(for: deviceUUID)

        connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                switch state {
                case .authenticated:
                    guard !read.liveDataRequested else { return }
                    read.liveDataRequested = true
                    connection.requestLiveData()
                case .error, .disconnected:
                    self.finishRead(for: deviceUUID, success: false)
                default:
                    break
                }
            }
            .store(in: &read.cancellables)

        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .first()
            .sink { [weak self] sensorData in
                guard let self else { return }
                let source = self.armSources[deviceUUID] ?? .backgroundTask
                Task { @MainActor in
                    let saved = await self.saveSample(sensorData, deviceUUID, source)
                    if saved {
                        await self.runStatusCheck(deviceUUID)
                    }
                    self.finishRead(for: deviceUUID, success: saved)
                }
            }
            .store(in: &read.cancellables)

        read.timeoutTask = scheduler.schedule(after: wakeReadTimeout) { [weak self] in
            Task { @MainActor in
                self?.finishRead(for: deviceUUID, success: false)
            }
        }
    }

    private func finishRead(for deviceUUID: String, success: Bool) {
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        read.finished = true
        read.timeoutTask?.cancel()
        read.cancellables.removeAll()
        activeReads[deviceUUID] = nil
        armSources[deviceUUID] = nil

        // One trigger, one chance: never re-arm from a wake (wake-loop
        // prevention — the sensor advertises continuously in range)
        pool.disarmBackgroundConnect(for: deviceUUID)
        pool.disconnect(from: deviceUUID)

        if success {
            BackgroundTaskTracker.shared.recordRefreshTaskExecution(result: BackgroundFetchResult(
                successfulDevices: [deviceUUID],
                failedDevices: [],
                totalDataPoints: 1,
                duration: 0
            ))
            endBackgroundTask(read.backgroundTaskID)
        } else {
            // Keep the background-task assertion until the failed contact is
            // persisted; ending it first lets iOS suspend us mid-write.
            let backgroundTaskID = read.backgroundTaskID
            Task { @MainActor in
                await self.recordFailedContact(deviceUUID)
                self.endBackgroundTask(backgroundTaskID)
            }
        }

        AppLogger.ble.info("🛡 BLE wake read finished for \(deviceUUID) (success: \(success))")
    }
}

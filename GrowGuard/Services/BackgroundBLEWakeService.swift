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
    private let beginBackgroundTask: () -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private let notificationCenter: NotificationCenter
    private let tracker: BackgroundTaskTracker

    // MARK: - State

    /// Arm trigger per device so saved samples carry the right
    /// SensorDataSource and the debug history names what caused the read
    private var armTriggers: [String: BackgroundTrigger] = [:]
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
        let startedAt = Date()
        /// nil when iOS relaunched the app for the connect (arm state lost)
        var trigger: BackgroundTrigger?
    }

    init(pool: ConnectionPoolManager? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         loadSensorDeviceUUIDs: (() async -> [String])? = nil,
         saveSample: ((SensorDataTemp, String, SensorDataSource) async -> Bool)? = nil,
         runStatusCheck: ((String) async -> Void)? = nil,
         beginBackgroundTask: (() -> UIBackgroundTaskIdentifier)? = nil,
         endBackgroundTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil,
         notificationCenter: NotificationCenter = .default,
         tracker: BackgroundTaskTracker = .shared) {
        self.notificationCenter = notificationCenter
        self.tracker = tracker
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
                await self?.armAll(trigger: .enterBackground)
            }
        }
    }

    /// Arms pending connects for all sensors. Cheap (~1 s) — call from
    /// BGAppRefreshTask, silent push, and applicationDidEnterBackground.
    /// - Returns: How many sensors were armed
    @discardableResult
    func armAll(trigger: BackgroundTrigger) async -> Int {
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("🛡 Background arm: \(uuids.count) sensor(s), trigger \(trigger.rawValue)")
        for uuid in uuids {
            armTriggers[uuid] = trigger
            pool.armBackgroundConnect(for: uuid)
        }
        return uuids.count
    }

    func disarmAll() {
        pool.disarmAllBackgroundConnects()
        armTriggers.removeAll()
    }

    // MARK: - Wake handling

    private func handleArmedConnection(_ deviceUUID: String) {
        guard activeReads[deviceUUID] == nil else { return }

        AppLogger.ble.info("🛡 BLE wake: armed connect completed for \(deviceUUID)")
        let read = WakeRead()
        // Captured now: foregrounding disarms and clears armTriggers while
        // this read may still be running
        read.trigger = armTriggers[deviceUUID]
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
                case .error:
                    self.finishRead(for: deviceUUID, outcome: .connectionError)
                case .disconnected:
                    self.finishRead(for: deviceUUID, outcome: .disconnected)
                default:
                    break
                }
            }
            .store(in: &read.cancellables)

        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .first()
            .sink { [weak self, trigger = read.trigger] sensorData in
                guard let self else { return }
                let source = trigger?.sensorDataSource ?? .backgroundTask
                Task { @MainActor in
                    let saved = await self.saveSample(sensorData, deviceUUID, source)
                    if saved {
                        await self.runStatusCheck(deviceUUID)
                    }
                    self.finishRead(for: deviceUUID, outcome: saved ? .saved : .sampleRejected)
                }
            }
            .store(in: &read.cancellables)

        read.timeoutTask = scheduler.schedule(after: wakeReadTimeout) { [weak self] in
            Task { @MainActor in
                self?.finishRead(for: deviceUUID, outcome: .timedOut)
            }
        }
    }

    private func finishRead(for deviceUUID: String, outcome: WakeReadOutcome) {
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        read.finished = true
        read.timeoutTask?.cancel()
        read.cancellables.removeAll()
        activeReads[deviceUUID] = nil
        armTriggers[deviceUUID] = nil

        // One trigger, one chance: never re-arm from a wake (wake-loop
        // prevention — the sensor advertises continuously in range)
        pool.disarmBackgroundConnect(for: deviceUUID)
        pool.disconnect(from: deviceUUID)

        tracker.recordWakeRead(
            trigger: read.trigger,
            outcome: outcome,
            duration: Date().timeIntervalSince(read.startedAt)
        )

        endBackgroundTask(read.backgroundTaskID)
        AppLogger.ble.info("🛡 BLE wake read finished for \(deviceUUID) (\(outcome.rawValue))")
    }
}

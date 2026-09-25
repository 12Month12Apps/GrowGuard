//
//  BackgroundBLEWakeService.swift
//  Vattna
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
    /// Newest stored history date; nil = never synced, skip history
    private let loadHistoryBoundary: (String) async -> Date?
    private let saveHistoricalEntry: (HistoricalSensorData, String) async -> Void

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
        enum Phase {
            /// Waiting for authentication and the live sample
            case live
            /// Sample received and being persisted: the link is no longer
            /// needed, so a disconnect must not turn the read into a failure
            case saving
            /// Live sample stored, fetching entries newer than the stored history
            case history
        }

        var cancellables: Set<AnyCancellable> = []
        var timeoutTask: BLEScheduledTask?
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        var liveDataRequested = false
        var phase: Phase = .live
        /// Only this read's own flow may be cleaned up and only its own
        /// boundary cleared — the pooled connection is shared
        var startedHistoryFlow = false
        /// Answers whether the live sample actually reached the store
        var saveTask: Task<Bool, Never>?
        /// Chained history writes, awaited before the background task ends
        var historySaves: Task<Void, Never>?
        var historyEntries = 0
        var historyCompletionObserver: NSObjectProtocol?
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
         tracker: BackgroundTaskTracker = .shared,
         loadHistoryBoundary: ((String) async -> Date?)? = nil,
         saveHistoricalEntry: ((HistoricalSensorData, String) async -> Void)? = nil) {
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
        self.loadHistoryBoundary = loadHistoryBoundary ?? { uuid in
            try? await RepositoryManager.shared.sensorDataRepository.getLatestSensorDate(for: uuid, source: .historyLoading)
        }
        self.saveHistoricalEntry = saveHistoricalEntry ?? { entry, uuid in
            _ = try? await PlantMonitorService.shared.validateHistoricSensorData(entry, deviceUUID: uuid)
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
                case .error, .disconnected:
                    switch read.phase {
                    case .live:
                        let outcome: WakeReadOutcome = state == .disconnected ? .disconnected : .connectionError
                        self.finishRead(for: deviceUUID, outcome: outcome)
                    case .saving:
                        return
                    case .history:
                        // Live sample is stored; keep what history arrived
                        self.finishRead(for: deviceUUID, outcome: .saved)
                    }
                default:
                    break
                }
            }
            .store(in: &read.cancellables)

        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .first()
            .sink { [weak self, trigger = read.trigger] sensorData in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                read.phase = .saving
                let source = trigger?.sensorDataSource ?? .backgroundTask
                // Held so a timeout during the write can wait for its result
                // instead of guessing whether the sample was persisted
                let saveTask = Task { @MainActor in
                    await self.saveSample(sensorData, deviceUUID, source)
                }
                read.saveTask = saveTask
                Task { @MainActor in
                    let saved = await saveTask.value
                    guard let read = self.activeReads[deviceUUID], !read.finished else { return }
                    guard saved else {
                        self.finishRead(for: deviceUUID, outcome: .sampleRejected)
                        return
                    }
                    await self.runStatusCheck(deviceUUID)
                    await self.fetchNewHistory(for: deviceUUID, connection: connection)
                }
            }
            .store(in: &read.cancellables)

        read.timeoutTask = scheduler.schedule(after: wakeReadTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                switch read.phase {
                case .live:
                    self.finishRead(for: deviceUUID, outcome: .timedOut)
                case .saving:
                    // Out of time while the sample is being written: only the
                    // store can say whether it was persisted
                    let stored = await read.saveTask?.value ?? false
                    self.finishRead(for: deviceUUID, outcome: stored ? .saved : .sampleRejected)
                case .history:
                    // The live sample is stored; keep what history arrived
                    self.finishRead(for: deviceUUID, outcome: .saved)
                }
            }
        }
    }

    /// Appends the entries recorded since the last stored history entry.
    /// A full sync never fits the wake window, so without stored history
    /// this is left to the details screen and BGProcessing.
    private func fetchNewHistory(for deviceUUID: String, connection: DeviceConnection) async {
        let boundary = await loadHistoryBoundary(deviceUUID)
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        guard let boundary else {
            finishRead(for: deviceUUID, outcome: .saved)
            return
        }

        // A BGProcessing sync (or a user sync that kept running when the app
        // was backgrounded) already owns this pooled connection: its boundary
        // and its entries are not this read's to touch
        guard !connection.isHistoryFlowActive else {
            AppLogger.ble.info("🛡 BLE wake: history flow already active for \(deviceUUID), leaving it to its owner")
            finishRead(for: deviceUUID, outcome: .saved)
            return
        }

        read.phase = .history
        connection.setHistoryStopBoundary(boundary)

        connection.historicalDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self, let read = self.activeReads[deviceUUID] else { return }
                // Written one after another and awaited before the background
                // task ends, so iOS cannot suspend the app mid-write; counted
                // only once actually stored
                let pending = read.historySaves
                read.historySaves = Task { @MainActor in
                    await pending?.value
                    await self.saveHistoricalEntry(entry, deviceUUID)
                    read.historyEntries += 1
                }
            }
            .store(in: &read.cancellables)

        read.historyCompletionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let completedUUID = notification.object as? String
            Task { @MainActor in
                guard completedUUID == deviceUUID else { return }
                self?.finishRead(for: deviceUUID, outcome: .saved)
            }
        }

        connection.startHistoryDataFlow()

        // Not authenticated any more (link lost while saving), already busy
        // or missing characteristic: no completion will ever be posted
        if !connection.isHistoryFlowActive {
            connection.setHistoryStopBoundary(nil)
            finishRead(for: deviceUUID, outcome: .saved)
            return
        }
        read.startedHistoryFlow = true
    }

    private func finishRead(for deviceUUID: String, outcome: WakeReadOutcome) {
        guard let read = activeReads[deviceUUID], !read.finished else { return }
        read.finished = true
        read.timeoutTask?.cancel()
        read.cancellables.removeAll()
        if let observer = read.historyCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        activeReads[deviceUUID] = nil
        armTriggers[deviceUUID] = nil

        // One trigger, one chance: never re-arm from a wake (wake-loop
        // prevention — the sensor advertises continuously in range)
        pool.disarmBackgroundConnect(for: deviceUUID)

        let connection = pool.getConnection(for: deviceUUID)
        if read.startedHistoryFlow {
            // An active flow makes the pool auto-reconnect to resume it
            if connection.isHistoryFlowActive {
                connection.cleanupHistoryFlow()
            }
            // The boundary this read set must never cut a later foreground full sync short
            connection.setHistoryStopBoundary(nil)
        }
        // A flow owned by someone else still needs the link
        if !connection.isHistoryFlowActive {
            pool.disconnect(from: deviceUUID)
        }

        // Entries may still be on their way into the store: the background
        // task has to outlive them, and the tracker counts only what landed
        if let pendingSaves = read.historySaves {
            Task { @MainActor in
                await pendingSaves.value
                self.completeRead(read, deviceUUID: deviceUUID, outcome: outcome)
            }
        } else {
            completeRead(read, deviceUUID: deviceUUID, outcome: outcome)
        }
    }

    private func completeRead(_ read: WakeRead, deviceUUID: String, outcome: WakeReadOutcome) {
        tracker.recordWakeRead(
            trigger: read.trigger,
            outcome: outcome,
            duration: Date().timeIntervalSince(read.startedAt),
            historyEntries: read.historyEntries
        )

        endBackgroundTask(read.backgroundTaskID)
        AppLogger.ble.info("🛡 BLE wake read finished for \(deviceUUID) (\(outcome.rawValue))")
    }
}

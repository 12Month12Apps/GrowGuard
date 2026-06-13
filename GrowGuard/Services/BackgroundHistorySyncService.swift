//
//  BackgroundHistorySyncService.swift
//  GrowGuard
//
//  Runs full history syncs inside BGProcessingTask windows (minutes of
//  runtime, unlike the ~30 s of BGAppRefreshTask). Sequential per device;
//  the expiration handler suspends the in-flight flow so a later window
//  can resume while the process lives. Spec:
//  docs/superpowers/specs/2026-06-12-background-ble-design.md
//

import Foundation
import Combine

@MainActor
final class BackgroundHistorySyncService {

    static let shared = BackgroundHistorySyncService()

    // MARK: - Injected dependencies (tests override)

    private let pool: ConnectionPoolManager
    private let scheduler: BLEScheduler
    private let loadSensorDeviceUUIDs: () async -> [String]
    private let saveHistoricalEntry: (HistoricalSensorData, String) async -> Void

    /// Hard per-device cap; BGProcessing windows are usually several minutes
    private let perDeviceTimeout: TimeInterval = 240

    // MARK: - State

    private var expirationRequested = false
    private var currentDeviceUUID: String?
    private var currentContinuation: CheckedContinuation<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var completionObserver: NSObjectProtocol?
    private var timeoutTask: BLEScheduledTask?

    init(pool: ConnectionPoolManager? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         loadSensorDeviceUUIDs: (() async -> [String])? = nil,
         saveHistoricalEntry: ((HistoricalSensorData, String) async -> Void)? = nil) {
        self.pool = pool ?? ConnectionPoolManager.shared
        self.scheduler = scheduler
        self.loadSensorDeviceUUIDs = loadSensorDeviceUUIDs ?? {
            let devices = (try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()) ?? []
            return devices.filter { $0.isSensor }.map { $0.uuid }
        }
        self.saveHistoricalEntry = saveHistoricalEntry ?? { entry, uuid in
            _ = try? await PlantMonitorService.shared.validateHistoricSensorData(entry, deviceUUID: uuid)
        }
    }

    // MARK: - Public API

    func syncAllDevices() async {
        expirationRequested = false
        let uuids = await loadSensorDeviceUUIDs()
        AppLogger.ble.info("📚 Background history sync: \(uuids.count) sensor(s)")
        for uuid in uuids {
            guard !expirationRequested else { break }
            await syncDevice(uuid)
        }
        AppLogger.ble.info("📚 Background history sync finished (expired: \(self.expirationRequested))")
    }

    /// Called from the BGProcessingTask expiration handler: suspends the
    /// in-flight flow (progress kept in DeviceConnection for resume) and
    /// makes syncAllDevices return.
    func requestExpiration() {
        expirationRequested = true
        guard let uuid = currentDeviceUUID else { return }
        AppLogger.ble.bleWarning("📚 History sync expiring — suspending device \(uuid)")
        pool.getConnection(for: uuid).suspendHistoryFlow()
        finishCurrentDevice()
    }

    // MARK: - Per-device sync

    private func syncDevice(_ deviceUUID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            currentDeviceUUID = deviceUUID
            currentContinuation = continuation

            let connection = pool.getConnection(for: deviceUUID)

            connection.historicalDataPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] entry in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.saveHistoricalEntry(entry, deviceUUID)
                    }
                }
                .store(in: &cancellables)

            connection.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    if case .error = state {
                        self?.finishCurrentDevice()
                    }
                }
                .store(in: &cancellables)

            completionObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let completedUUID = notification.object as? String
                Task { @MainActor in
                    guard completedUUID == deviceUUID else { return }
                    self?.finishCurrentDevice()
                }
            }

            timeoutTask = scheduler.schedule(after: perDeviceTimeout) { [weak self] in
                Task { @MainActor in
                    AppLogger.ble.bleWarning("📚 History sync timeout for \(deviceUUID)")
                    self?.finishCurrentDevice()
                }
            }

            // Pool contract: every new session needs a fresh retry budget
            pool.resetRetryCounter(for: deviceUUID)
            pool.connect(to: deviceUUID, autoStartHistoryFlow: true)
        }
    }

    private func finishCurrentDevice() {
        guard let continuation = currentContinuation else { return }
        currentContinuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil
        cancellables.removeAll()
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }
        if let uuid = currentDeviceUUID {
            pool.disconnect(from: uuid)
        }
        currentDeviceUUID = nil
        continuation.resume()
    }
}

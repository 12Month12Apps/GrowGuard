//
//  BackgroundSensorDataService.swift
//  GrowGuard
//
//  Service for fetching sensor data in background using ConnectionPool
//

import Foundation
import Combine

/// Result of a background sensor data fetch operation
struct BackgroundFetchResult {
    let successfulDevices: [String]
    let failedDevices: [String]
    let totalDataPoints: Int
    let duration: TimeInterval
}

/// Service that handles background sensor data fetching using the ConnectionPool
/// Designed to work within iOS background task time constraints (~30 seconds)
@MainActor
class BackgroundSensorDataService {

    // MARK: - Singleton

    static let shared = BackgroundSensorDataService()

    // MARK: - Properties

    /// Maximum time allowed for background fetch (25 seconds to be safe within iOS ~30s limit)
    private let maxBackgroundDuration: TimeInterval = 25.0

    /// Timeout per device connection and data fetch
    private let perDeviceTimeout: TimeInterval = 8.0

    /// Subscriptions for managing Combine publishers
    private var cancellables: Set<AnyCancellable> = []

    /// Track devices that have received data in current session
    private var devicesWithData: Set<String> = []

    /// Track devices that failed in current session
    private var failedDevices: Set<String> = []

    /// Current data source for this fetch session
    private var currentSource: SensorDataSource = .backgroundTask

    /// Continuation for async/await bridge
    private var fetchContinuation: CheckedContinuation<BackgroundFetchResult, Never>?

    /// Start time of current fetch operation
    private var fetchStartTime: Date?

    /// Total data points received in current session
    private var dataPointsReceived: Int = 0

    /// Flag to track if fetch is in progress
    private var isFetching: Bool = false

    // MARK: - Initialization

    private init() {
        AppLogger.ble.info("BackgroundSensorDataService initialized")
    }

    // MARK: - Public Methods

    /// Fetches live sensor data from all saved devices in background
    /// This method is optimized for background execution with strict time limits
    /// - Parameter source: The source that triggered this fetch (backgroundTask or backgroundPush)
    /// - Returns: Result containing successful/failed devices and duration
    func fetchSensorDataInBackground(source: SensorDataSource = .backgroundTask) async -> BackgroundFetchResult {
        guard !isFetching else {
            AppLogger.ble.bleWarning("Background fetch already in progress, skipping")
            return BackgroundFetchResult(
                successfulDevices: [],
                failedDevices: [],
                totalDataPoints: 0,
                duration: 0
            )
        }

        // Check if ConnectionPool is enabled
        guard SettingsStore.shared.useConnectionPool else {
            AppLogger.ble.info("ConnectionPool disabled, skipping background fetch")
            return BackgroundFetchResult(
                successfulDevices: [],
                failedDevices: [],
                totalDataPoints: 0,
                duration: 0
            )
        }

        AppLogger.ble.info("Starting background sensor data fetch (source: \(source.rawValue))")

        // Reset state
        isFetching = true
        currentSource = source
        devicesWithData.removeAll()
        failedDevices.removeAll()
        dataPointsReceived = 0
        cancellables.removeAll()
        fetchStartTime = Date()

        // Load all saved devices
        let devices: [FlowerDeviceDTO]
        do {
            devices = try await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
            AppLogger.ble.info("Found \(devices.count) saved device(s) for background fetch")
        } catch {
            AppLogger.ble.bleError("Failed to load devices: \(error.localizedDescription)")
            isFetching = false
            return BackgroundFetchResult(
                successfulDevices: [],
                failedDevices: [],
                totalDataPoints: 0,
                duration: 0
            )
        }

        // Filter to only sensor devices
        let sensorDevices = devices.filter { $0.isSensor }

        guard !sensorDevices.isEmpty else {
            AppLogger.ble.info("No sensor devices found for background fetch")
            isFetching = false
            return BackgroundFetchResult(
                successfulDevices: [],
                failedDevices: [],
                totalDataPoints: 0,
                duration: Date().timeIntervalSince(fetchStartTime ?? Date())
            )
        }

        AppLogger.ble.info("Starting background fetch for \(sensorDevices.count) sensor(s)")

        // Use async/await with continuation
        return await withCheckedContinuation { continuation in
            self.fetchContinuation = continuation

            // Start overall timeout
            self.startOverallTimeout()

            // Connect to each device and request live data
            for device in sensorDevices {
                self.connectAndFetchData(for: device.uuid)
            }
        }
    }

    // MARK: - Private Methods

    /// Connects to a device and fetches live data
    private func connectAndFetchData(for deviceUUID: String) {
        AppLogger.ble.bleConnection("Background: Connecting to device \(deviceUUID)")

        // Get connection from pool
        let connection = ConnectionPoolManager.shared.getConnection(for: deviceUUID)

        // Setup data observer
        setupDataObserver(for: deviceUUID, connection: connection)

        // Setup connection state observer
        setupConnectionObserver(for: deviceUUID, connection: connection)

        // Setup per-device timeout
        startDeviceTimeout(for: deviceUUID)

        // Connect with autoStartHistoryFlow disabled (we only want live data)
        ConnectionPoolManager.shared.connect(to: deviceUUID, autoStartHistoryFlow: false)
    }

    /// Sets up observer for connection state changes
    private func setupConnectionObserver(for deviceUUID: String, connection: DeviceConnection) {
        connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.isFetching else { return }

                switch state {
                case .authenticated:
                    // Device is ready, request live data
                    AppLogger.ble.info("Background: Device \(deviceUUID) authenticated, requesting live data")
                    connection.requestLiveData()

                case .error(let error):
                    AppLogger.ble.bleError("Background: Device \(deviceUUID) error: \(error.localizedDescription)")
                    self.markDeviceFailed(deviceUUID)

                case .disconnected:
                    // Only mark as failed if we haven't received data yet
                    if !self.devicesWithData.contains(deviceUUID) && !self.failedDevices.contains(deviceUUID) {
                        AppLogger.ble.bleWarning("Background: Device \(deviceUUID) disconnected without data")
                        self.markDeviceFailed(deviceUUID)
                    }

                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Sets up observer for sensor data
    private func setupDataObserver(for deviceUUID: String, connection: DeviceConnection) {
        connection.sensorDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sensorData in
                guard let self = self, self.isFetching else { return }

                AppLogger.ble.info("Background: Received live data from device \(deviceUUID)")

                // Validate and save the data
                Task {
                    await self.processAndSaveSensorData(sensorData, deviceUUID: deviceUUID)
                }
            }
            .store(in: &cancellables)
    }

    /// Processes and saves received sensor data
    private func processAndSaveSensorData(_ data: SensorDataTemp, deviceUUID: String) async {
        do {
            // Validate and save using PlantMonitorService with the current source
            if let _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: deviceUUID, source: self.currentSource) {
                AppLogger.ble.info("Background: Saved sensor data for device \(deviceUUID) (source: \(self.currentSource.rawValue))")

                devicesWithData.insert(deviceUUID)
                dataPointsReceived += 1

                // Disconnect after receiving data to save power
                ConnectionPoolManager.shared.disconnect(from: deviceUUID)

                // Check if all devices are done
                checkCompletion()
            }
        } catch {
            AppLogger.ble.bleError("Background: Failed to save data for device \(deviceUUID): \(error.localizedDescription)")
            markDeviceFailed(deviceUUID)
        }
    }

    /// Marks a device as failed
    private func markDeviceFailed(_ deviceUUID: String) {
        guard !devicesWithData.contains(deviceUUID) else { return }

        failedDevices.insert(deviceUUID)
        ConnectionPoolManager.shared.disconnect(from: deviceUUID)
        checkCompletion()
    }

    /// Starts timeout for a specific device
    private func startDeviceTimeout(for deviceUUID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + perDeviceTimeout) { [weak self] in
            guard let self = self, self.isFetching else { return }

            // If device hasn't received data yet, mark as failed
            if !self.devicesWithData.contains(deviceUUID) && !self.failedDevices.contains(deviceUUID) {
                AppLogger.ble.bleWarning("Background: Device \(deviceUUID) timed out")
                self.markDeviceFailed(deviceUUID)
            }
        }
    }

    /// Starts overall timeout for the background fetch operation
    private func startOverallTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + maxBackgroundDuration) { [weak self] in
            guard let self = self, self.isFetching else { return }

            AppLogger.ble.bleWarning("Background: Overall timeout reached, completing fetch")
            self.completeFetch()
        }
    }

    /// Checks if all devices are done (either success or failure)
    private func checkCompletion() {
        // Get total expected devices
        Task {
            do {
                let allDevices = try await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
                let sensorDevices = allDevices.filter { $0.isSensor }

                let totalProcessed = self.devicesWithData.count + self.failedDevices.count

                if totalProcessed >= sensorDevices.count {
                    AppLogger.ble.info("Background: All devices processed (\(self.devicesWithData.count) success, \(self.failedDevices.count) failed)")
                    self.completeFetch()
                }
            } catch {
                AppLogger.ble.bleError("Background: Error checking completion: \(error.localizedDescription)")
            }
        }
    }

    /// Completes the fetch operation and returns result
    private func completeFetch() {
        guard isFetching, let continuation = fetchContinuation else { return }

        isFetching = false
        fetchContinuation = nil

        let duration = Date().timeIntervalSince(fetchStartTime ?? Date())

        // Disconnect any remaining connections
        for deviceUUID in devicesWithData.union(failedDevices) {
            ConnectionPoolManager.shared.disconnect(from: deviceUUID)
        }

        // Clear subscriptions
        cancellables.removeAll()

        let result = BackgroundFetchResult(
            successfulDevices: Array(devicesWithData),
            failedDevices: Array(failedDevices),
            totalDataPoints: dataPointsReceived,
            duration: duration
        )

        AppLogger.ble.info("Background fetch completed: \(result.successfulDevices.count) successful, \(result.failedDevices.count) failed, \(result.totalDataPoints) data points in \(String(format: "%.1f", result.duration))s")

        continuation.resume(returning: result)
    }

    /// Cancels any ongoing background fetch
    func cancelFetch() {
        guard isFetching else { return }

        AppLogger.ble.info("Background: Cancelling fetch")
        completeFetch()
    }
}

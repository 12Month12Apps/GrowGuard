//
//  BLEBenchmark.swift
//  GrowGuard
//
//  Benchmark tool to compare FlowerManager vs ConnectionPool performance
//

import Foundation
import Combine

struct BenchmarkResult {
    let implementation: String
    let connectionTime: TimeInterval
    let authenticationTime: TimeInterval
    let firstEntryTime: TimeInterval
    let totalDownloadTime: TimeInterval
    let totalEntries: Int
    let entriesPerSecond: Double
    let retryCount: Int
    let errorCount: Int
    let successRate: Double

    var summary: String {
        """
        📊 \(implementation) Benchmark Results:
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        ⏱️  Connection:      \(String(format: "%.2f", connectionTime))s
        🔐 Authentication:   \(String(format: "%.2f", authenticationTime))s
        📥 First Entry:      \(String(format: "%.2f", firstEntryTime))s
        ⏳ Total Download:   \(String(format: "%.2f", totalDownloadTime))s
        📊 Entries:          \(totalEntries)
        ⚡️ Speed:            \(String(format: "%.1f", entriesPerSecond)) entries/sec
        🔄 Retries:          \(retryCount)
        ❌ Errors:           \(errorCount)
        ✅ Success Rate:     \(String(format: "%.1f", successRate))%
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """
    }
}

@MainActor
class BLEBenchmark: ObservableObject {
    static let shared = BLEBenchmark()

    @Published var isRunning = false
    @Published var currentTest: String = ""
    @Published var flowerManagerResult: BenchmarkResult?
    @Published var connectionPoolResult: BenchmarkResult?
    @Published var logs: [String] = []

    private var startTime: Date?
    private var connectionStartTime: Date?
    private var authStartTime: Date?
    private var firstEntryTime: Date?
    private var entriesReceived = 0
    private var retryCount = 0
    private var errorCount = 0
    private var isCompleted = false
    private var currentState: String = "disconnected"
    private var totalEntriesToLoad = 0

    private var cancellables = Set<AnyCancellable>()
    private var completionObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Public API

    func runBenchmark(deviceUUID: String) async {
        guard !isRunning else {
            log("⚠️ Benchmark already running")
            return
        }

        isRunning = true
        logs.removeAll()
        flowerManagerResult = nil
        connectionPoolResult = nil

        log("🏁 Starting BLE Benchmark")
        log("Device: \(deviceUUID)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Test 1: FlowerManager (Legacy)
        await testFlowerManager(deviceUUID: deviceUUID)

        // Wait between tests to ensure clean state
        log("⏸️ Waiting 5 seconds between tests for clean state...")
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

        // Test 2: ConnectionPool (New)
        await testConnectionPool(deviceUUID: deviceUUID)

        isRunning = false
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("✅ Benchmark Complete!")

        // Print comparison
        if let fm = flowerManagerResult, let cp = connectionPoolResult {
            printComparison(flowerManager: fm, connectionPool: cp)
        }
    }

    // MARK: - FlowerManager Test

    private func testFlowerManager(deviceUUID: String) async {
        currentTest = "FlowerManager (Legacy)"
        log("\n📱 Testing FlowerManager Implementation...")
        log("⏳ This will download the ENTIRE history - may take several minutes...")

        resetMetrics()
        startTime = Date()

        let flowerManager = FlowerCareManager.shared

        // Subscribe to state changes
        flowerManager.connectionStatePublisher
            .sink { [weak self] state in
                self?.handleFlowerManagerState(state)
            }
            .store(in: &cancellables)

        // Subscribe to progress
        flowerManager.loadingProgressPublisher
            .sink { [weak self] progress in
                let (current, total) = progress
                if current == 1 && self?.firstEntryTime == nil {
                    self?.firstEntryTime = Date()
                }
                self?.entriesReceived = current
                self?.totalEntriesToLoad = total

                // Log every 100 entries or the final entry
                if current % 100 == 0 || current == total {
                    let percentage = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    self?.log("📊 FlowerManager Progress: \(current)/\(total) (\(percentage)%)")
                }
            }
            .store(in: &cancellables)

        // Subscribe to completion notification
        completionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let notificationDeviceUUID = notification.object as? String,
               notificationDeviceUUID == deviceUUID {
                self.log("🎯 FlowerManager: History loading completed notification received")
                self.isCompleted = true
            }
        }

        // Start test
        connectionStartTime = Date()
        flowerManager.connectToKnownDevice(deviceUUID: deviceUUID)

        // Wait for authentication before requesting history
        log("⏳ Waiting for authentication...")
        var authenticated = false
        for _ in 0..<30 { // Max 30 seconds for authentication
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            if currentState == "ready" {
                authenticated = true
                log("✅ Device authenticated, requesting historical data")
                flowerManager.requestHistoricalData()
                break
            }
        }

        if !authenticated {
            log("❌ Authentication timeout - aborting test")
            return
        }

        // Wait for completion (max 10 minutes for full history)
        log("⏱ Waiting up to 10 minutes for complete history download...")
        for i in 0..<600 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            // Log every 30 seconds
            if i > 0 && i % 30 == 0 {
                let elapsed = Date().timeIntervalSince(startTime!)
                log("⏱ Elapsed: \(Int(elapsed))s - Entries: \(entriesReceived)/\(totalEntriesToLoad)")
            }

            if let result = checkFlowerManagerCompletion() {
                flowerManagerResult = result
                let totalTime = Date().timeIntervalSince(startTime!)
                log("✅ FlowerManager test completed in \(String(format: "%.1f", totalTime))s")
                log("📊 Downloaded \(entriesReceived) entries at \(String(format: "%.1f", result.entriesPerSecond)) entries/sec")
                break
            }
        }

        // Cleanup
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }
        flowerManager.disconnect()
        cancellables.removeAll()
    }

    private func handleFlowerManagerState(_ state: FlowerCareManager.ConnectionState) {
        switch state {
        case .connecting:
            currentState = "connecting"
            log("🔗 FlowerManager: Connecting...")
        case .connected:
            currentState = "connected"
            if let start = connectionStartTime {
                let elapsed = Date().timeIntervalSince(start)
                log("✅ FlowerManager: Connected in \(String(format: "%.2f", elapsed))s")
            }
        case .authenticating:
            currentState = "authenticating"
            authStartTime = Date()
            log("🔐 FlowerManager: Authenticating...")
        case .ready:
            currentState = "ready"
            if let start = authStartTime {
                let elapsed = Date().timeIntervalSince(start)
                log("✅ FlowerManager: Authenticated in \(String(format: "%.2f", elapsed))s")
            }
        case .disconnected:
            currentState = "disconnected"
            isCompleted = true
            log("📴 FlowerManager: Disconnected")
        case .error(let error):
            currentState = "error"
            errorCount += 1
            log("❌ FlowerManager: Error - \(error.localizedDescription)")
        }
    }

    private func checkFlowerManagerCompletion() -> BenchmarkResult? {
        guard let start = startTime else { return nil }

        // Check if completed - don't wait for disconnect, just check if loading is complete
        // This ensures we measure the full history download time, not the disconnect time
        if isCompleted && entriesReceived > 0 && entriesReceived == totalEntriesToLoad {
            let totalTime = Date().timeIntervalSince(start)

            let connTime = connectionStartTime.map { startTime in
                Date().timeIntervalSince(startTime)
            } ?? 0
            let authTime = authStartTime.map { startTime in
                Date().timeIntervalSince(startTime)
            } ?? 0
            let firstTime = firstEntryTime.map { time in
                Date().timeIntervalSince(start)
            } ?? 0

            return BenchmarkResult(
                implementation: "FlowerManager",
                connectionTime: connTime,
                authenticationTime: authTime,
                firstEntryTime: firstTime,
                totalDownloadTime: totalTime,
                totalEntries: entriesReceived,
                entriesPerSecond: Double(entriesReceived) / totalTime,
                retryCount: retryCount,
                errorCount: errorCount,
                successRate: entriesReceived > 0 ? 100.0 : 0.0
            )
        }

        return nil
    }

    // MARK: - ConnectionPool Test

    private func testConnectionPool(deviceUUID: String) async {
        currentTest = "ConnectionPool (New)"
        log("\n🔧 Testing ConnectionPool Implementation...")
        log("⏳ This will download the ENTIRE history - may take several minutes...")

        resetMetrics()
        startTime = Date()

        let pool = ConnectionPoolManager.shared

        // Ensure device is fully disconnected first
        log("🔌 Ensuring device is fully disconnected...")
        pool.disconnect(from: deviceUUID)
        try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2 seconds for disconnect to complete

        // Reset retry counter to ensure fresh start
        pool.resetRetryCounter(for: deviceUUID)
        log("🔄 Reset retry counter for clean test")

        let connection = pool.getConnection(for: deviceUUID)

        // Subscribe to state
        connection.connectionStatePublisher
            .sink { [weak self] state in
                self?.handleConnectionPoolState(state)
            }
            .store(in: &cancellables)

        // Subscribe to historical data (only for tracking first entry)
        connection.historicalDataPublisher
            .sink { [weak self] _ in
                if self?.firstEntryTime == nil {
                    self?.firstEntryTime = Date()
                }
            }
            .store(in: &cancellables)

        // Subscribe to progress - this is the REAL counter (includes all entries, even duplicates)
        connection.historyProgressPublisher
            .sink { [weak self] progress in
                let (current, total) = progress

                // First entry detected
                if current == 1 && self?.firstEntryTime == nil {
                    self?.firstEntryTime = Date()
                }

                // Update counters
                self?.entriesReceived = current
                self?.totalEntriesToLoad = total

                // Log every 100 entries or the final entry
                if current % 100 == 0 || current == total {
                    let percentage = total > 0 ? Int(Double(current) / Double(total) * 100) : 0
                    self?.log("📊 ConnectionPool Progress: \(current)/\(total) (\(percentage)%)")
                }
            }
            .store(in: &cancellables)

        // Subscribe to completion notification
        completionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: deviceUUID,
            queue: .main
        ) { [weak self] _ in
            self?.log("🎯 ConnectionPool: History loading completed notification received")
            self?.isCompleted = true
        }

        // Start test
        connectionStartTime = Date()
        pool.connect(to: deviceUUID)
        connection.startHistoryDataFlow()

        // Wait for completion (max 10 minutes for full history)
        log("⏱ Waiting up to 10 minutes for complete history download...")
        for i in 0..<600 {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            // Log every 30 seconds
            if i > 0 && i % 30 == 0 {
                let elapsed = Date().timeIntervalSince(startTime!)
                log("⏱ Elapsed: \(Int(elapsed))s - Entries: \(entriesReceived)/\(totalEntriesToLoad)")
            }

            if let result = checkConnectionPoolCompletion(connection: connection) {
                connectionPoolResult = result
                let totalTime = Date().timeIntervalSince(startTime!)
                log("✅ ConnectionPool test completed in \(String(format: "%.1f", totalTime))s")
                log("📊 Downloaded \(entriesReceived) entries at \(String(format: "%.1f", result.entriesPerSecond)) entries/sec")
                break
            }
        }

        // Cleanup
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }
        pool.disconnect(from: deviceUUID)
        cancellables.removeAll()
    }

    private func handleConnectionPoolState(_ state: DeviceConnection.ConnectionState) {
        switch state {
        case .connecting:
            currentState = "connecting"
            log("🔗 ConnectionPool: Connecting...")
        case .connected:
            currentState = "connected"
            if let start = connectionStartTime {
                let elapsed = Date().timeIntervalSince(start)
                log("✅ ConnectionPool: Connected in \(String(format: "%.2f", elapsed))s")
            }
        case .authenticated:
            currentState = "authenticated"
            if let start = authStartTime {
                let elapsed = Date().timeIntervalSince(start)
                log("✅ ConnectionPool: Authenticated in \(String(format: "%.2f", elapsed))s")
            }
        case .disconnected:
            currentState = "disconnected"
            isCompleted = true
            log("📴 ConnectionPool: Disconnected")
        case .error(let error):
            currentState = "error"
            errorCount += 1
            log("❌ ConnectionPool: Error - \(error.localizedDescription)")
        }
    }

    private func checkConnectionPoolCompletion(connection: DeviceConnection) -> BenchmarkResult? {
        guard let start = startTime else { return nil }

        // Check if completed - don't wait for disconnect, just check if loading is complete
        // This ensures we measure the full history download time, not the disconnect time
        if isCompleted && entriesReceived > 0 && entriesReceived == totalEntriesToLoad {
            let totalTime = Date().timeIntervalSince(start)

            let connTime = connectionStartTime.map { startTime in
                Date().timeIntervalSince(startTime)
            } ?? 0
            let authTime = authStartTime.map { startTime in
                Date().timeIntervalSince(startTime)
            } ?? 0
            let firstTime = firstEntryTime.map { time in
                Date().timeIntervalSince(start)
            } ?? 0

            return BenchmarkResult(
                implementation: "ConnectionPool",
                connectionTime: connTime,
                authenticationTime: authTime,
                firstEntryTime: firstTime,
                totalDownloadTime: totalTime,
                totalEntries: entriesReceived,
                entriesPerSecond: Double(entriesReceived) / totalTime,
                retryCount: retryCount,
                errorCount: errorCount,
                successRate: entriesReceived > 0 ? 100.0 : 0.0
            )
        }

        return nil
    }

    // MARK: - Helpers

    private func resetMetrics() {
        startTime = nil
        connectionStartTime = nil
        authStartTime = nil
        firstEntryTime = nil
        entriesReceived = 0
        retryCount = 0
        errorCount = 0
        isCompleted = false
        currentState = "disconnected"
        totalEntriesToLoad = 0

        // Remove any existing completion observer
        if let observer = completionObserver {
            NotificationCenter.default.removeObserver(observer)
            completionObserver = nil
        }
    }

    private func log(_ message: String) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let logMessage = "[\(formatter.string(from: timestamp))] \(message)"
        logs.append(logMessage)
        print(logMessage)
    }

    private func printComparison(flowerManager: BenchmarkResult, connectionPool: BenchmarkResult) {
        log("\n📊 PERFORMANCE COMPARISON")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        let speedDiff = ((connectionPool.entriesPerSecond - flowerManager.entriesPerSecond) / flowerManager.entriesPerSecond) * 100
        let timeDiff = ((flowerManager.totalDownloadTime - connectionPool.totalDownloadTime) / flowerManager.totalDownloadTime) * 100

        log("\nSpeed Comparison:")
        log("  FlowerManager:   \(String(format: "%.1f", flowerManager.entriesPerSecond)) entries/sec")
        log("  ConnectionPool:  \(String(format: "%.1f", connectionPool.entriesPerSecond)) entries/sec")
        log("  Difference:      \(speedDiff > 0 ? "+" : "")\(String(format: "%.1f", speedDiff))%")

        log("\nTime Comparison:")
        log("  FlowerManager:   \(String(format: "%.2f", flowerManager.totalDownloadTime))s")
        log("  ConnectionPool:  \(String(format: "%.2f", connectionPool.totalDownloadTime))s")
        log("  Difference:      \(timeDiff > 0 ? "+" : "")\(String(format: "%.1f", timeDiff))%")

        log("\nReliability:")
        log("  FlowerManager:   \(flowerManager.errorCount) errors, \(flowerManager.retryCount) retries")
        log("  ConnectionPool:  \(connectionPool.errorCount) errors, \(connectionPool.retryCount) retries")

        let winner = connectionPool.entriesPerSecond > flowerManager.entriesPerSecond ? "ConnectionPool" : "FlowerManager"
        log("\n🏆 Winner: \(winner)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}

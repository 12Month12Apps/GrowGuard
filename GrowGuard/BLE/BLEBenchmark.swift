//
//  BLEBenchmark.swift
//  GrowGuard
//
//  Benchmark tool measuring ConnectionPool history-sync performance
//  against a real sensor (connection, auth, throughput, errors).
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
    let skippedEntries: Int
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
        ⏭️ Skipped Entries:  \(skippedEntries)
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
        connectionPoolResult = nil

        log("🏁 Starting BLE Benchmark")
        log("Device: \(deviceUUID)")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        await testConnectionPool(deviceUUID: deviceUUID)

        isRunning = false
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("✅ Benchmark Complete!")
    }

    // MARK: - ConnectionPool Test

    private func testConnectionPool(deviceUUID: String) async {
        currentTest = "ConnectionPool"
        log("\n🔧 Benchmarking ConnectionPool...")
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

            if let result = checkConnectionPoolCompletion(connection: connection, pool: pool) {
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
            authStartTime = Date()
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

    private func checkConnectionPoolCompletion(connection: DeviceConnection, pool: ConnectionPoolManager) -> BenchmarkResult? {
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
                time.timeIntervalSince(start)
            } ?? 0

            return BenchmarkResult(
                implementation: "ConnectionPool",
                connectionTime: connTime,
                authenticationTime: authTime,
                firstEntryTime: firstTime,
                totalDownloadTime: totalTime,
                totalEntries: entriesReceived,
                entriesPerSecond: Double(entriesReceived) / totalTime,
                retryCount: pool.retryCount(for: connection.deviceUUID),
                errorCount: errorCount,
                skippedEntries: connection.lastSyncSkippedEntries,
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
}

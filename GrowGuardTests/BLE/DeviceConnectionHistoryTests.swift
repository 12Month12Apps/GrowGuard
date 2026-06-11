//
//  DeviceConnectionHistoryTests.swift
//  GrowGuardTests
//
//  Hardware-in-the-loop tests for DeviceConnection History Loading.
//
//  These tests require a real FlowerCare sensor in range. They are skipped
//  unless the TEST_FLOWERCARE_UUID environment variable is set to the
//  CoreBluetooth peripheral identifier of the sensor, e.g. in the
//  HardwareTests test plan or via:
//
//      xcodebuild test ... -only-testing:GrowGuardTests/DeviceConnectionHistoryTests \
//          TEST_FLOWERCARE_UUID=<peripheral-uuid>
//

import XCTest
import Combine
@testable import GrowGuard

@MainActor
final class DeviceConnectionHistoryTests: XCTestCase {

    var connectionPool: ConnectionPoolManager!
    var deviceConnection: DeviceConnection!
    var cancellables: Set<AnyCancellable>!

    // Set via the TEST_FLOWERCARE_UUID environment variable; populated in setUp
    var testDeviceUUID: String!

    override func setUp() async throws {
        try await super.setUp()

        guard let configuredUUID = ProcessInfo.processInfo.environment["TEST_FLOWERCARE_UUID"],
              UUID(uuidString: configuredUUID) != nil else {
            throw XCTSkip("Hardware test skipped: set TEST_FLOWERCARE_UUID to a FlowerCare peripheral UUID to run against a real sensor")
        }
        testDeviceUUID = configuredUUID

        connectionPool = ConnectionPoolManager.shared
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() async throws {
        cancellables?.removeAll()
        if let connection = deviceConnection {
            connectionPool?.disconnect(from: connection.deviceUUID)
        }
        deviceConnection = nil

        try await super.tearDown()
    }

    // MARK: - Full History Loading Test

    func testFullHistoryLoading() async throws {
        print("🧪 Starting full history loading test for device: \(testDeviceUUID)")

        let expectation = XCTestExpectation(description: "Full history loaded")
        expectation.expectedFulfillmentCount = 1

        var receivedEntries: [HistoricalSensorData] = []
        var connectionStates: [String] = []
        var progressUpdates: [(Int, Int)] = []
        var errors: [Error] = []

        // Get connection
        deviceConnection = connectionPool.getConnection(for: testDeviceUUID)

        // Subscribe to connection state
        deviceConnection.connectionStatePublisher
            .sink { state in
                let stateString = self.stateToString(state)
                connectionStates.append(stateString)
                print("📊 Connection State: \(stateString)")
            }
            .store(in: &cancellables)

        // Subscribe to historical data
        deviceConnection.historicalDataPublisher
            .sink { data in
                receivedEntries.append(data)
                print("📥 Received entry #\(receivedEntries.count): temp=\(data.temperature)°C, moisture=\(data.moisture)%, date=\(data.date)")
            }
            .store(in: &cancellables)

        // Subscribe to progress
        deviceConnection.historyProgressPublisher
            .sink { progress in
                let (current, total) = progress
                progressUpdates.append((current, total))
                print("📈 Progress: \(current)/\(total) (\(total > 0 ? Int(Double(current)/Double(total) * 100) : 0)%)")
            }
            .store(in: &cancellables)

        // Listen for completion
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: testDeviceUUID,
            queue: .main
        ) { _ in
            print("✅ History loading completed notification received")
            expectation.fulfill()
        }

        // Start connection and history flow
        print("🔌 Connecting to device...")
        connectionPool.connect(to: testDeviceUUID)

        // Wait a bit for connection
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

        print("📊 Starting history data flow...")
        deviceConnection.startHistoryDataFlow()

        // Wait for completion (max 2 minutes)
        await fulfillment(of: [expectation], timeout: 120)

        // Verify results
        print("\n📊 Test Results Summary:")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Total entries received: \(receivedEntries.count)")
        print("Connection states: \(connectionStates)")
        print("Progress updates: \(progressUpdates.count)")
        print("Errors: \(errors.count)")

        if let lastProgress = progressUpdates.last {
            print("Final progress: \(lastProgress.0)/\(lastProgress.1)")
        }

        // Assertions
        XCTAssertGreaterThan(receivedEntries.count, 0, "Should receive at least one historical entry")
        XCTAssertTrue(connectionStates.contains("connected"), "Should reach connected state")
        XCTAssertTrue(connectionStates.contains("authenticated"), "Should reach authenticated state")
        XCTAssertGreaterThan(progressUpdates.count, 0, "Should receive progress updates")

        if let lastProgress = progressUpdates.last {
            XCTAssertEqual(lastProgress.0, lastProgress.1, "Should complete all entries")
            XCTAssertEqual(receivedEntries.count, lastProgress.1, "Received entries should match total")
        }

        print("✅ Full history loading test completed successfully!")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }

    // MARK: - Connection Test

    func testBasicConnection() async throws {
        print("🧪 Testing basic connection to device: \(testDeviceUUID)")

        let expectation = XCTestExpectation(description: "Device connected and authenticated")

        deviceConnection = connectionPool.getConnection(for: testDeviceUUID)

        deviceConnection.connectionStatePublisher
            .sink { state in
                let stateString = self.stateToString(state)
                print("📊 State: \(stateString)")

                if case .authenticated = state {
                    print("✅ Authentication successful!")
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        connectionPool.connect(to: testDeviceUUID)

        await fulfillment(of: [expectation], timeout: 30)

        XCTAssertEqual(deviceConnection.connectionState, .authenticated, "Should be authenticated")
        print("✅ Basic connection test passed!\n")
    }

    // MARK: - Progress Tracking Test

    func testProgressTracking() async throws {
        print("🧪 Testing progress tracking for device: \(testDeviceUUID)")

        let expectation = XCTestExpectation(description: "Progress updates received")
        var progressUpdates: [(Int, Int)] = []

        deviceConnection = connectionPool.getConnection(for: testDeviceUUID)

        deviceConnection.historyProgressPublisher
            .sink { progress in
                let (current, total) = progress
                progressUpdates.append((current, total))
                print("📈 Progress update: \(current)/\(total)")

                if total > 0 && current >= total {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        connectionPool.connect(to: testDeviceUUID)

        try await Task.sleep(nanoseconds: 3_000_000_000)

        deviceConnection.startHistoryDataFlow()

        await fulfillment(of: [expectation], timeout: 120)

        XCTAssertGreaterThan(progressUpdates.count, 0, "Should receive progress updates")

        if let first = progressUpdates.first, let last = progressUpdates.last {
            print("Progress range: \(first) → \(last)")
            XCTAssertLessThanOrEqual(first.0, last.0, "Progress should increase")
        }

        print("✅ Progress tracking test passed!\n")
    }

    // MARK: - Data Validation Test

    func testDataValidation() async throws {
        print("🧪 Testing data validation for device: \(testDeviceUUID)")

        let expectation = XCTestExpectation(description: "Valid data received")
        expectation.expectedFulfillmentCount = 10 // Wait for 10 entries

        var validEntries = 0
        var invalidEntries = 0

        deviceConnection = connectionPool.getConnection(for: testDeviceUUID)

        deviceConnection.historicalDataPublisher
            .sink { data in
                // Validate data ranges
                let isValid = self.validateSensorData(data)

                if isValid {
                    validEntries += 1
                    print("✅ Valid entry: temp=\(data.temperature)°C, moisture=\(data.moisture)%")
                } else {
                    invalidEntries += 1
                    print("⚠️ Invalid entry: temp=\(data.temperature)°C, moisture=\(data.moisture)%")
                }

                if validEntries + invalidEntries >= 10 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        connectionPool.connect(to: testDeviceUUID)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        deviceConnection.startHistoryDataFlow()

        await fulfillment(of: [expectation], timeout: 60)

        print("Valid entries: \(validEntries)")
        print("Invalid entries: \(invalidEntries)")

        XCTAssertGreaterThan(validEntries, 0, "Should receive at least one valid entry")

        let validPercentage = Double(validEntries) / Double(validEntries + invalidEntries) * 100
        XCTAssertGreaterThanOrEqual(validPercentage, 80.0, "At least 80% of entries should be valid")

        print("✅ Data validation test passed! (\(String(format: "%.1f", validPercentage))% valid)\n")
    }

    // MARK: - Performance Test

    func testPerformance() async throws {
        print("🧪 Testing performance for device: \(testDeviceUUID)")

        let expectation = XCTestExpectation(description: "Performance test completed")

        let startTime = Date()
        var firstEntryTime: Date?
        var lastEntryTime: Date?
        var entryCount = 0

        deviceConnection = connectionPool.getConnection(for: testDeviceUUID)

        deviceConnection.historicalDataPublisher
            .sink { _ in
                if firstEntryTime == nil {
                    firstEntryTime = Date()
                }
                lastEntryTime = Date()
                entryCount += 1
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HistoricalDataLoadingCompleted"),
            object: testDeviceUUID,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        connectionPool.connect(to: testDeviceUUID)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        deviceConnection.startHistoryDataFlow()

        await fulfillment(of: [expectation], timeout: 120)

        let totalTime = Date().timeIntervalSince(startTime)
        let firstEntryDelay = firstEntryTime.map { $0.timeIntervalSince(startTime) } ?? 0
        let downloadTime = lastEntryTime.map { $0.timeIntervalSince(firstEntryTime!) } ?? 0
        let entriesPerSecond = Double(entryCount) / totalTime

        print("📊 Performance Metrics:")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Total time: \(String(format: "%.2f", totalTime))s")
        print("Time to first entry: \(String(format: "%.2f", firstEntryDelay))s")
        print("Download time: \(String(format: "%.2f", downloadTime))s")
        print("Entries received: \(entryCount)")
        print("Speed: \(String(format: "%.1f", entriesPerSecond)) entries/sec")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        XCTAssertLessThan(firstEntryDelay, 10.0, "Should receive first entry within 10 seconds")
        XCTAssertGreaterThan(entriesPerSecond, 1.0, "Should download at least 1 entry/sec")

        print("✅ Performance test passed!\n")
    }

    // MARK: - Helper Methods

    private func stateToString(_ state: DeviceConnection.ConnectionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .authenticated: return "authenticated"
        case .error(let error): return "error(\(error.localizedDescription))"
        }
    }

    private func validateSensorData(_ data: HistoricalSensorData) -> Bool {
        // Validate temperature (FlowerCare range: -15°C to 50°C)
        guard data.temperature >= -15.0 && data.temperature <= 50.0 else {
            return false
        }

        // Validate moisture (0-100%)
        guard data.moisture >= 0 && data.moisture <= 100 else {
            return false
        }

        // Validate conductivity (0-10000 µS/cm)
        guard data.conductivity >= 0 && data.conductivity <= 10000 else {
            return false
        }

        // Validate brightness (0-200000 lux)
        guard data.brightness >= 0 && data.brightness <= 200000 else {
            return false
        }

        // Validate date (not in future)
        guard data.date <= Date() else {
            return false
        }

        return true
    }
}

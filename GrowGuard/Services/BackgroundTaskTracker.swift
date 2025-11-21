//
//  BackgroundTaskTracker.swift
//  GrowGuard
//
//  Tracks background task executions for debugging
//

import Foundation

/// Tracks background task execution history for debugging purposes
class BackgroundTaskTracker {

    static let shared = BackgroundTaskTracker()

    private let defaults = UserDefaults.standard

    // UserDefaults keys
    private let refreshTaskCountKey = "background_refresh_task_count"
    private let processingTaskCountKey = "background_processing_task_count"
    private let lastRefreshDateKey = "background_last_refresh_date"
    private let lastProcessingDateKey = "background_last_processing_date"
    private let executionHistoryKey = "background_execution_history"

    private init() {}

    // MARK: - Public API

    /// Records a background refresh task execution
    func recordRefreshTaskExecution(result: BackgroundFetchResult) {
        let count = refreshTaskCount + 1
        defaults.set(count, forKey: refreshTaskCountKey)
        defaults.set(Date(), forKey: lastRefreshDateKey)

        addToHistory(TaskExecution(
            type: .refresh,
            date: Date(),
            successfulDevices: result.successfulDevices.count,
            failedDevices: result.failedDevices.count,
            dataPoints: result.totalDataPoints,
            duration: result.duration
        ))

        print("📊 BackgroundTaskTracker: Refresh task #\(count) completed - \(result.successfulDevices.count) devices, \(result.totalDataPoints) data points")
    }

    /// Records a background processing task execution
    func recordProcessingTaskExecution(result: BackgroundFetchResult) {
        let count = processingTaskCount + 1
        defaults.set(count, forKey: processingTaskCountKey)
        defaults.set(Date(), forKey: lastProcessingDateKey)

        addToHistory(TaskExecution(
            type: .processing,
            date: Date(),
            successfulDevices: result.successfulDevices.count,
            failedDevices: result.failedDevices.count,
            dataPoints: result.totalDataPoints,
            duration: result.duration
        ))

        print("📊 BackgroundTaskTracker: Processing task #\(count) completed - \(result.successfulDevices.count) devices, \(result.totalDataPoints) data points")
    }

    /// Total refresh task executions
    var refreshTaskCount: Int {
        defaults.integer(forKey: refreshTaskCountKey)
    }

    /// Total processing task executions
    var processingTaskCount: Int {
        defaults.integer(forKey: processingTaskCountKey)
    }

    /// Last refresh task execution date
    var lastRefreshDate: Date? {
        defaults.object(forKey: lastRefreshDateKey) as? Date
    }

    /// Last processing task execution date
    var lastProcessingDate: Date? {
        defaults.object(forKey: lastProcessingDateKey) as? Date
    }

    /// Get execution history (last 50 entries)
    var executionHistory: [TaskExecution] {
        guard let data = defaults.data(forKey: executionHistoryKey),
              let history = try? JSONDecoder().decode([TaskExecution].self, from: data) else {
            return []
        }
        return history
    }

    /// Reset all tracking data
    func resetAll() {
        defaults.removeObject(forKey: refreshTaskCountKey)
        defaults.removeObject(forKey: processingTaskCountKey)
        defaults.removeObject(forKey: lastRefreshDateKey)
        defaults.removeObject(forKey: lastProcessingDateKey)
        defaults.removeObject(forKey: executionHistoryKey)
        print("📊 BackgroundTaskTracker: All tracking data reset")
    }

    /// Get a summary string for debugging
    func getSummary() -> String {
        let refreshDate = lastRefreshDate.map { formatDate($0) } ?? "Never"
        let processingDate = lastProcessingDate.map { formatDate($0) } ?? "Never"

        return """
        === Background Task Stats ===
        Refresh Tasks: \(refreshTaskCount) (Last: \(refreshDate))
        Processing Tasks: \(processingTaskCount) (Last: \(processingDate))
        Total Executions: \(refreshTaskCount + processingTaskCount)
        ==============================
        """
    }

    /// Print summary to console
    func printSummary() {
        print(getSummary())
    }

    // MARK: - Private Methods

    private func addToHistory(_ execution: TaskExecution) {
        var history = executionHistory
        history.insert(execution, at: 0)

        // Keep only last 50 entries
        if history.count > 50 {
            history = Array(history.prefix(50))
        }

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: executionHistoryKey)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Task Execution Model

struct TaskExecution: Codable, Identifiable {
    let id: UUID
    let type: TaskType
    let date: Date
    let successfulDevices: Int
    let failedDevices: Int
    let dataPoints: Int
    let duration: TimeInterval

    init(type: TaskType, date: Date, successfulDevices: Int, failedDevices: Int, dataPoints: Int, duration: TimeInterval) {
        self.id = UUID()
        self.type = type
        self.date = date
        self.successfulDevices = successfulDevices
        self.failedDevices = failedDevices
        self.dataPoints = dataPoints
        self.duration = duration
    }

    enum TaskType: String, Codable {
        case refresh = "Refresh"
        case processing = "Processing"
    }
}

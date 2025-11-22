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

    // Scheduling tracking keys
    private let schedulingHistoryKey = "background_scheduling_history"
    private let lastRefreshScheduledKey = "background_last_refresh_scheduled"
    private let lastProcessingScheduledKey = "background_last_processing_scheduled"
    private let refreshScheduleCountKey = "background_refresh_schedule_count"
    private let processingScheduleCountKey = "background_processing_schedule_count"
    private let scheduleFailureCountKey = "background_schedule_failure_count"

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

    // MARK: - Scheduling Tracking

    /// Records a successful task scheduling attempt
    func recordSchedulingAttempt(type: TaskExecution.TaskType, success: Bool, error: String? = nil, source: SchedulingSource) {
        let event = SchedulingEvent(
            type: type,
            date: Date(),
            success: success,
            error: error,
            source: source
        )

        addToSchedulingHistory(event)

        if success {
            if type == .refresh {
                let count = refreshScheduleCount + 1
                defaults.set(count, forKey: refreshScheduleCountKey)
                defaults.set(Date(), forKey: lastRefreshScheduledKey)
                print("📅 BackgroundTaskTracker: Refresh task scheduled (#\(count)) from \(source.rawValue)")
            } else {
                let count = processingScheduleCount + 1
                defaults.set(count, forKey: processingScheduleCountKey)
                defaults.set(Date(), forKey: lastProcessingScheduledKey)
                print("📅 BackgroundTaskTracker: Processing task scheduled (#\(count)) from \(source.rawValue)")
            }
        } else {
            let count = scheduleFailureCount + 1
            defaults.set(count, forKey: scheduleFailureCountKey)
            print("❌ BackgroundTaskTracker: Failed to schedule \(type.rawValue) task: \(error ?? "unknown")")
        }
    }

    /// Total refresh task scheduling attempts
    var refreshScheduleCount: Int {
        defaults.integer(forKey: refreshScheduleCountKey)
    }

    /// Total processing task scheduling attempts
    var processingScheduleCount: Int {
        defaults.integer(forKey: processingScheduleCountKey)
    }

    /// Total scheduling failures
    var scheduleFailureCount: Int {
        defaults.integer(forKey: scheduleFailureCountKey)
    }

    /// Last refresh task scheduled date
    var lastRefreshScheduledDate: Date? {
        defaults.object(forKey: lastRefreshScheduledKey) as? Date
    }

    /// Last processing task scheduled date
    var lastProcessingScheduledDate: Date? {
        defaults.object(forKey: lastProcessingScheduledKey) as? Date
    }

    /// Get scheduling history (last 50 entries)
    var schedulingHistory: [SchedulingEvent] {
        guard let data = defaults.data(forKey: schedulingHistoryKey),
              let history = try? JSONDecoder().decode([SchedulingEvent].self, from: data) else {
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
        defaults.removeObject(forKey: schedulingHistoryKey)
        defaults.removeObject(forKey: lastRefreshScheduledKey)
        defaults.removeObject(forKey: lastProcessingScheduledKey)
        defaults.removeObject(forKey: refreshScheduleCountKey)
        defaults.removeObject(forKey: processingScheduleCountKey)
        defaults.removeObject(forKey: scheduleFailureCountKey)
        print("📊 BackgroundTaskTracker: All tracking data reset")
    }

    /// Get a summary string for debugging
    func getSummary() -> String {
        let refreshDate = lastRefreshDate.map { formatDate($0) } ?? "Never"
        let processingDate = lastProcessingDate.map { formatDate($0) } ?? "Never"
        let refreshScheduled = lastRefreshScheduledDate.map { formatDate($0) } ?? "Never"
        let processingScheduled = lastProcessingScheduledDate.map { formatDate($0) } ?? "Never"

        return """
        === Background Task Stats ===
        SCHEDULING:
        Refresh Scheduled: \(refreshScheduleCount)x (Last: \(refreshScheduled))
        Processing Scheduled: \(processingScheduleCount)x (Last: \(processingScheduled))
        Schedule Failures: \(scheduleFailureCount)

        EXECUTION:
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

    private func addToSchedulingHistory(_ event: SchedulingEvent) {
        var history = schedulingHistory
        history.insert(event, at: 0)

        // Keep only last 50 entries
        if history.count > 50 {
            history = Array(history.prefix(50))
        }

        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: schedulingHistoryKey)
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

// MARK: - Scheduling Event Model

struct SchedulingEvent: Codable, Identifiable {
    let id: UUID
    let type: TaskExecution.TaskType
    let date: Date
    let success: Bool
    let error: String?
    let source: SchedulingSource

    init(type: TaskExecution.TaskType, date: Date, success: Bool, error: String?, source: SchedulingSource) {
        self.id = UUID()
        self.type = type
        self.date = date
        self.success = success
        self.error = error
        self.source = source
    }
}

/// Source of the scheduling attempt
enum SchedulingSource: String, Codable {
    case appLaunch = "App Launch"
    case enterBackground = "Enter Background"
    case afterExecution = "After Execution"
    case manual = "Manual"
}

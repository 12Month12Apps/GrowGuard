//
//  BackgroundTaskTracker.swift
//  Vattna
//
//  Tracks background task executions for debugging
//

import Foundation

/// What started a piece of background work. Stored with every execution
/// history entry so a push-driven read is distinguishable from a BGTask run.
enum BackgroundTrigger: String, Codable, CaseIterable {
    case refreshTask = "BG Refresh Task"
    case processingTask = "BG Processing Task"
    case silentPush = "Silent Push"
    case enterBackground = "Enter Background"

    /// Source stored with sensor samples this trigger produced
    var sensorDataSource: SensorDataSource {
        self == .silentPush ? .backgroundPush : .backgroundTask
    }
}

/// How a BLE wake read ended
enum WakeReadOutcome: String, Codable {
    case saved = "Saved"
    case sampleRejected = "Sample rejected"
    case disconnected = "Disconnected before data"
    case connectionError = "Connection error"
    case timedOut = "Timed out"

    var isSuccess: Bool { self == .saved }
}

/// Tracks background task execution history for debugging purposes
class BackgroundTaskTracker {

    static let shared = BackgroundTaskTracker()

    private let defaults: UserDefaults

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

    // Silent push tracking keys (phase 2: hourly server push)
    private let pushReceivedCountKey = "background_push_received_count"
    private let lastPushReceivedKey = "background_last_push_received"

    // BLE wake read tracking keys
    private let wakeReadSuccessCountKey = "background_wake_read_success_count"
    private let wakeReadFailureCountKey = "background_wake_read_failure_count"
    private let lastWakeReadKey = "background_last_wake_read"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public API

    /// Records a BGAppRefreshTask run (it only arms pending connects).
    /// `expired` mirrors the failure reported to setTaskCompleted.
    func recordRefreshTaskRun(armedSensors: Int, expired: Bool) {
        let count = refreshTaskCount + 1
        defaults.set(count, forKey: refreshTaskCountKey)
        defaults.set(Date(), forKey: lastRefreshDateKey)

        addToHistory(TaskExecution(
            type: .refresh,
            trigger: .refreshTask,
            success: !expired,
            detail: expired ? "Expired while arming \(armedSensors) sensor(s)" : "Armed \(armedSensors) sensor(s)"
        ))

        print("📊 BackgroundTaskTracker: Refresh task #\(count) ran - armed \(armedSensors) sensor(s) (expired: \(expired))")
    }

    /// Records a BGProcessingTask run (history sync)
    func recordProcessingTaskRun(duration: TimeInterval, expired: Bool) {
        let count = processingTaskCount + 1
        defaults.set(count, forKey: processingTaskCountKey)
        defaults.set(Date(), forKey: lastProcessingDateKey)

        addToHistory(TaskExecution(
            type: .processing,
            trigger: .processingTask,
            success: !expired,
            detail: expired ? "Expired before finishing" : "History sync finished",
            duration: duration
        ))

        print("📊 BackgroundTaskTracker: Processing task #\(count) ran for \(String(format: "%.1f", duration))s (expired: \(expired))")
    }

    /// Records how a BLE wake read ended. `trigger` is nil when iOS
    /// relaunched the app for the connect and the arm source was lost.
    func recordWakeRead(trigger: BackgroundTrigger?,
                        outcome: WakeReadOutcome,
                        duration: TimeInterval,
                        historyEntries: Int = 0) {
        let countKey = outcome.isSuccess ? wakeReadSuccessCountKey : wakeReadFailureCountKey
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        defaults.set(Date(), forKey: lastWakeReadKey)

        addToHistory(TaskExecution(
            type: .bleWake,
            trigger: trigger,
            success: outcome.isSuccess,
            detail: historyEntries > 0
                ? "\(outcome.rawValue) · \(historyEntries) history entries"
                : outcome.rawValue,
            isSensorRead: true,
            duration: duration
        ))

        print("📊 BackgroundTaskTracker: BLE wake read (\(trigger?.rawValue ?? "relaunch")) - \(outcome.rawValue)")
    }

    /// Successful BLE wake reads
    var wakeReadSuccessCount: Int {
        defaults.integer(forKey: wakeReadSuccessCountKey)
    }

    /// Failed BLE wake reads (timeout, disconnect, rejected sample)
    var wakeReadFailureCount: Int {
        defaults.integer(forKey: wakeReadFailureCountKey)
    }

    /// Last BLE wake read, successful or not
    var lastWakeReadDate: Date? {
        defaults.object(forKey: lastWakeReadKey) as? Date
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

    // MARK: - Silent Push Tracking (phase 2)

    /// Records a received silent push — verifies the server cadence
    /// actually reaches the device
    func recordPushReceived(armedSensors: Int) {
        let count = pushReceivedCount + 1
        defaults.set(count, forKey: pushReceivedCountKey)
        defaults.set(Date(), forKey: lastPushReceivedKey)

        addToHistory(TaskExecution(
            type: .silentPush,
            trigger: .silentPush,
            success: true,
            detail: "Armed \(armedSensors) sensor(s)"
        ))

        print("📬 BackgroundTaskTracker: Silent push #\(count) received - armed \(armedSensors) sensor(s)")
    }

    /// Total silent pushes received
    var pushReceivedCount: Int {
        defaults.integer(forKey: pushReceivedCountKey)
    }

    /// Last silent push receipt date
    var lastPushReceivedDate: Date? {
        defaults.object(forKey: lastPushReceivedKey) as? Date
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
        defaults.removeObject(forKey: pushReceivedCountKey)
        defaults.removeObject(forKey: lastPushReceivedKey)
        defaults.removeObject(forKey: wakeReadSuccessCountKey)
        defaults.removeObject(forKey: wakeReadFailureCountKey)
        defaults.removeObject(forKey: lastWakeReadKey)
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
        BLE Wake Reads: \(wakeReadSuccessCount) ok, \(wakeReadFailureCount) failed (Last: \(lastWakeReadDate.map { formatDate($0) } ?? "Never"))

        SILENT PUSH:
        Pushes Received: \(pushReceivedCount) (Last: \(lastPushReceivedDate.map { formatDate($0) } ?? "Never"))
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
    // Optional: entries written by older builds have none of these
    let trigger: BackgroundTrigger?
    let success: Bool?
    let detail: String?

    /// - Parameter isSensorRead: one sensor read one sample (BLE wake);
    ///   fills the device and data point counts from `success`
    init(type: TaskType,
         trigger: BackgroundTrigger?,
         success: Bool,
         detail: String,
         isSensorRead: Bool = false,
         duration: TimeInterval = 0) {
        self.id = UUID()
        self.type = type
        self.trigger = trigger
        self.success = success
        self.detail = detail
        self.date = Date()
        self.successfulDevices = isSensorRead && success ? 1 : 0
        self.failedDevices = isSensorRead && !success ? 1 : 0
        self.dataPoints = isSensorRead && success ? 1 : 0
        self.duration = duration
    }

    /// What started this entry, including the cases without a stored trigger
    var triggerLabel: String {
        if let trigger { return trigger.rawValue }
        return success == nil ? "Unknown (legacy entry)" : "Relaunch (trigger unknown)"
    }

    enum TaskType: String, Codable {
        case refresh = "Refresh"
        case processing = "Processing"
        case silentPush = "Silent Push"
        case bleWake = "BLE Wake"
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

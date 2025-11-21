import ActivityKit
import Combine
import Foundation
import UIKit

/// Service to manage Live Activity for history loading progress
/// Handles starting, updating, and ending the Live Activity displayed in
/// Dynamic Island and Lock Screen
@MainActor
final class HistoryLoadingActivityService: ObservableObject {

    // MARK: - Singleton

    static let shared = HistoryLoadingActivityService()

    // MARK: - Published Properties

    @Published private(set) var isActivityRunning = false
    @Published private(set) var currentDeviceUUID: String?

    // MARK: - Private Properties

    private var currentActivity: Activity<HistoryLoadingAttributes>?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()

    // For ETA calculation
    private var loadingStartTime: Date?
    private var progressHistory: [(timestamp: Date, entry: Int)] = []
    private let maxProgressHistoryCount = 10

    // MARK: - Initialization

    private init() {
        // Check if there's an existing activity on app launch
        checkForExistingActivity()
    }

    // MARK: - Public Methods

    /// Start a new Live Activity for history loading
    /// - Parameters:
    ///   - deviceName: Name of the device being loaded
    ///   - deviceUUID: UUID of the device
    ///   - totalEntries: Total number of entries to load (can be 0 initially)
    /// - Returns: True if the activity was started successfully
    @discardableResult
    func startActivity(
        deviceName: String,
        deviceUUID: String,
        totalEntries: Int = 0
    ) -> Bool {
        // End any existing activity first
        if currentActivity != nil {
            endActivity(status: .failed)
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[HistoryLoadingActivity] Live Activities are not enabled")
            return false
        }

        let attributes = HistoryLoadingAttributes(
            deviceName: deviceName,
            deviceUUID: deviceUUID
        )

        let initialState = HistoryLoadingAttributes.ContentState(
            currentEntry: 0,
            totalEntries: totalEntries,
            connectionStatus: .connecting,
            estimatedSecondsRemaining: nil,
            isPaused: false
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )

            self.currentActivity = activity
            self.currentDeviceUUID = deviceUUID
            self.isActivityRunning = true
            self.loadingStartTime = Date()
            self.progressHistory = []

            // Start background task to keep app alive
            startBackgroundTask()

            print("[HistoryLoadingActivity] Started activity for device: \(deviceName)")
            return true
        } catch {
            print("[HistoryLoadingActivity] Failed to start activity: \(error)")
            return false
        }
    }

    /// Update the Live Activity with current progress
    /// - Parameters:
    ///   - currentEntry: Current entry index (0-based)
    ///   - totalEntries: Total number of entries
    ///   - connectionStatus: Current connection status
    ///   - isPaused: Whether loading is paused
    ///   - errorMessage: Optional error message
    func updateProgress(
        currentEntry: Int,
        totalEntries: Int,
        connectionStatus: HistoryLoadingAttributes.ConnectionStatus = .loading,
        isPaused: Bool = false,
        errorMessage: String? = nil
    ) {
        guard let activity = currentActivity else {
            print("[HistoryLoadingActivity] No active activity to update")
            return
        }

        // Record progress for ETA calculation
        recordProgress(entry: currentEntry)

        // Calculate ETA
        let estimatedSeconds = calculateEstimatedTimeRemaining(
            currentEntry: currentEntry,
            totalEntries: totalEntries
        )

        let updatedState = HistoryLoadingAttributes.ContentState(
            currentEntry: currentEntry,
            totalEntries: totalEntries,
            connectionStatus: connectionStatus,
            estimatedSecondsRemaining: estimatedSeconds,
            isPaused: isPaused,
            errorMessage: errorMessage
        )

        Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: nil)
            )
        }
    }

    /// Update connection status without changing progress
    func updateConnectionStatus(_ status: HistoryLoadingAttributes.ConnectionStatus, isPaused: Bool = false) {
        guard let activity = currentActivity else { return }

        // Get current state and update only the status
        let currentState = activity.content.state
        let updatedState = HistoryLoadingAttributes.ContentState(
            currentEntry: currentState.currentEntry,
            totalEntries: currentState.totalEntries,
            connectionStatus: status,
            estimatedSecondsRemaining: currentState.estimatedSecondsRemaining,
            isPaused: isPaused,
            errorMessage: currentState.errorMessage
        )

        Task {
            await activity.update(
                ActivityContent(state: updatedState, staleDate: nil)
            )
        }
    }

    /// End the Live Activity
    /// - Parameter status: Final status to display
    func endActivity(status: HistoryLoadingAttributes.ConnectionStatus = .completed) {
        guard let activity = currentActivity else {
            print("[HistoryLoadingActivity] No active activity to end")
            return
        }

        let currentState = activity.content.state
        let finalState = HistoryLoadingAttributes.ContentState(
            currentEntry: status == .completed ? currentState.totalEntries : currentState.currentEntry,
            totalEntries: currentState.totalEntries,
            connectionStatus: status,
            estimatedSecondsRemaining: nil,
            isPaused: false,
            errorMessage: status == .failed ? "Loading failed" : nil
        )

        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .default
            )
        }

        // Cleanup
        currentActivity = nil
        currentDeviceUUID = nil
        isActivityRunning = false
        loadingStartTime = nil
        progressHistory = []

        // End background task
        endBackgroundTask()

        print("[HistoryLoadingActivity] Ended activity with status: \(status)")
    }

    /// Check if an activity exists for a specific device
    func hasActivity(for deviceUUID: String) -> Bool {
        return currentDeviceUUID == deviceUUID && currentActivity != nil
    }

    // MARK: - Background Task Management

    /// Start a background task to keep the app alive while loading
    func startBackgroundTask() {
        guard backgroundTaskIdentifier == .invalid else { return }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "HistoryLoading"
        ) { [weak self] in
            // Called when background time is about to expire
            self?.handleBackgroundTimeExpiring()
        }

        print("[HistoryLoadingActivity] Started background task: \(backgroundTaskIdentifier)")
    }

    /// End the background task
    func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid

        print("[HistoryLoadingActivity] Ended background task")
    }

    // MARK: - Private Methods

    private func checkForExistingActivity() {
        // Check if there are any existing activities from a previous session
        let existingActivities = Activity<HistoryLoadingAttributes>.activities

        if let activity = existingActivities.first {
            // Resume tracking the existing activity
            self.currentActivity = activity
            self.currentDeviceUUID = activity.attributes.deviceUUID
            self.isActivityRunning = true

            print("[HistoryLoadingActivity] Resumed existing activity for: \(activity.attributes.deviceName)")
        }
    }

    private func handleBackgroundTimeExpiring() {
        print("[HistoryLoadingActivity] Background time expiring")

        // Update activity to show paused state
        updateConnectionStatus(.reconnecting, isPaused: true)

        // End background task (iOS will suspend the app)
        endBackgroundTask()
    }

    private func recordProgress(entry: Int) {
        let now = Date()
        progressHistory.append((timestamp: now, entry: entry))

        // Keep only recent history
        if progressHistory.count > maxProgressHistoryCount {
            progressHistory.removeFirst()
        }
    }

    private func calculateEstimatedTimeRemaining(currentEntry: Int, totalEntries: Int) -> Int? {
        guard progressHistory.count >= 2,
              let startTime = loadingStartTime,
              currentEntry > 0,
              totalEntries > currentEntry else {
            return nil
        }

        // Calculate average speed using recent progress
        let oldestRecord = progressHistory.first!
        let newestRecord = progressHistory.last!

        let entriesLoaded = newestRecord.entry - oldestRecord.entry
        let timeElapsed = newestRecord.timestamp.timeIntervalSince(oldestRecord.timestamp)

        guard entriesLoaded > 0, timeElapsed > 0 else {
            return nil
        }

        let entriesPerSecond = Double(entriesLoaded) / timeElapsed
        let remainingEntries = totalEntries - currentEntry
        let estimatedSeconds = Double(remainingEntries) / entriesPerSecond

        return Int(estimatedSeconds)
    }
}

// MARK: - Convenience Extensions

extension HistoryLoadingActivityService {
    /// Convenience method to update progress from a tuple (used by DeviceConnection)
    func updateProgress(from progressTuple: (current: Int, total: Int)) {
        updateProgress(
            currentEntry: progressTuple.current,
            totalEntries: progressTuple.total
        )
    }
}

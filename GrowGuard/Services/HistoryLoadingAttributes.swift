import ActivityKit
import Foundation

/// Attributes for the History Loading Live Activity
/// This defines the static and dynamic data for the Live Activity displayed
/// in Dynamic Island and Lock Screen
public struct HistoryLoadingAttributes: ActivityAttributes {

    /// Static content that doesn't change during the activity
    public struct ContentState: Codable, Hashable {
        /// Current entry being loaded (0-based index)
        public var currentEntry: Int
        /// Total number of entries to load
        public var totalEntries: Int
        /// Connection status description
        public var connectionStatus: ConnectionStatus
        /// Estimated time remaining in seconds (nil if unknown)
        public var estimatedSecondsRemaining: Int?
        /// Whether the loading is paused (e.g., reconnecting)
        public var isPaused: Bool
        /// Last error message if any
        public var errorMessage: String?

        /// Computed progress percentage (0.0 to 1.0)
        public var progress: Double {
            guard totalEntries > 0 else { return 0 }
            return Double(currentEntry) / Double(totalEntries)
        }

        /// Formatted progress string (e.g., "45%")
        public var progressPercentage: String {
            let percentage = Int(progress * 100)
            return "\(percentage)%"
        }

        /// Formatted entry count string (e.g., "123/500")
        public var entryCountString: String {
            "\(currentEntry)/\(totalEntries)"
        }

        /// Formatted estimated time remaining
        public var estimatedTimeString: String? {
            guard let seconds = estimatedSecondsRemaining, seconds > 0 else { return nil }

            if seconds < 60 {
                return "\(seconds)s"
            } else if seconds < 3600 {
                let minutes = seconds / 60
                return "\(minutes)m"
            } else {
                let hours = seconds / 3600
                let minutes = (seconds % 3600) / 60
                return "\(hours)h \(minutes)m"
            }
        }

        public init(
            currentEntry: Int = 0,
            totalEntries: Int = 0,
            connectionStatus: ConnectionStatus = .connecting,
            estimatedSecondsRemaining: Int? = nil,
            isPaused: Bool = false,
            errorMessage: String? = nil
        ) {
            self.currentEntry = currentEntry
            self.totalEntries = totalEntries
            self.connectionStatus = connectionStatus
            self.estimatedSecondsRemaining = estimatedSecondsRemaining
            self.isPaused = isPaused
            self.errorMessage = errorMessage
        }
    }

    /// Connection status for display
    public enum ConnectionStatus: String, Codable, Hashable {
        case connecting = "Connecting"
        case connected = "Connected"
        case loading = "Loading"
        case reconnecting = "Reconnecting"
        case completed = "Completed"
        case failed = "Failed"

        public var displayString: String {
            rawValue
        }

        public var systemImage: String {
            switch self {
            case .connecting:
                return "antenna.radiowaves.left.and.right"
            case .connected:
                return "checkmark.circle"
            case .loading:
                return "arrow.down.circle"
            case .reconnecting:
                return "arrow.triangle.2.circlepath"
            case .completed:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.triangle"
            }
        }
    }

    /// Name of the device being loaded
    public let deviceName: String
    /// UUID of the device
    public let deviceUUID: String

    public init(deviceName: String, deviceUUID: String) {
        self.deviceName = deviceName
        self.deviceUUID = deviceUUID
    }
}

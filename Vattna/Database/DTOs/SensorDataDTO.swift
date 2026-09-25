import Foundation

/// Describes how the sensor data was loaded/fetched
enum SensorDataSource: String, CaseIterable, Codable {
    /// User manually triggered live data fetch in the app
    case liveUserTriggered = "live_user"
    /// Background task (BGAppRefreshTask or BGProcessingTask) fetched the data
    case backgroundTask = "background_task"
    /// Silent push notification triggered the fetch
    case backgroundPush = "background_push"
    /// Historical data loaded from device memory
    case historyLoading = "history"
    /// Source unknown (legacy data or migration)
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .liveUserTriggered: return "Live (User)"
        case .backgroundTask: return "Background Task"
        case .backgroundPush: return "Background Push"
        case .historyLoading: return "History"
        case .unknown: return "Unknown"
        }
    }
}

struct SensorDataDTO: Identifiable, Hashable {
    let id: String
    let temperature: Double
    let brightness: Int32
    let moisture: Int16
    let conductivity: Int16
    let date: Date
    let deviceUUID: String
    let source: SensorDataSource

    init(
        id: String = UUID().uuidString,
        temperature: Double,
        brightness: Int32,
        moisture: Int16,
        conductivity: Int16,
        date: Date,
        deviceUUID: String,
        source: SensorDataSource = .unknown
    ) {
        self.id = id
        self.temperature = temperature
        self.brightness = brightness
        self.moisture = moisture
        self.conductivity = conductivity
        self.date = date
        self.deviceUUID = deviceUUID
        self.source = source
    }
}
import Foundation

struct FlowerDeviceDTO: Identifiable, Hashable {
    let id: String
    var name: String
    let uuid: String
    let peripheralID: UUID?
    var battery: Int16
    /// When `battery` was last read from the sensor. nil for devices stored
    /// before 2026-09 (see `batteryReadAt`) and for sensors never read.
    var batteryUpdatedAt: Date?
    var firmware: String
    let isSensor: Bool
    let added: Date
    /// Time of the last measurement. Never bumped by battery reads or settings.
    var lastUpdate: Date
    let lastHistoryIndex: Int
    /// Failed contact attempts since the last successful reading
    var failedContactAttempts: Int16
    /// When the last failed attempt was recorded (rate limiting + UI)
    var lastFailedContactAt: Date?
    /// User-named place. Sensors sharing a location are within Bluetooth
    /// range of each other. Stored trimmed; empty is nil.
    var location: String?
    var optimalRange: OptimalRangeDTO?
    var potSize: PotSizeDTO?
    var selectedFlower: VMSpecies?
    let sensorData: [SensorDataDTO]

    init(
        id: String = UUID().uuidString,
        name: String,
        uuid: String,
        peripheralID: UUID? = nil,
        battery: Int16 = 0,
        batteryUpdatedAt: Date? = nil,
        firmware: String = "",
        isSensor: Bool = true,
        added: Date = Date(),
        lastUpdate: Date = Date(),
        lastHistoryIndex: Int = 0,
        failedContactAttempts: Int16 = 0,
        lastFailedContactAt: Date? = nil,
        location: String? = nil,
        optimalRange: OptimalRangeDTO? = nil,
        potSize: PotSizeDTO? = nil,
        selectedFlower: VMSpecies? = nil,
        sensorData: [SensorDataDTO] = []
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.peripheralID = peripheralID
        self.battery = battery
        self.batteryUpdatedAt = batteryUpdatedAt
        self.firmware = firmware
        self.isSensor = isSensor
        self.added = added
        self.lastUpdate = lastUpdate
        self.lastHistoryIndex = lastHistoryIndex
        self.failedContactAttempts = failedContactAttempts
        self.lastFailedContactAt = lastFailedContactAt
        self.location = location
        self.optimalRange = optimalRange
        self.potSize = potSize
        self.selectedFlower = selectedFlower
        self.sensorData = sensorData
    }

    // MARK: - Sensor health helpers (spec 2026-09-14-sensor-health-design.md)

    /// When the battery value was read. Devices stored before the timestamp
    /// existed fall back to `lastUpdate` when they have a value: the old code
    /// wrote the battery only from an open detail screen with a live
    /// connection, and that same connection bumped `lastUpdate`.
    var batteryReadAt: Date? {
        if let batteryUpdatedAt { return batteryUpdatedAt }
        return battery > 0 ? lastUpdate : nil
    }

    /// The later of `lastUpdate` and the newest sample. Background saves do
    /// not always bump `lastUpdate`; the overview syncs it lazily.
    var lastReading: Date {
        let newestSample = sensorData.map(\.date).max() ?? .distantPast
        return max(lastUpdate, newestSample)
    }

    /// Trims whitespace; empty becomes nil. Applied on every read and write.
    static func normalizeLocation(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

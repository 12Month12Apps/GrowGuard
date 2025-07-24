import Foundation

struct OptimalRangeDTO: Identifiable, Hashable {
    let id: String
    var minTemperature: Double
    var maxTemperature: Double
    var minBrightness: Int32
    var maxBrightness: Int32
    var minMoisture: Int16
    var maxMoisture: Int16
    var minConductivity: Int16
    var maxConductivity: Int16
    let deviceUUID: String
    
    init(
        id: String = UUID().uuidString,
        minTemperature: Double = 0.0,
        maxTemperature: Double = 0.0,
        minBrightness: Int32 = 0,
        maxBrightness: Int32 = 0,
        minMoisture: Int16 = 0,
        maxMoisture: Int16 = 0,
        minConductivity: Int16 = 0,
        maxConductivity: Int16 = 0,
        deviceUUID: String
    ) {
        self.id = id
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
        self.minMoisture = minMoisture
        self.maxMoisture = maxMoisture
        self.minConductivity = minConductivity
        self.maxConductivity = maxConductivity
        self.deviceUUID = deviceUUID
    }
}

import Foundation

struct SensorDataDTO: Identifiable, Hashable {
    let id: String
    let temperature: Double
    let brightness: Int32
    let moisture: Int16
    let conductivity: Int16
    let date: Date
    let deviceUUID: String
    
    init(
        id: String = UUID().uuidString,
        temperature: Double,
        brightness: Int32,
        moisture: Int16,
        conductivity: Int16,
        date: Date,
        deviceUUID: String
    ) {
        self.id = id
        self.temperature = temperature
        self.brightness = brightness
        self.moisture = moisture
        self.conductivity = conductivity
        self.date = date
        self.deviceUUID = deviceUUID
    }
}
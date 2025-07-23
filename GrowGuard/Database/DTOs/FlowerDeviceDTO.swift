import Foundation

struct FlowerDeviceDTO: Identifiable, Hashable {
    let id: String
    let name: String
    let uuid: String
    let peripheralID: UUID?
    let battery: Int16
    let firmware: String
    let isSensor: Bool
    let added: Date
    let lastUpdate: Date
    let optimalRange: OptimalRangeDTO?
    let potSize: PotSizeDTO?
    let sensorData: [SensorDataDTO]
    
    init(
        id: String = UUID().uuidString,
        name: String,
        uuid: String,
        peripheralID: UUID? = nil,
        battery: Int16 = 0,
        firmware: String = "",
        isSensor: Bool = true,
        added: Date = Date(),
        lastUpdate: Date = Date(),
        optimalRange: OptimalRangeDTO? = nil,
        potSize: PotSizeDTO? = nil,
        sensorData: [SensorDataDTO] = []
    ) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.peripheralID = peripheralID
        self.battery = battery
        self.firmware = firmware
        self.isSensor = isSensor
        self.added = added
        self.lastUpdate = lastUpdate
        self.optimalRange = optimalRange
        self.potSize = potSize
        self.sensorData = sensorData
    }
}
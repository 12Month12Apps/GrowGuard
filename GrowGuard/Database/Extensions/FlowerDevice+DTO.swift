import Foundation
import CoreData

extension FlowerDevice {
    func toDTO() -> FlowerDeviceDTO {
        let sensorDataDTOs = (sensorData?.allObjects as? [SensorData])?.compactMap { $0.toDTO() } ?? []
        
        return FlowerDeviceDTO(
            id: objectID.uriRepresentation().absoluteString,
            name: name ?? "",
            uuid: uuid ?? "",
            peripheralID: peripheralID,
            battery: battery,
            firmware: firmware ?? "",
            isSensor: isSensor,
            added: added ?? Date(),
            lastUpdate: lastUpdate ?? Date(),
            optimalRange: optimalRange?.toDTO(),
            potSize: potSize?.toDTO(),
            sensorData: sensorDataDTOs
        )
    }
    
    func updateFromDTO(_ dto: FlowerDeviceDTO) {
        name = dto.name
        uuid = dto.uuid
        peripheralID = dto.peripheralID
        battery = dto.battery
        firmware = dto.firmware
        isSensor = dto.isSensor
        added = dto.added
        lastUpdate = dto.lastUpdate
    }
}
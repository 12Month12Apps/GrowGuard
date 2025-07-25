import Foundation
import CoreData

extension FlowerDevice {
    func toDTO() -> FlowerDeviceDTO? {
        // Ensure we have a valid UUID - this is critical for device identification
        guard let deviceUUID = uuid, !deviceUUID.isEmpty else {
            print("FlowerDevice.toDTO(): Missing or empty UUID - cannot create DTO")
            return nil
        }
        
        // CRITICAL FIX: Remove performAndWait to prevent deadlocks
        // These properties are already on the correct context when method is called
        
        // Skip expensive sensor data conversion for better performance
        // Only load basic device info, sensor data can be loaded separately when needed
        let sensorDataDTOs: [SensorDataDTO] = []
        
        // Safely get object ID string
        let objectIdString: String
        do {
            objectIdString = self.objectID.uriRepresentation().absoluteString
        } catch {
            print("FlowerDevice.toDTO(): Error getting object ID - using UUID as fallback")
            objectIdString = deviceUUID
        }
        
        // Access optimalRange and potSize relationships safely (quick operations)
        let optimalRangeDTO = self.optimalRange?.toDTO()
        let potSizeDTO = self.potSize?.toDTO()
        
        return FlowerDeviceDTO(
            id: objectIdString,
            name: self.name ?? "Unknown Device",
            uuid: deviceUUID,
            peripheralID: self.peripheralID,
            battery: self.battery,
            firmware: self.firmware ?? "Unknown",
            isSensor: self.isSensor,
            added: self.added ?? Date(),
            lastUpdate: self.lastUpdate ?? Date(),
            optimalRange: optimalRangeDTO,
            potSize: potSizeDTO,
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

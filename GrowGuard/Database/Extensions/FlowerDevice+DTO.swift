import Foundation
import CoreData

extension FlowerDevice {
    func toDTO() -> FlowerDeviceDTO? {
        // Ensure we're executing on the correct context queue
        guard let context = managedObjectContext else {
            print("FlowerDevice.toDTO(): No managed object context - cannot create DTO")
            return nil
        }
        
        // Ensure we have a valid UUID - this is critical for device identification
        guard let deviceUUID = uuid, !deviceUUID.isEmpty else {
            print("FlowerDevice.toDTO(): Missing or empty UUID - cannot create DTO")
            return nil
        }
        
        var result: FlowerDeviceDTO?
        
        // Perform all Core Data operations on the context's queue
        context.performAndWait {
            // Safely convert sensor data within the context queue
            var sensorDataDTOs: [SensorDataDTO] = []
            
            // Access sensorData relationship safely
            if let sensorDataSet = self.sensorData {
                // Convert NSSet to Array safely
                let sensorDataArray = sensorDataSet.allObjects.compactMap { $0 as? SensorData }
                sensorDataDTOs = sensorDataArray.compactMap { sensorData in
                    // Only include sensor data that can be successfully converted
                    return sensorData.toDTO()
                }
            }
            
            // Safely get object ID string
            let objectIdString: String
            do {
                objectIdString = self.objectID.uriRepresentation().absoluteString
            } catch {
                print("FlowerDevice.toDTO(): Error getting object ID - using UUID as fallback")
                objectIdString = deviceUUID
            }
            
            // Access optimalRange and potSize relationships safely
            let optimalRangeDTO = self.optimalRange?.toDTO()
            let potSizeDTO = self.potSize?.toDTO()
            
            result = FlowerDeviceDTO(
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
        
        return result
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

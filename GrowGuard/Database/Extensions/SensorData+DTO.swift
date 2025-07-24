import Foundation
import CoreData

extension SensorData {
    func toDTO() -> SensorDataDTO? {
        // Ensure we're executing on the correct context queue
        guard let context = managedObjectContext else {
            print("SensorData.toDTO(): No managed object context - cannot create DTO")
            return nil
        }
        
        var result: SensorDataDTO?
        
        // Perform all Core Data operations on the context's queue
        context.performAndWait {
            // Ensure we have a valid device relationship with UUID
            guard let device = self.device,
                  let deviceUUID = device.uuid,
                  !deviceUUID.isEmpty else {
                print("SensorData.toDTO(): Missing device relationship or device UUID - cannot create DTO")
                return
            }
            
            // Safely get object ID string
            let objectIdString: String
            do {
                objectIdString = self.objectID.uriRepresentation().absoluteString
            } catch {
                print("SensorData.toDTO(): Error getting object ID - using timestamp-based fallback")
                objectIdString = "sensor-\(deviceUUID)-\(Int(Date().timeIntervalSince1970))"
            }
            
            // Ensure we have a valid date
            let sensorDate = self.date ?? Date()
            
            result = SensorDataDTO(
                id: objectIdString,
                temperature: self.temperature,
                brightness: self.brightness,
                moisture: self.moisture,
                conductivity: self.conductivity,
                date: sensorDate,
                deviceUUID: deviceUUID
            )
        }
        
        return result
    }
    
    func updateFromDTO(_ dto: SensorDataDTO, device: FlowerDevice) {
        temperature = dto.temperature
        brightness = dto.brightness
        moisture = dto.moisture
        conductivity = dto.conductivity
        date = dto.date
        self.device = device
    }
}
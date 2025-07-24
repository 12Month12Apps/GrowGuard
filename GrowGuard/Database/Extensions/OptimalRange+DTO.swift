import Foundation
import CoreData

extension OptimalRange {
    func toDTO() -> OptimalRangeDTO? {
        // Ensure we're executing on the correct context queue
        guard let context = managedObjectContext else {
            print("OptimalRange.toDTO(): No managed object context - cannot create DTO")
            return nil
        }
        
        var result: OptimalRangeDTO?
        
        // Perform all Core Data operations on the context's queue
        context.performAndWait {
            // Ensure we have a valid device relationship with UUID
            guard let device = self.device,
                  let deviceUUID = device.uuid,
                  !deviceUUID.isEmpty else {
                print("OptimalRange.toDTO(): Missing device relationship or device UUID - cannot create DTO")
                return
            }
            
            // Safely get object ID string
            let objectIdString: String
            do {
                objectIdString = self.objectID.uriRepresentation().absoluteString
            } catch {
                print("OptimalRange.toDTO(): Error getting object ID - using device-based fallback")
                objectIdString = "range-\(deviceUUID)"
            }
            
            result = OptimalRangeDTO(
                id: objectIdString,
                minTemperature: self.minTemperature,
                maxTemperature: self.maxTemperature,
                minBrightness: self.minBrightness,
                maxBrightness: self.maxBrightness,
                minMoisture: self.minMoisture,
                maxMoisture: self.maxMoisture,
                minConductivity: self.minConductivity,
                maxConductivity: self.maxConductivity,
                deviceUUID: deviceUUID
            )
        }
        
        return result
    }
    
    func updateFromDTO(_ dto: OptimalRangeDTO) {
        minTemperature = dto.minTemperature
        maxTemperature = dto.maxTemperature
        minBrightness = dto.minBrightness
        maxBrightness = dto.maxBrightness
        minMoisture = dto.minMoisture
        maxMoisture = dto.maxMoisture
        minConductivity = dto.minConductivity
        maxConductivity = dto.maxConductivity
    }
}
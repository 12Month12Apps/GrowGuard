import Foundation
import CoreData

extension PotSize {
    func toDTO() -> PotSizeDTO? {
        // CRITICAL FIX: Remove performAndWait to prevent deadlocks
        // These properties are already on the correct context when method is called
        
        // Ensure we have a valid device relationship with UUID
        guard let device = self.device,
              let deviceUUID = device.uuid,
              !deviceUUID.isEmpty else {
            print("PotSize.toDTO(): Missing device relationship or device UUID - cannot create DTO")
            return nil
        }
        
        // Safely get object ID string
        let objectIdString: String
        do {
            objectIdString = self.objectID.uriRepresentation().absoluteString
        } catch {
            print("PotSize.toDTO(): Error getting object ID - using device-based fallback")
            objectIdString = "pot-\(deviceUUID)"
        }
        
        return PotSizeDTO(
            id: objectIdString,
            width: self.width,
            height: self.height,
            volume: self.volume,
            deviceUUID: deviceUUID
        )
    }
    
    func updateFromDTO(_ dto: PotSizeDTO) {
        width = dto.width
        height = dto.height
        volume = dto.volume
    }
}
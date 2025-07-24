import Foundation
import CoreData

extension PotSize {
    func toDTO() -> PotSizeDTO? {
        // Ensure we're executing on the correct context queue
        guard let context = managedObjectContext else {
            print("PotSize.toDTO(): No managed object context - cannot create DTO")
            return nil
        }
        
        var result: PotSizeDTO?
        
        // Perform all Core Data operations on the context's queue
        context.performAndWait {
            // Ensure we have a valid device relationship with UUID
            guard let device = self.device,
                  let deviceUUID = device.uuid,
                  !deviceUUID.isEmpty else {
                print("PotSize.toDTO(): Missing device relationship or device UUID - cannot create DTO")
                return
            }
            
            // Safely get object ID string
            let objectIdString: String
            do {
                objectIdString = self.objectID.uriRepresentation().absoluteString
            } catch {
                print("PotSize.toDTO(): Error getting object ID - using device-based fallback")
                objectIdString = "pot-\(deviceUUID)"
            }
            
            result = PotSizeDTO(
                id: objectIdString,
                width: self.width,
                height: self.height,
                volume: self.volume,
                deviceUUID: deviceUUID
            )
        }
        
        return result
    }
    
    func updateFromDTO(_ dto: PotSizeDTO) {
        width = dto.width
        height = dto.height
        volume = dto.volume
    }
}
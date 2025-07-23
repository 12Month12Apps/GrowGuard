import Foundation
import CoreData

extension PotSize {
    func toDTO() -> PotSizeDTO? {
        guard let deviceUUID = device?.uuid else { return nil }
        
        return PotSizeDTO(
            id: objectID.uriRepresentation().absoluteString,
            width: width,
            height: height,
            volume: volume,
            deviceUUID: deviceUUID
        )
    }
    
    func updateFromDTO(_ dto: PotSizeDTO) {
        width = dto.width
        height = dto.height
        volume = dto.volume
    }
}
import Foundation
import CoreData

extension OptimalRange {
    func toDTO() -> OptimalRangeDTO? {
        guard let deviceUUID = device?.uuid else { return nil }
        
        return OptimalRangeDTO(
            id: objectID.uriRepresentation().absoluteString,
            minTemperature: minTemperature,
            maxTemperature: maxTemperature,
            minBrightness: minBrightness,
            maxBrightness: maxBrightness,
            minMoisture: minMoisture,
            maxMoisture: maxMoisture,
            minConductivity: minConductivity,
            maxConductivity: maxConductivity,
            deviceUUID: deviceUUID
        )
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
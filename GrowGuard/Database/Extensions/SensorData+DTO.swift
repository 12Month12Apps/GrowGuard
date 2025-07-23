import Foundation
import CoreData

extension SensorData {
    func toDTO() -> SensorDataDTO? {
        guard let deviceUUID = device?.uuid else { return nil }
        
        return SensorDataDTO(
            id: objectID.uriRepresentation().absoluteString,
            temperature: temperature,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: date ?? Date(),
            deviceUUID: deviceUUID
        )
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
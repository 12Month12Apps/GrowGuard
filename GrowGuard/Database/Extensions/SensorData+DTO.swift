import Foundation
import CoreData

extension SensorData {
    func toDTO() -> SensorDataDTO? {
        // CRITICAL FIX: Remove performAndWait to prevent deadlocks
        // These properties are already on the correct context when method is called
        
        // Ensure we have a valid device relationship with UUID
        guard let device = self.device,
              let deviceUUID = device.uuid,
              !deviceUUID.isEmpty else {
            print("SensorData.toDTO(): Missing device relationship or device UUID - cannot create DTO")
            return nil
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
        
        // Parse source from stored string, defaulting to unknown for legacy data
        let dataSource = SensorDataSource(rawValue: self.source ?? "unknown") ?? .unknown

        return SensorDataDTO(
            id: objectIdString,
            temperature: self.temperature,
            brightness: self.brightness,
            moisture: self.moisture,
            conductivity: self.conductivity,
            date: sensorDate,
            deviceUUID: deviceUUID,
            source: dataSource
        )
    }
    
    func updateFromDTO(_ dto: SensorDataDTO, device: FlowerDevice) {
        temperature = dto.temperature
        brightness = dto.brightness
        moisture = dto.moisture
        conductivity = dto.conductivity
        date = dto.date
        source = dto.source.rawValue
        self.device = device
    }
}
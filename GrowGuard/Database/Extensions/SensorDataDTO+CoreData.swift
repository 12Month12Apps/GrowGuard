import Foundation
import CoreData

extension SensorDataDTO {
    func toCoreDataSensorData() -> SensorData? {
        // Validate deviceUUID
        guard !deviceUUID.isEmpty else {
            print("SensorDataDTO.toCoreDataSensorData(): Empty deviceUUID - cannot create Core Data object")
            return nil
        }
        
        let context = DataService.shared.context
        var result: SensorData?
        
        context.performAndWait {
            // Try to find the associated device first
            let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
            request.predicate = NSPredicate(format: "uuid == %@", deviceUUID)
            request.fetchLimit = 1
            
            do {
                let devices = try context.fetch(request)
                guard let device = devices.first else {
                    print("SensorDataDTO.toCoreDataSensorData(): No device found with UUID \(deviceUUID)")
                    return
                }
                
                // Create sensor data only after confirming device exists
                let sensorData = SensorData(context: context)
                sensorData.temperature = temperature
                sensorData.brightness = brightness
                sensorData.moisture = moisture
                sensorData.conductivity = conductivity
                sensorData.date = date
                sensorData.device = device
                
                result = sensorData
            } catch {
                print("SensorDataDTO.toCoreDataSensorData(): Error finding device for sensor data: \(error)")
            }
        }
        
        return result
    }
}

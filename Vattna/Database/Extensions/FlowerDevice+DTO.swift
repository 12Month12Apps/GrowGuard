import Foundation
import CoreData

extension FlowerDevice {
    func toDTO() -> FlowerDeviceDTO? {
        // Ensure we have a valid UUID - this is critical for device identification
        guard let deviceUUID = uuid, !deviceUUID.isEmpty else {
            print("FlowerDevice.toDTO(): Missing or empty UUID - cannot create DTO")
            return nil
        }
        
        // CRITICAL FIX: Remove performAndWait to prevent deadlocks
        // These properties are already on the correct context when method is called
        
        // Load latest sensor data for overview display
        // Only fetch the most recent entry to keep it performant
        let sensorDataDTOs: [SensorDataDTO]
        if let sensorDataSet = self.sensorData as? Set<SensorData> {
            // Sort by date descending and take only the latest one
            let latestSensorData = sensorDataSet
                .sorted { ($0.date ?? Date.distantPast) > ($1.date ?? Date.distantPast) }
                .prefix(1)
                .compactMap { $0.toDTO() }
            sensorDataDTOs = Array(latestSensorData)
        } else {
            sensorDataDTOs = []
        }
        
        // Safely get object ID string
        let objectIdString: String
        do {
            objectIdString = self.objectID.uriRepresentation().absoluteString
        } catch {
            print("FlowerDevice.toDTO(): Error getting object ID - using UUID as fallback")
            objectIdString = deviceUUID
        }
        
        // Access optimalRange and potSize relationships safely (quick operations)
        let optimalRangeDTO = self.optimalRange?.toDTO()
        let potSizeDTO = self.potSize?.toDTO()
        
        // Create selected flower DTO if data exists - check if properties exist first
        let selectedFlowerDTO: VMSpecies?
        let entityDescription = self.entity
        let hasFlowerProperties = entityDescription.attributesByName.keys.contains("selectedFlowerID")
        
        if hasFlowerProperties {
            if let flowerName = self.selectedFlowerName,
               !flowerName.isEmpty,
               self.selectedFlowerID != 0 {
                selectedFlowerDTO = VMSpecies(
                    name: flowerName,
                    id: self.selectedFlowerID,
                    imageUrl: self.selectedFlowerImageUrl,
                    minMoisture: self.selectedFlowerMinMoisture > 0 ? Int(self.selectedFlowerMinMoisture) : nil,
                    maxMoisture: self.selectedFlowerMaxMoisture > 0 ? Int(self.selectedFlowerMaxMoisture) : nil
                )
                print("🔍 FlowerDevice.toDTO: Loading flower - ID: \(self.selectedFlowerID), Name: \(flowerName)")
            } else {
                selectedFlowerDTO = nil
                print("🔍 FlowerDevice.toDTO: No flower data found - ID: \(self.selectedFlowerID), Name: \(self.selectedFlowerName ?? "nil")")
            }
        } else {
            selectedFlowerDTO = nil
            print("ℹ️ FlowerDevice.toDTO: Flower properties not available in Core Data model")
            print("ℹ️ Available attributes: \(entityDescription.attributesByName.keys.sorted())")
        }
        
        return FlowerDeviceDTO(
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
            selectedFlower: selectedFlowerDTO,
            sensorData: sensorDataDTOs
        )
    }
    
    func updateFromDTO(_ dto: FlowerDeviceDTO) {
        print("💾 FlowerDevice.updateFromDTO: Updating device")
        print("  Current name: '\(self.name ?? "nil")'")
        print("  New name from DTO: '\(dto.name)'")
        name = dto.name
        print("  Name after update: '\(self.name ?? "nil")'")
        uuid = dto.uuid
        peripheralID = dto.peripheralID
        battery = dto.battery
        firmware = dto.firmware
        isSensor = dto.isSensor
        added = dto.added
        lastUpdate = dto.lastUpdate
        
        // Update selected flower fields - use key-value approach for safety
        if let selectedFlower = dto.selectedFlower {
            // Check if the properties exist in the entity
            let entityDescription = self.entity
            let hasFlowerProperties = entityDescription.attributesByName.keys.contains("selectedFlowerID")
            
            if hasFlowerProperties {
                selectedFlowerID = selectedFlower.id
                selectedFlowerName = selectedFlower.name
                selectedFlowerImageUrl = selectedFlower.imageUrl
                selectedFlowerMinMoisture = selectedFlower.minMoisture != nil ? Int32(selectedFlower.minMoisture!) : 0
                selectedFlowerMaxMoisture = selectedFlower.maxMoisture != nil ? Int32(selectedFlower.maxMoisture!) : 0
                print("💾 FlowerDevice.updateFromDTO: Saving flower - ID: \(selectedFlowerID), Name: \(selectedFlowerName ?? "nil")")
            } else {
                print("❌ FlowerDevice.updateFromDTO: Flower properties not found in Core Data model")
                print("❌ Available attributes: \(entityDescription.attributesByName.keys.sorted())")
            }
        } else {
            // Check if the properties exist before clearing
            let entityDescription = self.entity
            let hasFlowerProperties = entityDescription.attributesByName.keys.contains("selectedFlowerID")
            
            if hasFlowerProperties {
                selectedFlowerID = 0
                selectedFlowerName = nil
                selectedFlowerImageUrl = nil
                selectedFlowerMinMoisture = 0
                selectedFlowerMaxMoisture = 0
                print("💾 FlowerDevice.updateFromDTO: Clearing flower data")
            } else {
                print("ℹ️ FlowerDevice.updateFromDTO: Flower properties not found in model, nothing to clear")
            }
        }
    }
}

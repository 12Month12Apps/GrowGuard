import Foundation
import CoreData

class CoreDataSensorDataRepository: SensorDataRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.backgroundContext) {
        self.context = context
    }
    
    func getSensorData(for deviceUUID: String, limit: Int? = nil) async throws -> [SensorDataDTO] {
        let request = NSFetchRequest<SensorData>(entityName: "SensorData")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        
        if let limit = limit {
            request.fetchLimit = limit
        }
        
        let sensorData = try context.fetch(request)
        return sensorData.compactMap { $0.toDTO() }
    }
    
    func getRecentSensorData(for deviceUUID: String, limit: Int) async throws -> [SensorDataDTO] {
        let request = NSFetchRequest<SensorData>(entityName: "SensorData")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = limit
        
        let sensorData = try context.fetch(request)
        return sensorData.compactMap { $0.toDTO() }.reversed()
    }
    
    func saveSensorData(_ sensorData: SensorDataDTO) async throws {
        let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        deviceRequest.predicate = NSPredicate(format: "uuid == %@", sensorData.deviceUUID)
        deviceRequest.fetchLimit = 1
        
        guard let device = try context.fetch(deviceRequest).first else {
            throw RepositoryError.deviceNotFound
        }
        
        let coreDataSensorData = SensorData(context: context)
        coreDataSensorData.updateFromDTO(sensorData, device: device)
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func deleteSensorData(id: String) async throws {
        let request = NSFetchRequest<SensorData>(entityName: "SensorData")
        request.predicate = NSPredicate(format: "objectID == %@", id)
        
        let sensorData = try context.fetch(request)
        for data in sensorData {
            context.delete(data)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func deleteAllSensorData(for deviceUUID: String) async throws {
        let request = NSFetchRequest<SensorData>(entityName: "SensorData")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        
        let sensorData = try context.fetch(request)
        for data in sensorData {
            context.delete(data)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
}
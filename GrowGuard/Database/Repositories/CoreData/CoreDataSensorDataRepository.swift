import Foundation
import CoreData

class CoreDataSensorDataRepository: SensorDataRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.backgroundContext) {
        self.context = context
    }
    
    func getSensorData(for deviceUUID: String, limit: Int? = nil) async throws -> [SensorDataDTO] {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = NSFetchRequest<SensorData>(entityName: "SensorData")
                    request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                    
                    if let limit = limit {
                        request.fetchLimit = limit
                    }
                    
                    let sensorData = try self.context.fetch(request)
                    let dtos = sensorData.compactMap { $0.toDTO() }
                    continuation.resume(returning: dtos)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func getRecentSensorData(for deviceUUID: String, limit: Int) async throws -> [SensorDataDTO] {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = NSFetchRequest<SensorData>(entityName: "SensorData")
                    request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                    request.fetchLimit = limit
                    
                    let sensorData = try self.context.fetch(request)
                    let dtos = sensorData.compactMap { $0.toDTO() }.reversed()
                    continuation.resume(returning: Array(dtos))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func saveSensorData(_ sensorData: SensorDataDTO) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
                    deviceRequest.predicate = NSPredicate(format: "uuid == %@", sensorData.deviceUUID)
                    deviceRequest.fetchLimit = 1
                    
                    guard let device = try self.context.fetch(deviceRequest).first else {
                        continuation.resume(throwing: RepositoryError.deviceNotFound)
                        return
                    }
                    
                    let coreDataSensorData = SensorData(context: self.context)
                    coreDataSensorData.updateFromDTO(sensorData, device: device)
                    
                    if self.context.hasChanges {
                        try self.context.save()
                    }
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
    
    func getSensorDataInDateRange(for deviceUUID: String, startDate: Date, endDate: Date) async throws -> [SensorDataDTO] {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = NSFetchRequest<SensorData>(entityName: "SensorData")
                    request.predicate = NSPredicate(format: "device.uuid == %@ AND date >= %@ AND date <= %@", 
                                                  deviceUUID, startDate as NSDate, endDate as NSDate)
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                    
                    let sensorData = try self.context.fetch(request)
                    let dtos = sensorData.compactMap { $0.toDTO() }
                    continuation.resume(returning: dtos)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
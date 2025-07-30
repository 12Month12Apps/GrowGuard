import Foundation
import CoreData

class CoreDataOptimalRangeRepository: OptimalRangeRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.backgroundContext) {
        self.context = context
    }
    
    func getOptimalRange(for deviceUUID: String) async throws -> OptimalRangeDTO? {
        return try await context.perform {
            let request = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
            request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
            request.fetchLimit = 1
            
            let optimalRanges = try self.context.fetch(request)
            return optimalRanges.first?.toDTO()
        }
    }
    
    func saveOptimalRange(_ optimalRange: OptimalRangeDTO) async throws {
        try await context.perform {
            let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
            deviceRequest.predicate = NSPredicate(format: "uuid == %@", optimalRange.deviceUUID)
            deviceRequest.fetchLimit = 1
            
            guard let device = try self.context.fetch(deviceRequest).first else {
                throw RepositoryError.deviceNotFound
            }
            
            let existingRequest = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
            existingRequest.predicate = NSPredicate(format: "device.uuid == %@", optimalRange.deviceUUID)
            existingRequest.fetchLimit = 1
            
            let existingRanges = try self.context.fetch(existingRequest)
            let coreDataRange: OptimalRange
            
            if let existing = existingRanges.first {
                coreDataRange = existing
            } else {
                coreDataRange = OptimalRange(context: self.context)
                coreDataRange.device = device
            }
            
            coreDataRange.updateFromDTO(optimalRange)
            
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
    
    func deleteOptimalRange(for deviceUUID: String) async throws {
        try await context.perform {
            let request = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
            request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
            
            let optimalRanges = try self.context.fetch(request)
            for range in optimalRanges {
                self.context.delete(range)
            }
            
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
}
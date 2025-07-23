import Foundation
import CoreData

class CoreDataOptimalRangeRepository: OptimalRangeRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.context) {
        self.context = context
    }
    
    func getOptimalRange(for deviceUUID: String) async throws -> OptimalRangeDTO? {
        let request = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        request.fetchLimit = 1
        
        let optimalRanges = try context.fetch(request)
        return optimalRanges.first?.toDTO()
    }
    
    func saveOptimalRange(_ optimalRange: OptimalRangeDTO) async throws {
        let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        deviceRequest.predicate = NSPredicate(format: "uuid == %@", optimalRange.deviceUUID)
        deviceRequest.fetchLimit = 1
        
        guard let device = try context.fetch(deviceRequest).first else {
            throw RepositoryError.deviceNotFound
        }
        
        let existingRequest = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
        existingRequest.predicate = NSPredicate(format: "device.uuid == %@", optimalRange.deviceUUID)
        existingRequest.fetchLimit = 1
        
        let existingRanges = try context.fetch(existingRequest)
        let coreDataRange: OptimalRange
        
        if let existing = existingRanges.first {
            coreDataRange = existing
        } else {
            coreDataRange = OptimalRange(context: context)
            coreDataRange.device = device
        }
        
        coreDataRange.updateFromDTO(optimalRange)
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func deleteOptimalRange(for deviceUUID: String) async throws {
        let request = NSFetchRequest<OptimalRange>(entityName: "OptimalRange")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        
        let optimalRanges = try context.fetch(request)
        for range in optimalRanges {
            context.delete(range)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
}
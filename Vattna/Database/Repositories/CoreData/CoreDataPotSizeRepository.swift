import Foundation
import CoreData

class CoreDataPotSizeRepository: PotSizeRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.backgroundContext) {
        self.context = context
    }
    
    func getPotSize(for deviceUUID: String) async throws -> PotSizeDTO? {
        return try await context.perform {
            let request = NSFetchRequest<PotSize>(entityName: "PotSize")
            request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
            request.fetchLimit = 1
            
            let potSizes = try self.context.fetch(request)
            return potSizes.first?.toDTO()
        }
    }
    
    func savePotSize(_ potSize: PotSizeDTO) async throws {
        try await context.perform {
            let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
            deviceRequest.predicate = NSPredicate(format: "uuid == %@", potSize.deviceUUID)
            deviceRequest.fetchLimit = 1
            
            guard let device = try self.context.fetch(deviceRequest).first else {
                throw RepositoryError.deviceNotFound
            }
            
            let existingRequest = NSFetchRequest<PotSize>(entityName: "PotSize")
            existingRequest.predicate = NSPredicate(format: "device.uuid == %@", potSize.deviceUUID)
            existingRequest.fetchLimit = 1
            
            let existingPotSizes = try self.context.fetch(existingRequest)
            let coreDataPotSize: PotSize
            
            if let existing = existingPotSizes.first {
                coreDataPotSize = existing
            } else {
                coreDataPotSize = PotSize(context: self.context)
                coreDataPotSize.device = device
            }
            
            coreDataPotSize.updateFromDTO(potSize)
            
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
    
    func deletePotSize(for deviceUUID: String) async throws {
        try await context.perform {
            let request = NSFetchRequest<PotSize>(entityName: "PotSize")
            request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
            
            let potSizes = try self.context.fetch(request)
            for potSize in potSizes {
                self.context.delete(potSize)
            }
            
            if self.context.hasChanges {
                try self.context.save()
            }
        }
    }
}
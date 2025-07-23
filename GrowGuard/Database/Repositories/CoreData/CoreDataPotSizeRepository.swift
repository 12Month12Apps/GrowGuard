import Foundation
import CoreData

class CoreDataPotSizeRepository: PotSizeRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.context) {
        self.context = context
    }
    
    func getPotSize(for deviceUUID: String) async throws -> PotSizeDTO? {
        let request = NSFetchRequest<PotSize>(entityName: "PotSize")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        request.fetchLimit = 1
        
        let potSizes = try context.fetch(request)
        return potSizes.first?.toDTO()
    }
    
    func savePotSize(_ potSize: PotSizeDTO) async throws {
        let deviceRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        deviceRequest.predicate = NSPredicate(format: "uuid == %@", potSize.deviceUUID)
        deviceRequest.fetchLimit = 1
        
        guard let device = try context.fetch(deviceRequest).first else {
            throw RepositoryError.deviceNotFound
        }
        
        let existingRequest = NSFetchRequest<PotSize>(entityName: "PotSize")
        existingRequest.predicate = NSPredicate(format: "device.uuid == %@", potSize.deviceUUID)
        existingRequest.fetchLimit = 1
        
        let existingPotSizes = try context.fetch(existingRequest)
        let coreDataPotSize: PotSize
        
        if let existing = existingPotSizes.first {
            coreDataPotSize = existing
        } else {
            coreDataPotSize = PotSize(context: context)
            coreDataPotSize.device = device
        }
        
        coreDataPotSize.updateFromDTO(potSize)
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func deletePotSize(for deviceUUID: String) async throws {
        let request = NSFetchRequest<PotSize>(entityName: "PotSize")
        request.predicate = NSPredicate(format: "device.uuid == %@", deviceUUID)
        
        let potSizes = try context.fetch(request)
        for potSize in potSizes {
            context.delete(potSize)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
}
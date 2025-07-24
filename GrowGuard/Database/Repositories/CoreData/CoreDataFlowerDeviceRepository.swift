import Foundation
import CoreData

class CoreDataFlowerDeviceRepository: FlowerDeviceRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.context) {
        self.context = context
    }
    
    func getAllDevices() async throws -> [FlowerDeviceDTO] {
        let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        let devices = try context.fetch(request)
        return devices.compactMap { device in
            guard let dto = device.toDTO() else {
                print("Failed to convert FlowerDevice to DTO - skipping device")
                return nil
            }
            return dto
        }
    }
    
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? {
        let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        request.fetchLimit = 1
        
        let devices = try context.fetch(request)
        guard let device = devices.first else { return nil }
        
        return device.toDTO()
    }
    
    func saveDevice(_ device: FlowerDeviceDTO) async throws {
        let existingRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        existingRequest.predicate = NSPredicate(format: "uuid == %@", device.uuid)
        existingRequest.fetchLimit = 1
        
        let existingDevices = try context.fetch(existingRequest)
        let coreDataDevice: FlowerDevice
        
        if let existing = existingDevices.first {
            coreDataDevice = existing
        } else {
            coreDataDevice = FlowerDevice(context: context)
            coreDataDevice.uuid = device.uuid
        }
        
        coreDataDevice.updateFromDTO(device)
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func deleteDevice(uuid: String) async throws {
        let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        
        let devices = try context.fetch(request)
        for device in devices {
            context.delete(device)
        }
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func updateDevice(_ device: FlowerDeviceDTO) async throws {
        try await saveDevice(device)
    }
}
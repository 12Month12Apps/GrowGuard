import Foundation
import CoreData

class CoreDataFlowerDeviceRepository: FlowerDeviceRepository {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = DataService.shared.backgroundContext) {
        self.context = context
    }
    
    func getAllDevices() async throws -> [FlowerDeviceDTO] {
        return try await withCheckedThrowingContinuation { continuation in
            // CRITICAL FIX: Wrap in context.perform to prevent thread blocking
            context.perform {
                do {
                    let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
                    let devices = try self.context.fetch(request)
                    
                    // Convert to DTOs on background context - no more performAndWait blocking
                    let dtos = devices.compactMap { device -> FlowerDeviceDTO? in
                        guard let dto = device.toDTO() else {
                            print("Failed to convert FlowerDevice to DTO - skipping device")
                            return nil
                        }
                        return dto
                    }
                    
                    continuation.resume(returning: dtos)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO? {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
                    request.predicate = NSPredicate(format: "uuid == %@", uuid)
                    request.fetchLimit = 1
                    
                    let devices = try self.context.fetch(request)
                    let dto = devices.first?.toDTO()
                    
                    continuation.resume(returning: dto)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func saveDevice(_ device: FlowerDeviceDTO) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    let existingRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
                    existingRequest.predicate = NSPredicate(format: "uuid == %@", device.uuid)
                    existingRequest.fetchLimit = 1
                    
                    let existingDevices = try self.context.fetch(existingRequest)
                    let coreDataDevice: FlowerDevice
                    
                    if let existing = existingDevices.first {
                        coreDataDevice = existing
                    } else {
                        coreDataDevice = FlowerDevice(context: self.context)
                        coreDataDevice.uuid = device.uuid
                    }
                    
                    coreDataDevice.updateFromDTO(device)
                    
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
    
    func deleteDevice(uuid: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.perform {
                do {
                    let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
                    request.predicate = NSPredicate(format: "uuid == %@", uuid)
                    
                    let devices = try self.context.fetch(request)
                    for device in devices {
                        self.context.delete(device)
                    }
                    
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
    
    func updateDevice(_ device: FlowerDeviceDTO) async throws {
        try await saveDevice(device)
    }
}
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
//                    request.fetchLimit = 1
                    
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
                        print("💾 CoreDataFlowerDeviceRepository: Context has changes, saving...")
                        try self.context.save()
                        print("✅ CoreDataFlowerDeviceRepository: Context saved successfully")
                        print("  Device name in CoreData after save: '\(coreDataDevice.name ?? "nil")'")
                    } else {
                        print("ℹ️ CoreDataFlowerDeviceRepository: No changes to save")
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
                        // Manually delete related entities to avoid orphaned data
                        // since deletion rule is set to Nullify in Core Data model
                        
                        // Delete all sensor data for this device
                        if let sensorDataSet = device.sensorData {
                            for sensorData in sensorDataSet {
                                if let data = sensorData as? SensorData {
                                    self.context.delete(data)
                                }
                            }
                        }
                        
                        // Delete optimal range if it exists
                        if let optimalRange = device.optimalRange {
                            self.context.delete(optimalRange)
                        }
                        
                        // Delete pot size if it exists
                        if let potSize = device.potSize {
                            self.context.delete(potSize)
                        }
                        
                        // Finally delete the device itself
                        self.context.delete(device)
                    }
                    
                    if self.context.hasChanges {
                        try self.context.save()
                        print("Successfully deleted device with UUID: \(uuid) and all related data")
                    }
                    
                    continuation.resume()
                } catch {
                    print("Error deleting device with UUID \(uuid): \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func updateDevice(_ device: FlowerDeviceDTO) async throws {
        try await saveDevice(device)
    }
}

//
//  OverviewListViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import CoreData

@Observable class OverviewListViewModel {
    var allSavedDevices: [FlowerDeviceDTO] = []
    var deleteError: String? = nil
    var isDeleting = false
    private let repositoryManager = RepositoryManager.shared

    init() {}
    
    @MainActor
    func fetchSavedDevices() async {
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
            await syncLastUpdateTimestamps()
        } catch {
            print("Error fetching devices: \(error.localizedDescription)")
        }
    }

    /// Syncs lastUpdate timestamps based on latest sensor data for each device.
    /// Called when app opens to reflect data fetched via background/silent push.
    @MainActor
    private func syncLastUpdateTimestamps() async {
        for device in allSavedDevices {
            guard let latestSensorDate = device.sensorData.first?.date else { continue }

            // Only update if sensor data is newer than current lastUpdate
            if latestSensorDate > device.lastUpdate {
                let updatedDevice = FlowerDeviceDTO(
                    uuid: device.uuid,
                    name: device.name,
                    peripheralID: device.peripheralID,
                    battery: device.battery,
                    firmware: device.firmware,
                    isSensor: device.isSensor,
                    added: device.added,
                    lastUpdate: latestSensorDate,
                    lastHistoryIndex: device.lastHistoryIndex,
                    optimalRange: device.optimalRange,
                    potSize: device.potSize,
                    selectedFlower: device.selectedFlower,
                    sensorData: device.sensorData
                )

                do {
                    try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
                } catch {
                    print("Error updating lastUpdate for \(device.name ?? "Unknown"): \(error.localizedDescription)")
                }
            }
        }

        // Refresh the device list to reflect updated timestamps
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
        } catch {
            print("Error refreshing devices after sync: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func deleteDevice(at offsets: IndexSet) async {
        isDeleting = true
        deleteError = nil
        
        do {
            for index in offsets {
                let device = allSavedDevices[index]
                
                // Clear any cached sensor data for this device
                SensorDataManager.shared.clearCache(for: device.uuid)
                
                // Delete the device from the repository
                try await repositoryManager.flowerDeviceRepository.deleteDevice(uuid: device.uuid)
                print("Successfully deleted device: \(device.name ?? "Unknown")")
            }
            
            // Remove from local array
            allSavedDevices.remove(atOffsets: offsets)
            
        } catch {
            let errorMessage = "Failed to delete device: \(error.localizedDescription)"
            print(errorMessage)
            deleteError = errorMessage
        }
        
        isDeleting = false
    }
    
}

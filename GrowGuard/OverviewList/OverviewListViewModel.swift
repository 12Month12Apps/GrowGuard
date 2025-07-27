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

    init() {
        Task {
            await fetchSavedDevices()
        }
    }
    
    @MainActor
    func fetchSavedDevices() async {
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
        } catch {
            print("Error fetching devices: \(error.localizedDescription)")
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

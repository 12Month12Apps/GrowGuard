//
//  AddDeviceViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import CoreBluetooth
import SwiftData
import CoreData

@Observable class AddDeviceViewModel {
    var devices: [CBPeripheral] = []
    var addDevice:  CBPeripheral?
    private var ble: AddDeviceBLE?
    var allSavedDevices: [FlowerDeviceDTO] = []
    var nextPlantName: String?  // Suggested name for the next device to add
    var loading: Bool = false
    var bluetoothState: CBManagerState = .unknown
    private var loadingTask: Task<Void, Never>? = nil
    private var hasStartedScan = false
    private let repositoryManager = RepositoryManager.shared

    // NOTE: nextPlantName is calculated lazily when first accessed, not in init()
    // Because the calculation requires async database access
    
    @MainActor
    func startScanningIfNeeded() {
        guard hasStartedScan == false else { return }
        hasStartedScan = true
        loading = true
        devices = []

        ble = AddDeviceBLE(
            foundDevice: { [weak self] peripheral in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.addToList(peripheral: peripheral)
                    // After adding a device, recalculate nextPlantName for subsequent devices
                    await self.calculateNextPlantName()
                    self.loadingTask?.cancel()
                    self.loading = false
                }
            },
            stateChanged: { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.bluetoothState = state
                }
            }
        )

        ble?.startScanning()

        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await MainActor.run {
                guard let self = self else { return }
                if self.devices.isEmpty {
                    self.loading = false
                }
            }
        }
    }

    @MainActor
    func stopScanning() {
        loadingTask?.cancel()
        ble?.stopScanning()
        hasStartedScan = false
    }
    
    @MainActor
    func addToList(peripheral: CBPeripheral) {
        let exists = devices.first { element in
            element.identifier.uuidString == peripheral.identifier.uuidString
        }
        
        if exists == nil {
            devices.append(peripheral)
        }
    }
    
    /// Calculate the next plant name (gets called when fetchSavedDevices is first invoked)
    @MainActor
    func calculateNextPlantName() async -> Void {
        // Fetch all existing devices from the database
        do {
            let existingDevices = try await self.repositoryManager.flowerDeviceRepository.getAllDevices()
            
            // Calculate the next number (start at 1, increment by existing count)
            let nextNumber = existingDevices.count + devices.count
            
            // Format as "Plant N"
            self.nextPlantName = "Plant \(nextNumber)"
            
            AppLogger.ble.info("Calculate next plant name: \(self.nextPlantName ?? "failed") (existing: \(existingDevices.count) existing devices)")
            
        } catch {
            AppLogger.ble.error("Failed to calculate next plant name: \(error.localizedDescription)")
            
            // Fallback if there's an error - use "Unknown Device" or the BLE peripheral name
            self.nextPlantName = "Unknown Device"
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
}

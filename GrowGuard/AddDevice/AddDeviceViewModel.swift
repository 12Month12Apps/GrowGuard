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
    var devices: [DiscoveredDevice] = []
    var addDevice:  DiscoveredDevice?
    private var discovery: DeviceDiscovery?
    /// Factory for the discovery backend. Overridable for tests; in DEBUG it
    /// returns the bridge scanner when `GROWGUARD_BLE_BRIDGE` is set.
    var makeDiscovery: () -> DeviceDiscovery = { AddDeviceViewModel.defaultDiscovery() }
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

        let discovery = makeDiscovery()
        discovery.onFound = { [weak self] device in
            Task { @MainActor in
                guard let self = self else { return }
                self.addToList(device)
                // After adding a device, recalculate nextPlantName for subsequent devices
                await self.calculateNextPlantName()
                self.loadingTask?.cancel()
                self.loading = false
            }
        }
        discovery.onState = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                self.bluetoothState = state
            }
        }
        self.discovery = discovery
        discovery.start()

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
        discovery?.stop()
        hasStartedScan = false
    }

    @MainActor
    func addToList(_ device: DiscoveredDevice) {
        if !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
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

    /// The discovery backend used in production. Real CoreBluetooth scan by
    /// default; in DEBUG, the bridge scanner when `GROWGUARD_BLE_BRIDGE` is set.
    static func defaultDiscovery() -> DeviceDiscovery {
        #if DEBUG
        if let endpoint = BLEBridgeConfig.endpoint {
            AppLogger.ble.info("🔌 Add Device using bridge discovery → \(endpoint.host):\(endpoint.port)")
            return BridgeDeviceDiscovery(channel: NWBridgeChannel(host: endpoint.host, port: endpoint.port))
        }
        AppLogger.ble.info("🔍 Add Device using CoreBluetooth scan (GROWGUARD_BLE_BRIDGE not set — iOS Simulator has no Bluetooth)")
        #endif
        return CoreBluetoothDeviceDiscovery()
    }
}

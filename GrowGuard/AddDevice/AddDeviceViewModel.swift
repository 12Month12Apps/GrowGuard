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
    var ble: AddDeviceBLE?
    var allSavedDevices: [FlowerDeviceDTO] = []
    var loading: Bool = false
    private var loadingTask: Task<Void, Never>? = nil
    private let repositoryManager = RepositoryManager.shared
    
    init() {
        loading = true
        self.devices = []

        self.ble = AddDeviceBLE { peripheral in
            self.addToList(peripheral: peripheral)
            self.loadingTask?.cancel()
            self.loading = false
        }

        // Timeout-Task starten
        self.loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await MainActor.run {
                if let self = self, self.devices.isEmpty {
                    self.loading = false
                }
            }
        }

        Task {
            await fetchSavedDevices()
        }
    }
    
    func addToList(peripheral: CBPeripheral) {
        let exists = devices.first { element in
            element.identifier.uuidString == peripheral.identifier.uuidString
        }
        
        if exists == nil {
            devices.append(peripheral)
        }
    }
    
    @MainActor
    func tapOnDevice(peripheral: CBPeripheral) async {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == peripheral.identifier.uuidString
        })
        
        if isSaved == false {
            self.addDevice = peripheral
            let newDeviceDTO = FlowerDeviceDTO(
                name: peripheral.name ?? "Unknown Device",
                uuid: peripheral.identifier.uuidString,
                peripheralID: peripheral.identifier,
                added: Date(),
                lastUpdate: Date()
            )
            
            do {
                try await repositoryManager.flowerDeviceRepository.saveDevice(newDeviceDTO)
                await fetchSavedDevices()
            } catch {
                print("Error saving device: \(error.localizedDescription)")
            }
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

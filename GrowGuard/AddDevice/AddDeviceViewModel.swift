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
    var loading: Bool = false
    private var loadingTask: Task<Void, Never>? = nil
    private var hasStartedScan = false
    private let repositoryManager = RepositoryManager.shared
    
    init() {}
    
    @MainActor
    func startScanningIfNeeded() {
        guard hasStartedScan == false else { return }
        hasStartedScan = true
        loading = true
        devices = []

        ble = AddDeviceBLE { [weak self] peripheral in
            Task { @MainActor in
                guard let self = self else { return }
                self.addToList(peripheral: peripheral)
                self.loadingTask?.cancel()
                self.loading = false
            }
        }

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

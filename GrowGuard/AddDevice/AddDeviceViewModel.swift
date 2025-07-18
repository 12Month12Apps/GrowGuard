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

@Observable class AddDeviceViewModel {
    var devices: [CBPeripheral] = []
    var addDevice:  CBPeripheral?
    var ble: AddDeviceBLE?
    var allSavedDevices: [FlowerDevice] = []
    var loading: Bool = false
    private var loadingTask: Task<Void, Never>? = nil
    
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
    func tapOnDevice(peripheral: CBPeripheral) {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == peripheral.identifier.uuidString
        })
        
        if isSaved == false {
            self.addDevice = peripheral
            let newItem = FlowerDevice(added: Date(),
                                       lastUpdate: Date(),
                                       peripheral: peripheral)
            
            DataService.sharedModelContainer.mainContext.insert(newItem)
            do {
                try DataService.sharedModelContainer.mainContext.save()
                self.fetchSavedDevices()
            } catch {
                print(error.localizedDescription)
            }
        }
    }
    
    @MainActor
    func fetchSavedDevices() {
        let fetchDescriptor = FetchDescriptor<FlowerDevice>()

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
            allSavedDevices = result
        } catch{
            print(error.localizedDescription)
        }
    }
}

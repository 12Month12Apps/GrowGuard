//
//  Settings.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import SwiftUI
import Foundation

@Observable
class SettingsViewModel {
    var potSize: PotSizeDTO
    var optimalRange: OptimalRangeDTO
    var selectedFlower: VMSpecies? {
        didSet {
            if !isLoadingData {
                updateOptimalRangeFromFlower()
            }
        }
    }
    var isLoading: Bool = false
    private var isLoadingData: Bool = false
    private let deviceUUID: String
    private let repositoryManager = RepositoryManager.shared
    
    init(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        // Initialize with default values, will be loaded in loadSettings()
        self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
        self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
        self.selectedFlower = nil
    }
    
    @MainActor
    func loadSettings() async {
        isLoading = true
        isLoadingData = true
        print("🔧 SettingsViewModel: Loading settings for device \(deviceUUID)")
        
        await withTaskGroup(of: Void.self) { group in
            // Load potSize and optimalRange concurrently
            group.addTask { [weak self] in
                await self?.loadPotSize()
            }
            
            group.addTask { [weak self] in
                await self?.loadOptimalRange()
            }
            
            group.addTask { [weak self] in
                await self?.loadSelectedFlower()
            }
        }
        
        isLoadingData = false
        isLoading = false
        print("✅ SettingsViewModel: Settings loaded successfully")
    }
    
    @MainActor
    private func loadPotSize() async {
        do {
            if let loadedPotSize = try await repositoryManager.potSizeRepository.getPotSize(for: deviceUUID) {
                print("  Loaded PotSize - Width/Height/Volume: \(loadedPotSize.width)/\(loadedPotSize.height)/\(loadedPotSize.volume)")
                self.potSize = loadedPotSize
            } else {
                print("  No PotSize found, using defaults")
                self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load potSize: \(error)")
            self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
        }
    }
    
    @MainActor
    private func loadOptimalRange() async {
        do {
            if let loadedOptimalRange = try await repositoryManager.optimalRangeRepository.getOptimalRange(for: deviceUUID) {
                print("  Loaded OptimalRange - Min/Max Temp: \(loadedOptimalRange.minTemperature)/\(loadedOptimalRange.maxTemperature)")
                self.optimalRange = loadedOptimalRange
            } else {
                print("  No OptimalRange found, using defaults")
                self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load optimalRange: \(error)")
            self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
        }
    }
    
    @MainActor
    private func loadSelectedFlower() async {
        print("🔍 SettingsViewModel.loadSelectedFlower: Starting for device \(deviceUUID)")
        do {
            if let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) {
                print("🔍 Device found, selectedFlower: \(device.selectedFlower?.name ?? "nil")")
                self.selectedFlower = device.selectedFlower
                if let flower = device.selectedFlower {
                    print("✅  Loaded SelectedFlower: \(flower.name) (ID: \(flower.id))")
                } else {
                    print("ℹ️  No flower selected for this device")
                }
            } else {
                print("❌  Device not found, no flower information available")
                self.selectedFlower = nil
            }
        } catch {
            print("❌ SettingsViewModel: Failed to load selectedFlower: \(error)")
            self.selectedFlower = nil
        }
    }
    
    func getUpdatedPotSize() -> PotSizeDTO {
        return potSize
    }
    
    func getUpdatedOptimalRange() -> OptimalRangeDTO {
        return optimalRange
    }
    
    func getSelectedFlower() -> VMSpecies? {
        return selectedFlower
    }
    
    @MainActor
    func saveSettings() async throws {
        print("💾 SettingsViewModel: Saving settings for device \(deviceUUID)")
        
        // Get current device first
        guard let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) else {
            print("❌ SettingsViewModel.saveSettings: Device not found")
            throw RepositoryError.deviceNotFound
        }
        
        // Save potSize and optimalRange separately first (these have their own entities)
        try await repositoryManager.potSizeRepository.savePotSize(potSize)
        print("  Saved PotSize - Width/Height/Volume: \(potSize.width)/\(potSize.height)/\(potSize.volume)")
        
        try await repositoryManager.optimalRangeRepository.saveOptimalRange(optimalRange)
        print("  Saved OptimalRange - Min/Max Temp: \(optimalRange.minTemperature)/\(optimalRange.maxTemperature)")
        
        // Now update the device with the selectedFlower in a single operation
        let updatedDevice = FlowerDeviceDTO(
            id: device.id,
            name: device.name,
            uuid: device.uuid,
            peripheralID: device.peripheralID,
            battery: device.battery,
            firmware: device.firmware,
            isSensor: device.isSensor,
            added: device.added,
            lastUpdate: device.lastUpdate,
            optimalRange: device.optimalRange, // Keep existing relationships
            potSize: device.potSize, // Keep existing relationships
            selectedFlower: selectedFlower, // Only update the flower
            sensorData: device.sensorData
        )
        
        print("🔧 Saving device with flower: \(selectedFlower?.name ?? "nil") (ID: \(selectedFlower?.id ?? 0))")
        try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
        
        if let flower = selectedFlower {
            print("✅  Saved SelectedFlower: \(flower.name) (ID: \(flower.id))")
        } else {
            print("✅  Removed flower selection")
        }
        
        print("✅ SettingsViewModel: Settings saved successfully")
    }
    
    
    private func updateOptimalRangeFromFlower() {
        guard let flower = selectedFlower else { return }
        
        // Update moisture values if the selected flower has them
        if let minMoisture = flower.minMoisture {
            optimalRange = OptimalRangeDTO(
                id: optimalRange.id,
                minTemperature: optimalRange.minTemperature,
                maxTemperature: optimalRange.maxTemperature,
                minBrightness: optimalRange.minBrightness,
                maxBrightness: optimalRange.maxBrightness,
                minMoisture: Int16(minMoisture),
                maxMoisture: flower.maxMoisture != nil ? Int16(flower.maxMoisture!) : optimalRange.maxMoisture,
                minConductivity: optimalRange.minConductivity,
                maxConductivity: optimalRange.maxConductivity,
                deviceUUID: optimalRange.deviceUUID
            )
            print("🌱 SettingsViewModel: Updated moisture range from flower - Min: \(minMoisture), Max: \(flower.maxMoisture ?? Int(optimalRange.maxMoisture))")
        }
    }
}

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var isSaving = false
    @State private var saveError: Error?
    @State private var showSaveError = false
    @State private var showFlowerSelection = false
    let isSensor: Bool
    let onSave: (OptimalRangeDTO, PotSizeDTO) -> Void
    @Environment(\.dismiss) private var dismiss
    
    init(deviceUUID: String, isSensor: Bool = true, onSave: @escaping (OptimalRangeDTO, PotSizeDTO) -> Void) {
        self.isSensor = isSensor
        self.onSave = onSave
        self._viewModel = State(initialValue: SettingsViewModel(deviceUUID: deviceUUID))
    }
    
    var calculatedVolume: Double? {
        guard viewModel.potSize.width > 0, viewModel.potSize.height > 0 else { return nil }
        let radius = viewModel.potSize.width
        return Double.pi * pow(radius, 2) * viewModel.potSize.height
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                List {
                
                Section(header: Text("Flower Pot")) {
                    HStack {
                        Text("Pot radius (cm)")
                        TextField("0", value: $viewModel.potSize.width, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Pot height (cm)")
                        TextField("0", value: $viewModel.potSize.height, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    VStack {
                        Text("Volume can be automaticily be calculated, but if you know yours please enter it here to be more precise")
                            .font(.caption)
                        HStack {
                            Text("Pot volume")
                            TextField("0", value: $viewModel.potSize.volume, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        if let calculated = calculatedVolume {
                            Text("Automatisch berechnetes Volumen: \(String(format: "%.1f", calculated)) cm³")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                viewModel.potSize.volume = calculated
                            } label: {
                                Text("Accept calculation")
                            }

                        }
                    }
                }
                
                Section(header: Text("Plant Selection")) {
                    if let selectedFlower = viewModel.selectedFlower {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(selectedFlower.name)
                                        .font(.headline)
                                    
                                    if let minMoisture = selectedFlower.minMoisture,
                                       let maxMoisture = selectedFlower.maxMoisture {
                                        Text("Recommended Moisture: \(minMoisture)% - \(maxMoisture)%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                Button("Change") {
                                    showFlowerSelection = true
                                }
                            }
                            
                            Button("Remove Plant") {
                                viewModel.selectedFlower = nil
                            }
                            .foregroundColor(.red)
                        }
                    } else {
                        Button("Select Plant") {
                            showFlowerSelection = true
                        }
                    }
                }
                
                Section(header: Text("Moisture")) {
                    if let selectedFlower = viewModel.selectedFlower,
                       selectedFlower.minMoisture != nil || selectedFlower.maxMoisture != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Values automatically set from selected plant")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text("Plant: \(selectedFlower.name)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Text("Min Moisture")
                        TextField("0", value: $viewModel.optimalRange.minMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Moisture")
                        TextField("0", value: $viewModel.optimalRange.maxMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                if isSensor {
                    Section(header: Text("Brightness")) {
                        HStack {
                            Text("Min Brightness")
                            TextField("0", value: $viewModel.optimalRange.minBrightness, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Brightness")
                            TextField("0", value: $viewModel.optimalRange.maxBrightness, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                    
                    Section(header: Text("Temperature")) {
                        HStack {
                            Text("Min Temperature")
                            TextField("0", value: $viewModel.optimalRange.minTemperature, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Temperature")
                            TextField("0", value: $viewModel.optimalRange.maxTemperature, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                    
                    Section(header: Text("Conductivity")) {
                        HStack {
                            Text("Min Conductivity")
                            TextField("0", value: $viewModel.optimalRange.minConductivity, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Conductivity")
                            TextField("0", value: $viewModel.optimalRange.maxConductivity, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                }
                }
                .disabled(viewModel.isLoading || isSaving)
                
                if viewModel.isLoading || isSaving {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(viewModel.isLoading ? "Loading..." : "Saving...")
                            .padding(.top)
                    }
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .cornerRadius(10)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(viewModel.isLoading || isSaving)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveSettings()
                        }
                    }
                    .disabled(viewModel.isLoading || isSaving)
                }
            }
            .navigationTitle("Settings")
            .task {
                await viewModel.loadSettings()
            }
            .alert("Save Error", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text(saveError?.localizedDescription ?? "Unknown error occurred")
            }
            .sheet(isPresented: $showFlowerSelection) {
                FlowerSelectionView(selectedFlower: $viewModel.selectedFlower)
            }
        }
    }
    
    @MainActor
    private func saveSettings() async {
        isSaving = true
        
        do {
            try await viewModel.saveSettings()
            
            let updatedOptimalRange = viewModel.getUpdatedOptimalRange()
            let updatedPotSize = viewModel.getUpdatedPotSize()
            
            onSave(updatedOptimalRange, updatedPotSize)
            dismiss()
        } catch {
            saveError = error
            showSaveError = true
        }
        
        isSaving = false
    }
}

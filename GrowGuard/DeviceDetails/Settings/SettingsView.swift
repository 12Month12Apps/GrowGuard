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
    var isLoading: Bool = false
    private let deviceUUID: String
    private let repositoryManager = RepositoryManager.shared
    
    init(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        // Initialize with default values, will be loaded in loadSettings()
        self.potSize = PotSizeDTO(deviceUUID: deviceUUID)
        self.optimalRange = OptimalRangeDTO(deviceUUID: deviceUUID)
    }
    
    @MainActor
    func loadSettings() async {
        isLoading = true
        print("🔧 SettingsViewModel: Loading settings for device \(deviceUUID)")
        
        await withTaskGroup(of: Void.self) { group in
            // Load potSize and optimalRange concurrently
            group.addTask { [weak self] in
                await self?.loadPotSize()
            }
            
            group.addTask { [weak self] in
                await self?.loadOptimalRange()
            }
        }
        
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
    
    func getUpdatedPotSize() -> PotSizeDTO {
        return potSize
    }
    
    func getUpdatedOptimalRange() -> OptimalRangeDTO {
        return optimalRange
    }
    
    @MainActor
    func saveSettings() async throws {
        print("💾 SettingsViewModel: Saving settings for device \(deviceUUID)")
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self = self else { return }
                try await self.repositoryManager.potSizeRepository.savePotSize(self.potSize)
                print("  Saved PotSize - Width/Height/Volume: \(self.potSize.width)/\(self.potSize.height)/\(self.potSize.volume)")
            }
            
            group.addTask { [weak self] in
                guard let self = self else { return }
                try await self.repositoryManager.optimalRangeRepository.saveOptimalRange(self.optimalRange)
                print("  Saved OptimalRange - Min/Max Temp: \(self.optimalRange.minTemperature)/\(self.optimalRange.maxTemperature)")
            }
            
            // Wait for all saves to complete
            try await group.waitForAll()
        }
        
        print("✅ SettingsViewModel: Settings saved successfully")
    }
}

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var isSaving = false
    @State private var saveError: Error?
    @State private var showSaveError = false
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
                
                Section(header: Text("Moisture")) {
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

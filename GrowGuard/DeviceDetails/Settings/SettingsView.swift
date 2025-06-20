//
//  Settings.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import SwiftUI
import Foundation

struct SettingsView: View {
    @Binding var potSize: PotSize
    @Binding var optimalRange: OptimalRange
    var isSensor = true
    @Environment(\.dismiss) private var dismiss
    
    var calculatedVolume: Double? {
        guard potSize.width > 0, potSize.height > 0 else { return nil }
        let radius = potSize.width
        return Double.pi * pow(radius, 2) * potSize.height
    }
    
    var body: some View {
        NavigationView {
            List {
                
                Section(header: Text("Flower Pot")) {
                    HStack {
                        Text("Pot radius (cm)")
                        TextField("0", value: $potSize.width, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Pot height (cm)")
                        TextField("0", value: $potSize.height, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    VStack {
                        Text("Volume can be automaticily be calculated, but if you know yours please enter it here to be more precise")
                            .font(.caption)
                        HStack {
                            Text("Pot volume")
                            TextField("0", value: $potSize.volume, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        if let calculated = calculatedVolume {
                            Text("Automatisch berechnetes Volumen: \(String(format: "%.1f", calculated)) cm³")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                potSize.volume = calculated
                            } label: {
                                Text("Accpet calculation")
                            }

                        }
                    }
                }
                
                Section(header: Text("Moisture")) {
                    HStack {
                        Text("Min Moisture")
                        TextField("0", value: $optimalRange.minMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Moisture")
                        TextField("0", value: $optimalRange.maxMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                if isSensor {
                    Section(header: Text("Brigtness")) {
                        HStack {
                            Text("Min Brigtness")
                            TextField("0", value: $optimalRange.minBrightness, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Brigtness")
                            TextField("0", value: $optimalRange.maxBrightness, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                    
                    Section(header: Text("Temperature")) {
                        HStack {
                            Text("Min Temperature")
                            TextField("0", value: $optimalRange.minTemperature, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Temperature")
                            TextField("0", value: $optimalRange.maxTemperature, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                    
                    Section(header: Text("Conductivity")) {
                        HStack {
                            Text("Min Conductivity")
                            TextField("0", value: $optimalRange.minConductivity, format: .number)
                                .keyboardType(.decimalPad)
                        }
                        
                        HStack {
                            Text("Max Conductivity")
                            TextField("0", value: $optimalRange.maxConductivity, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

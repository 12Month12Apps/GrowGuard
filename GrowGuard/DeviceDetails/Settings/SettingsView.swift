//
//  Settings.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import SwiftUI

struct SettingsView: View {
    @Binding var optimalRange: OptimalRange
    
    var body: some View {
        List {
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
}

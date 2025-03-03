//
//  DeviceDetailsView.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import SwiftUI

struct DeviceDetailsView: View {
    @State var viewModel: DeviceDetailsViewModel
    @State var showSetting: Bool = false
    @State private var showCopyAlert = false
    @State private var optimalRange: OptimalRange = OptimalRange(minTemperature: 0, minBrightness: 0, minMoisture: 70, minConductivity: 0, maxTemperature: 0, maxBrightness: 0, maxMoisture: 0, maxConductivity: 0)

    init(device: FlowerDevice) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        List {
            TextField("Device Name", text: $viewModel.device.name)
            Text("Added: ") + Text(viewModel.device.added, format: .dateTime)
            Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
            HStack {
                Text("ID: ") + Text(viewModel.device.uuid)
                
                Spacer()
                
                Button(action: {
                    UIPasteboard.general.string = viewModel.device.uuid
                    showCopyAlert.toggle()
                }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                }
                .alert(isPresented: $showCopyAlert) {
                    Alert(title: Text("Copied"), message: Text("ID copied to clipboard"), dismissButton: .default(Text("OK")))
                }
            }
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.brightness,
                            title: "Brightness",
                            dataType: "lux",
                            selectedChartType: .bars,
                            minRange: Int(viewModel.device.optimalRange.minBrightness),
                            maxRange: Int(viewModel.device.optimalRange.maxBrightness))
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.moisture,
                            title: "Moisture",
                            dataType: "%",
                            selectedChartType: .water,
                            minRange: Int(viewModel.device.optimalRange.minMoisture),
                            maxRange: Int(viewModel.device.optimalRange.maxMoisture))
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.temperature,
                            title: "Temperature",
                            dataType: "C",
                            selectedChartType: .bars,
                            minRange: Int(viewModel.device.optimalRange.minTemperature),
                            maxRange: Int(viewModel.device.optimalRange.maxTemperature))
            
            Button("Delete", role: .destructive) {
                viewModel.delete()
            }

        }.onAppear {
            self.viewModel.loadDetails()
            self.optimalRange = viewModel.device.optimalRange
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSetting.toggle()
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .navigationTitle(viewModel.device.name)
        .sheet(isPresented: $showSetting, onDismiss: {
            viewModel.device.optimalRange = optimalRange
            viewModel.saveDatabase()
        }) {
            SettingsView(optimalRange: $optimalRange)
        }
    }
}



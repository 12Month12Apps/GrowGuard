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
    @State private var optimalRange: OptimalRange?
    @State private var showingLoadingScreen = false
    @State private var waterFill: CGFloat = 0.0
    @State private var waterFillProzentage: CGFloat = 0.0

    private var sensorDataBinding: Binding<[SensorData]> {
        Binding<[SensorData]>(
            get: { Array((viewModel.device.sensorData as? Set<SensorData>) ?? []) },
            set: { viewModel.device.sensorData = NSSet(array: $0) }
        )
    }

    init(device: FlowerDevice) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        TextField("Device Name", text: Binding(
                            get: { viewModel.device.name ?? "" },
                            set: { viewModel.device.name = $0 }
                        ))
                        if let lastUpdate = viewModel.device.lastUpdate {
                            Text("Last Update: ") + Text(lastUpdate, format: .dateTime)
                        }
                        
                        if viewModel.device.isSensor {
                            Button {
                                viewModel.fetchHistoricalData()
                                showingLoadingScreen = true
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text("Load Historical Data")
                                }
                            }
                            .padding(.vertical, 5)
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        } else {
                            Text("This plant does not have a sensor attached. You need to manage the watering manually.")
                                .font(.caption)
                                .padding([.top], 5)
                        }
                    }
                    
                    VStack(alignment: .trailing) {
                        if viewModel.device.isSensor {
                            HStack(spacing: 2) {
                                Text(viewModel.device.battery, format: .percent)
                                Image(systemName: "battery.75percent")
                                    .frame(width: 30, alignment: .center)
                            }
                            
                            Button {
                                viewModel.blinkLED()
                            } label: {
                                HStack(spacing: 2) {
                                    Text("Blink")
                                    Image(systemName: "flashlight.off.fill")
                                        .frame(width: 30, alignment: .center)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                        }
                        
                        Button {
                            
                        } label: {
                            HStack(spacing: 2) {
                                Text("Info")
                                Image(systemName: "info.circle")
                                    .frame(width: 30, alignment: .center)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                }
            }
            
//            TextField("Device Name", text: $viewModel.device.name)
//            Text("Added: ") + Text(viewModel.device.added, format: .dateTime)
//            Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
//            Text("Battery: ") + Text(viewModel.device.battery, format: .percent)
//            Text("Firmware: ") + Text(viewModel.device.firmware)
            

            if let nextWatering = PlantMonitorService.shared.predictNextWatering(for: viewModel.device) {
                Section(header: Text("Prediction")) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                        Text("Next watering needed:")
                        Spacer()
                        Text(nextWatering, style: .relative)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            if viewModel.device.isSensor {
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: sensorDataBinding,
                                keyPath: \.brightness,
                                title: "Brightness",
                                dataType: "lux",
                                selectedChartType: .bars,
                                minRange: Int(viewModel.device.optimalRange?.minBrightness ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxBrightness ?? 0))
                
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: sensorDataBinding,
                                keyPath: \.moisture,
                                title: "Moisture",
                                dataType: "%",
                                selectedChartType: .water,
                                minRange: Int(viewModel.device.optimalRange?.minMoisture ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxMoisture ?? 0))
                
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: sensorDataBinding,
                                keyPath: \.temperature,
                                title: "Temperature",
                                dataType: "C",
                                selectedChartType: .bars,
                                minRange: Int(viewModel.device.optimalRange?.minTemperature ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxTemperature ?? 0))
                
                
                Section {
                    Text("You cann use this ID to setup an shortcut to this device in the Shortcuts app. This will allow you to quickly refresh the devices data and setup automations without having to open the app.")
                    
                    HStack {
                        Text("ID: ") + Text(viewModel.device.uuid ?? "")
                        
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
                }
            } else {
                Section {
                    VStack {
                        WaterFillPotView(fill: $waterFillProzentage)
                        
                        Divider()
                        
                        HStack(alignment: .center) {
                            Button {
//                                if round(waterFillProzentage * 10) / 10 > 0 {
                                    waterFill -= 0.1
                                    waterFillProzentage = round(waterFill / (viewModel.device.potSize.volume / 1000) * 100) / 100
//                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            
                            Text("100ml")
                            
                            Button {
//                                if round(waterFillProzentage * 10) / 10 < 1 {
                                    waterFill += 0.1
                                    waterFillProzentage = round(waterFill / (viewModel.device.potSize.volume / 1000) * 100) / 100
                                    print(waterFill)
//                                }
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                        
                        Divider()
                        
                        VStack {
                            Text("Max pot volume: \(viewModel.device.potSize.volume / 1000, specifier: "%.1f")l")
                                .frame(maxWidth: .infinity, alignment: .center)
                            Text("Current fill volume: \(waterFill, specifier: "%.1f")l")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .frame(maxWidth: .infinity)
                        
                        Divider()
                        
                        VStack {
                            Button("Save Water") {
                                viewModel.device.sensorData.append(SensorData(temperature: 0,
                                                                              brightness: 0,
                                                                              moisture: UInt8(waterFillProzentage * 100),
                                                                              conductivity: 0,
                                                                              date: Date(),
                                                                              device: viewModel.device))
                                viewModel.saveDatabase()
                            }
                        }
                    }
                }
                
                if !viewModel.device.sensorData.isEmpty {
                    SensorDataChart(isOverview: false,
                                    componet: viewModel.groupingOption,
                                    data: sensorDataBinding,
                                    keyPath: \.moisture,
                                    title: "Moisture",
                                    dataType: "%",
                                    selectedChartType: .water,
                                    minRange: Int(viewModel.device.optimalRange.minMoisture),
                                    maxRange: Int(viewModel.device.optimalRange.maxMoisture))
                }
            }

        }.onAppear {
            self.viewModel.loadDetails()
            self.optimalRange = viewModel.device.optimalRange
        }
        .refreshable {
            if viewModel.device.isSensor {
                self.viewModel.loadDetails()
            }
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
        .navigationTitle(viewModel.device.name ?? "")
        .sheet(isPresented: $showSetting, onDismiss: {
            viewModel.device.optimalRange = optimalRange
            viewModel.saveDatabase()
        }) {
            SettingsView(potSize: $viewModel.device.potSize, optimalRange: $optimalRange, isSensor: viewModel.device.isSensor)
        }
        .sheet(isPresented: $showingLoadingScreen) {
            HistoryLoadingView()
        }
    }
}


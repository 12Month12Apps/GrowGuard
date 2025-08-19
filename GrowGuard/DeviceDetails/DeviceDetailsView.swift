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
    @State private var showingLoadingScreen = false
    @State private var wateringPrediction: WateringPrediction? = nil
    @State private var justWatered = false


    init(device: FlowerDeviceDTO) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        TextField("Device Name", text: Binding(
                            get: { viewModel.device.name },
                            set: { _ in /* Read-only for now */ }
                        ))
                        Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
                        
                        if viewModel.device.isSensor {
                            // Connection quality hint
                            if !viewModel.connectionDistanceHint.isEmpty {
                                HStack {
                                    Text(viewModel.connectionDistanceHint)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            
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

            // Urgent watering alert at the top
            if let prediction = wateringPrediction, prediction.isUrgent {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading) {
                            Text("Urgent: Water Needed Now!")
                                .font(.headline)
                                .foregroundColor(.red)
                            Text("Your plant needs water today")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.red.opacity(0.1))
            }
            
            if let prediction = wateringPrediction {
                Section(header: Text("Watering Prediction")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: prediction.isUrgent ? "exclamationmark.triangle.fill" : "calendar.badge.clock")
                                .foregroundColor(prediction.isUrgent ? .red : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next watering needed:")
                                    .font(.subheadline)
                                Text(prediction.predictedDate, style: .relative)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(prediction.predictedDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                                    .font(.headline)
                                    .foregroundColor(prediction.isUrgent ? .red : .blue)
                                Text(prediction.predictedDate, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Prediction details
                        HStack {
                            Image(systemName: "drop.circle")
                                .foregroundColor(.blue)
                            Text("Current: \(Int(prediction.currentMoisture))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Target: \(Int(prediction.targetMoisture))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundColor(.secondary)
                            Text("Confidence: \(prediction.confidenceLevel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(prediction.dryingRatePerDay.rounded(toPlaces: 1))%/day drying")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let lastWatering = prediction.lastWateringEvent {
                            HStack {
                                Image(systemName: "drop.fill")
                                    .foregroundColor(.blue)
                                Text("Last watered:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(lastWatering, style: .relative)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            
            if viewModel.device.isSensor {
                // Week navigation controls
                Section(header: 
                    HStack {
                        Text("Sensor Data")
                        Spacer()
                        HStack {
                            Button("‹", action: {
                                Task { await viewModel.goToPreviousWeek() }
                            })
                            .disabled(viewModel.isLoadingSensorData)
                            
                            Text(viewModel.currentWeekDisplayText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Button("›", action: {
                                Task { await viewModel.goToNextWeek() }
                            })
                            .disabled(viewModel.isLoadingSensorData)
                            
                            Button("↻", action: {
                                Task { await viewModel.refreshCurrentWeek() }
                            })
                            .disabled(viewModel.isLoadingSensorData)
                        }
                        .font(.title2)
                    }
                ) {
                    if viewModel.isLoadingSensorData {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading week data...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
                
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: .constant(viewModel.currentWeekData),
                                keyPath: \.brightness,
                                title: "Brightness",
                                dataType: "lux",
                                selectedChartType: .bars,
                                minRange: Int(viewModel.device.optimalRange?.minBrightness ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxBrightness ?? 0))
                
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: .constant(viewModel.currentWeekData),
                                keyPath: \.moisture,
                                title: "Moisture",
                                dataType: "%",
                                selectedChartType: .water,
                                minRange: Int(viewModel.device.optimalRange?.minMoisture ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxMoisture ?? 0))
                
                SensorDataChart(isOverview: false,
                                componet: viewModel.groupingOption,
                                data: .constant(viewModel.currentWeekData),
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
                if let potSize = viewModel.device.potSize {
                    PotView(potSize: Binding(
                        get: { viewModel.device.potSize ?? potSize },
                        set: { viewModel.device.potSize = $0 }
                    ))
                }
                
                SensorDataChart(
                    isOverview: false,
                    componet: viewModel.groupingOption,
                    data: .constant(viewModel.currentWeekData),
                    keyPath: \.moisture,
                    title: "Moisture",
                    dataType: "%",
                    selectedChartType: .water,
                    minRange: Int(viewModel.device.optimalRange?.minMoisture ?? 0),
                    maxRange: Int(viewModel.device.optimalRange?.maxMoisture ?? 0)
                )
            }

        }.onAppear {
            self.viewModel.loadDetails()
            
            Task {
                await refreshPrediction()
            }
        }
        .refreshable {
            if viewModel.device.isSensor {
                self.viewModel.loadDetails()
            }
            
            Task {
                await refreshPrediction()
            }
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
        .sheet(isPresented: $showSetting) {
            SettingsView(
                deviceUUID: viewModel.device.uuid,
                isSensor: viewModel.device.isSensor
            ) { updatedOptimalRange, updatedPotSize in
                // Handle save callback
                print("🔄 DeviceDetailsView: Received settings to save:")
                print("  OptimalRange - Min/Max Temp: \(updatedOptimalRange.minTemperature)/\(updatedOptimalRange.maxTemperature)")
                print("  PotSize - Width/Height/Volume: \(updatedPotSize.width)/\(updatedPotSize.height)/\(updatedPotSize.volume)")
                
                Task {
                    do {
                        try await viewModel.saveSettings(
                            optimalRange: updatedOptimalRange,
                            potSize: updatedPotSize
                        )
                        print("✅ DeviceDetailsView: Settings saved successfully via callback")
                    } catch {
                        print("❌ DeviceDetailsView: Failed to save settings: \(error)")
                        // Handle error gracefully - could show alert to user in real app
                    }
                }
            }
        }
        .sheet(isPresented: $showingLoadingScreen) {
            HistoryLoadingView()
        }
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func refreshPrediction() async {
        guard viewModel.device.isSensor else {
            wateringPrediction = nil
            return
        }
        
        // Debug logging for chart vs prediction moisture discrepancy
        let latestChartData = viewModel.currentWeekData.sorted(by: { $0.date < $1.date }).last
        if let chartData = latestChartData {
            print("🔍 DeviceDetailsView: Latest chart data: \(chartData.moisture)% at \(chartData.date)")
        }
        
        do {
            wateringPrediction = try await PlantMonitorService.shared.predictNextWatering(for: viewModel.device)
            if let prediction = wateringPrediction {
                print("🔍 DeviceDetailsView: Prediction shows current moisture: \(Int(prediction.currentMoisture))%")
            }
        } catch {
            print("Failed to get watering prediction: \(error)")
            wateringPrediction = nil
        }
    }
}


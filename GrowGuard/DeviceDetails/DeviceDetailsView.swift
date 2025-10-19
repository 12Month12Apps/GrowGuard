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
        ScrollView {
            VStack(spacing: 20) {
                // Header Card
                VStack(spacing: 16) {
                    // Device name and last update
                    VStack(spacing: 8) {
                        Text(viewModel.device.name ?? "")
                            .font(.title)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption)
                            Text(L10n.Device.lastUpdate)
                                .font(.caption)
                            Text(viewModel.device.lastUpdate, format: .dateTime)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Action buttons
                    if viewModel.device.isSensor {
                        HStack(spacing: 12) {
                            // Battery indicator
                            HStack(spacing: 6) {
                                Image(systemName: "battery.75percent")
                                    .foregroundColor(.green)
                                Text(viewModel.device.battery, format: .percent)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(10)

                            Spacer()

                            // Blink LED button
                            Button {
                                viewModel.blinkLED()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "flashlight.off.fill")
                                    Text(L10n.Device.blink)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(10)
                            }
                        }

                        // Connection quality hint
                        if !viewModel.connectionDistanceHint.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                                Text(viewModel.connectionDistanceHint)
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider()

                        // Data management buttons
                        VStack(spacing: 10) {
                            Button {
                                viewModel.fetchHistoricalData()
                                showingLoadingScreen = true
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.body)
                                    Text(L10n.Device.loadHistoricalData)
                                        .font(.subheadline)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.systemBackground))
                                .foregroundColor(.blue)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                                )
                            }

                            NavigationLink(destination: HistoryListView(device: viewModel.device)) {
                                HStack {
                                    Image(systemName: "list.bullet.clipboard")
                                        .font(.body)
                                    Text(L10n.History.viewAll)
                                        .font(.subheadline)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.systemBackground))
                                .foregroundColor(.blue)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                            Text(L10n.Device.noSensorMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                .padding(.horizontal)

                // Urgent watering alert
                if let prediction = wateringPrediction, prediction.isUrgent {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(.red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Watering.urgentNow)
                                .font(.headline)
                                .foregroundColor(.red)
                            Text(L10n.Watering.neededToday)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                }

                // Watering prediction card
                if let prediction = wateringPrediction {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.Watering.prediction)
                            .font(.title3)
                            .fontWeight(.semibold)

                        // Next watering date
                        HStack {
                            Image(systemName: prediction.isUrgent ? "exclamationmark.triangle.fill" : "calendar.badge.clock")
                                .font(.title2)
                                .foregroundColor(prediction.isUrgent ? .red : .blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.Watering.nextNeeded)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(prediction.predictedDate, style: .relative)
                                    .font(.headline)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text(prediction.predictedDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(.headline)
                                    .foregroundColor(prediction.isUrgent ? .red : .blue)
                                Text(prediction.predictedDate, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Prediction metrics
                        VStack(spacing: 12) {
                            HStack {
                                Label(L10n.Watering.current(Int(prediction.currentMoisture)), systemImage: "drop.circle")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Label(L10n.Watering.target(Int(prediction.targetMoisture)), systemImage: "target")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                Label(L10n.Watering.confidence(prediction.confidence), systemImage: "chart.line.uptrend.xyaxis")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Label(L10n.Watering.dryingRate(Float(prediction.dryingRatePerDay.rounded(toPlaces: 1))), systemImage: "wind")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let lastWatering = prediction.lastWateringEvent {
                                HStack {
                                    Image(systemName: "drop.fill")
                                        .foregroundColor(.blue)
                                    Text(L10n.Watering.lastWatered)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(lastWatering, style: .relative)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                    .padding(.horizontal)
                }
            
                if viewModel.device.isSensor {
                    // Sensor data section
                    VStack(alignment: .leading, spacing: 16) {
                        // Section header with controls
                        HStack {
                            Text(L10n.Sensor.data)
                                .font(.title3)
                                .fontWeight(.semibold)

                            Spacer()

                            HStack(spacing: 12) {
                                Button {
                                    Task { await viewModel.goToPreviousWeek() }
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.subheadline)
                                        .frame(width: 32, height: 32)
                                        .background(Color(.tertiarySystemGroupedBackground))
                                        .cornerRadius(8)
                                }
                                .disabled(viewModel.isLoadingSensorData)

                                VStack(spacing: 2) {
                                    Text(viewModel.currentWeekDisplayText)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Button {
                                    Task { await viewModel.goToNextWeek() }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.subheadline)
                                        .frame(width: 32, height: 32)
                                        .background(Color(.tertiarySystemGroupedBackground))
                                        .cornerRadius(8)
                                }
                                .disabled(viewModel.isLoadingSensorData)

                                Button {
                                    Task { await viewModel.refreshCurrentWeek() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.subheadline)
                                        .frame(width: 32, height: 32)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                }
                                .disabled(viewModel.isLoadingSensorData)
                            }
                        }

                        if viewModel.isLoadingSensorData {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(L10n.Sensor.loadingWeekData)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            // Charts
                            VStack(spacing: 20) {
                                SensorDataChart(isOverview: false,
                                                componet: viewModel.groupingOption,
                                                data: .constant(viewModel.currentWeekData),
                                                keyPath: \.brightness,
                                                title: L10n.Sensor.brightness,
                                                dataType: L10n.Sensor.Unit.lux,
                                                selectedChartType: .bars,
                                                minRange: Int(viewModel.device.optimalRange?.minBrightness ?? 0),
                                                maxRange: Int(viewModel.device.optimalRange?.maxBrightness ?? 0))

                                SensorDataChart(isOverview: false,
                                                componet: viewModel.groupingOption,
                                                data: .constant(viewModel.currentWeekData),
                                                keyPath: \.moisture,
                                                title: L10n.Sensor.moisture,
                                                dataType: L10n.Sensor.Unit.percent,
                                                selectedChartType: .water,
                                                minRange: Int(viewModel.device.optimalRange?.minMoisture ?? 0),
                                                maxRange: Int(viewModel.device.optimalRange?.maxMoisture ?? 0))

                                SensorDataChart(isOverview: false,
                                                componet: viewModel.groupingOption,
                                                data: .constant(viewModel.currentWeekData),
                                                keyPath: \.temperature,
                                                title: L10n.Sensor.temperature,
                                                dataType: L10n.Sensor.Unit.celsius,
                                                selectedChartType: .bars,
                                                minRange: Int(viewModel.device.optimalRange?.minTemperature ?? 0),
                                                maxRange: Int(viewModel.device.optimalRange?.maxTemperature ?? 0))
                            }
                        }

                        // Device ID section
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.Device.shortcutInfo)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text(L10n.Device.id)
                                    .font(.caption)
                                Text(viewModel.device.uuid ?? "")
                                    .font(.caption)
                                    .fontWeight(.medium)

                                Spacer()

                                Button(action: {
                                    UIPasteboard.general.string = viewModel.device.uuid
                                    showCopyAlert.toggle()
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.subheadline)
                                        .foregroundColor(.blue)
                                        .padding(8)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .alert(isPresented: $showCopyAlert) {
                                    Alert(title: Text(L10n.Alert.copied), message: Text(L10n.Clipboard.idCopied), dismissButton: .default(Text(L10n.Alert.ok)))
                                }
                            }
                            .padding()
                            .background(Color(.tertiarySystemGroupedBackground))
                            .cornerRadius(12)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                    .padding(.horizontal)
                } else {
                    // Non-sensor device
                    VStack(spacing: 20) {
                        if let potSize = viewModel.device.potSize {
                            PotView(potSize: Binding(
                                get: { viewModel.device.potSize ?? potSize },
                                set: { viewModel.device.potSize = $0 }
                            ))
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                            .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.Sensor.moisture)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .padding(.horizontal)

                            SensorDataChart(
                                isOverview: false,
                                componet: viewModel.groupingOption,
                                data: .constant(viewModel.currentWeekData),
                                keyPath: \.moisture,
                                title: L10n.Sensor.moisture,
                                dataType: "%",
                                selectedChartType: .water,
                                minRange: Int(viewModel.device.optimalRange?.minMoisture ?? 0),
                                maxRange: Int(viewModel.device.optimalRange?.maxMoisture ?? 0)
                            )
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
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
        .onChange(of: showingLoadingScreen) { isShowing in
            // Ensure cleanup when sheet is dismissed
            if !isShowing {
                // Give a brief delay to allow proper cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    FlowerCareManager.shared.forceResetHistoryState()
                }
            }
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


//
//  OverviewList.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI

struct OverviewList: View {
    @State var viewModel: OverviewListViewModel
    @State var showAddFlowerSheet = false
    @State var loading: Bool = false
    @State private var deviceToDelete: IndexSet?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var hasRequestedDashboardLiveRefresh = false

    private let settingsStore = SettingsStore.shared
    private let initialSensorDataService = InitialSensorDataService.shared

    init() {
        self.viewModel = OverviewListViewModel()
    }

    // Calculate next watering device
    var nextWateringDevice: FlowerDeviceDTO? {
        viewModel.allSavedDevices
            .filter { !$0.sensorData.isEmpty }
            .min { device1, device2 in
                guard let moisture1 = device1.sensorData.first?.moisture,
                      let moisture2 = device2.sensorData.first?.moisture else {
                    return false
                }
                return moisture1 < moisture2
            }
    }

    // Calculate average moisture
    var averageMoisture: Double {
        let devices = viewModel.allSavedDevices.filter { !$0.sensorData.isEmpty }
        guard !devices.isEmpty else { return 0 }

        let totalMoisture = devices.compactMap { $0.sensorData.first?.moisture }
            .reduce(0) { $0 + Int($1) }

        return Double(totalMoisture) / Double(devices.count) / 100.0
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Summary Cards Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Environment Overview")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.horizontal)

                    Group {
                        if let device = nextWateringDevice {
                            SummaryCard(
                                device: device,
                                averageMoisture: averageMoisture,
                                color: .blue,
                                icon: "drop.fill",
                                title: "Moisture"
                            )
                            .padding(.horizontal)
                        } else {
                            HStack {
                                Text("No plants with sensor data yet")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(20)
                            .padding(.horizontal)
                        }
                    }
                    .id(viewModel.allSavedDevices.count)

                    // Debug slider (can be removed in production)
//                    Slider(value: $progress, in: 0...1)
//                        .padding(.horizontal)
//                        .opacity(0.3)
                }
                .padding(.top, 8)

                // Debug Link
                NavigationLink(destination: LogExportView()) {
                    HStack {
                        Image(systemName: "ladybug.fill")
                        Text(L10n.Debug.menu)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                // Devices Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("My Plants")
                            .font(.title2)
                            .fontWeight(.bold)

                        Spacer()

                        EditButton()
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    if viewModel.allSavedDevices.isEmpty {
                        EmptyStateView()
                    } else {
                        List {
                            ForEach(viewModel.allSavedDevices) { device in
                                DeviceCard(device: device) {
                                    NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                            }
                            .onDelete(perform: delete)
                            .listRowSeparator(.hidden)
                        }
                        .listStyle(.plain)
                        .frame(height: CGFloat(viewModel.allSavedDevices.count) * 110)
                        .scrollDisabled(true)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.Navigation.overview)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            self.loading = true
            Task { @MainActor in
                await viewModel.fetchSavedDevices()
                self.loading = false
                await triggerDashboardLiveRefreshIfNeeded()
            }
        }
        .overlay {
            if loading {
                ProgressView()
            }
        }
        .alert(L10n.Device.delete, isPresented: $showDeleteConfirmation) {
            Button(L10n.Alert.cancel, role: .cancel) {
                deviceToDelete = nil
            }
            Button(L10n.Alert.delete, role: .destructive) {
                confirmDelete()
            }
        } message: {
            if let offsets = deviceToDelete, let index = offsets.first {
                Text(L10n.Device.deleteConfirmation(viewModel.allSavedDevices[index].name ?? "this device"))
            }
        }
        .alert(L10n.Alert.error, isPresented: $showDeleteError) {
            Button(L10n.Alert.ok) {
                viewModel.deleteError = nil
            }
        } message: {
            if let error = viewModel.deleteError {
                Text(error)
            }
        }
        .onChange(of: viewModel.deleteError) { _, newError in
            showDeleteError = newError != nil
        }
        .onDisappear {
            hasRequestedDashboardLiveRefresh = false
        }
    }
    
    func delete(at offsets: IndexSet) {
        deviceToDelete = offsets
        showDeleteConfirmation = true
    }
    
    private func confirmDelete() {
        guard let offsets = deviceToDelete else { return }
        Task {
            await viewModel.deleteDevice(at: offsets)
        }
        deviceToDelete = nil
    }

    @MainActor
    private func triggerDashboardLiveRefreshIfNeeded() async {
        guard settingsStore.useConnectionPool else {
            AppLogger.ble.info("📡 OverviewList: Skipping live refresh - ConnectionPool mode disabled")
            return
        }
        guard !hasRequestedDashboardLiveRefresh else {
            AppLogger.ble.info("📡 OverviewList: Live refresh already triggered for this appearance")
            return
        }

        let sensorUUIDs = viewModel.allSavedDevices
            .filter { $0.isSensor }
            .map { $0.uuid }

        guard !sensorUUIDs.isEmpty else {
            AppLogger.ble.info("📡 OverviewList: No sensor devices available for live refresh")
            return
        }

        hasRequestedDashboardLiveRefresh = true
        AppLogger.ble.info("📡 OverviewList: Triggering ConnectionPool live refresh for \(sensorUUIDs.count) sensor(s)")
        await initialSensorDataService.requestLiveData(for: sensorUUIDs)
    }
}

// MARK: - Supporting Views

struct SummaryCard: View {
    let device: FlowerDeviceDTO
    let averageMoisture: Double
    let color: Color
    let icon: String
    let title: String

    var currentMoisture: Double {
        guard let moisture = device.sensorData.first?.moisture else { return 0 }
        return Double(moisture) / 100.0
    }

    var daysUntilWatering: Int {
        guard let moisture = device.sensorData.first?.moisture else { return 0 }
        let optimalMoisture = Int(device.optimalRange?.minMoisture ?? 20)
        let currentLevel = Int(moisture)

        if currentLevel <= optimalMoisture {
            return 0
        }

        // Estimate: assume ~5% moisture loss per day
        let daysLeft = (currentLevel - optimalMoisture) / 5
        return max(0, daysLeft)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Text links
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text("Next Watering")
                    .font(.title3)
                    .fontWeight(.bold)

                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption2)
                    if daysUntilWatering == 0 {
                        Text("\(device.name) · water now!")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    } else {
                        Text("\(device.name) · in \(daysUntilWatering) days")
                            .font(.subheadline)
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Progress Circle rechts
            ZStack {
                // Background Circle
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 8)
                    .frame(width: 70, height: 70)

                // Progress Circle
                Circle()
                    .trim(from: 0, to: currentMoisture)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: currentMoisture)

                // Percentage Text
                Text("\(Int(currentMoisture * 100))%")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(20)
    }
}

struct DeviceCard: View {
    let device: FlowerDeviceDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Plant icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: device.isSensor ? "sensor.fill" : "leaf.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }

                // Device info
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name ?? "Unknown Plant")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(device.lastUpdate, format: .relative(presentation: .named))
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)

                    if device.isSensor {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "battery.75percent")
                                    .font(.caption2)
                                Text(device.battery, format: .percent)
                                    .font(.caption)
                            }

                            if !device.uuid.isEmpty {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text("Connected")
                                        .font(.caption)
                                }
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.circle")
                .font(.system(size: 64))
                .foregroundColor(.green.opacity(0.5))

            Text("No Plants Yet")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add your first plant to start monitoring")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

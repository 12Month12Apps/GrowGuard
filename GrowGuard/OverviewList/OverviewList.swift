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
    @State var progress: Double = 0
    @State private var deviceToDelete: IndexSet?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false

    init() {
        self.viewModel = OverviewListViewModel()
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

                    HStack(spacing: 16) {
//                        SummaryCard(
//                            value: progress,
//                            color: .orange,
//                            icon: "thermometer.variable.and.figure",
//                            title: "Temperature"
//                        )
//
//                        SummaryCard(
//                            value: progress,
//                            color: .yellow,
//                            icon: "sun.max.fill",
//                            title: "Light"
//                        )
                        
                        SummaryCard(
                            value: progress,
                            color: .blue,
                            icon: "drop.fill",
                            title: "Moisture"
                        )
                    }
                    .padding(.horizontal)

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
                        ForEach(viewModel.allSavedDevices) { device in
                            DeviceCard(device: device) {
                                NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                            }
                            .padding(.horizontal)
                        }
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
            Task {
                await viewModel.fetchSavedDevices()
                self.loading = false
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
}

// MARK: - Supporting Views

struct SummaryCard: View {
    let value: Double
    let color: Color
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 16) {
            // Text links
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text("Next Plant Watering")
                    .font(.title3)
                    .fontWeight(.bold)

                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption2)
                    Text("Monstera · 5 days left")
                        .font(.subheadline)
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
                    .trim(from: 0, to: value)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: value)

                // Percentage Text
                Text("\(Int(value * 100))%")
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

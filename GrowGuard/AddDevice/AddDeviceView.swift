//
//  AddDeviceView.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import CoreBluetooth

struct AddDeviceView: View {
    @State var viewModel: AddDeviceViewModel
    @State var loading: Bool = false

    init(/*allSavedDevices: [FlowerDeviceDTO]*/) {
        self.viewModel = AddDeviceViewModel(/*allSavedDevices: allSavedDevices*/)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Manual add section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "leaf.fill")
                            .font(.title2)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Add Plant Manually")
                                .font(.headline)
                                .fontWeight(.semibold)

                            Text("Track your plant without a sensor")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                    .onTapGesture {
                        NavigationService.shared.navigateToAddDeviceWithoutSensor()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // Available sensors section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L10n.Device.availableSensors)
                            .font(.title3)
                            .fontWeight(.bold)

                        Spacer()

                        if viewModel.loading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .padding(.horizontal)

                    // Bluetooth permission warning
                    if viewModel.bluetoothState == .unauthorized {
                        BluetoothPermissionWarning()
                            .padding(.horizontal)
                    } else if viewModel.bluetoothState == .poweredOff {
                        BluetoothPoweredOffWarning()
                            .padding(.horizontal)
                    } else if !viewModel.loading && viewModel.devices.isEmpty && viewModel.bluetoothState == .poweredOn {
                        // Empty state (only show when Bluetooth is on and working)
                        VStack(spacing: 16) {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .font(.system(size: 48))
                                .foregroundColor(.blue.opacity(0.5))

                            Text("No Sensors Found")
                                .font(.headline)

                            Text("Make sure your sensor is nearby and turned on")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .padding(.horizontal)
                    } else if viewModel.bluetoothState == .poweredOn {
                        ForEach(viewModel.devices, id: \.identifier.uuidString) { device in
                            SensorDeviceCard(
                                device: device,
                                isAlreadyAdded: viewModel.allSavedDevices.contains(where: { $0.uuid == device.identifier.uuidString })
                            ) {
                                NavigationService.shared.navigateToDeviceDetails(device: device)
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.Navigation.addDevice)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            viewModel.startScanningIfNeeded()
            Task {
                await viewModel.fetchSavedDevices()
            }
        }
        .onDisappear {
            viewModel.stopScanning()
        }
    }
}

// MARK: - Supporting Views

struct SensorDeviceCard: View {
    let device: CBPeripheral
    let isAlreadyAdded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Sensor icon
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: "sensor.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }

                // Device info
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name ?? "Unknown Sensor")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Nearby")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)

                        if isAlreadyAdded {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                Text("Added")
                                    .font(.caption)
                            }
                            .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                // Action indicator
                if isAlreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isAlreadyAdded ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Bluetooth Warning Views

struct BluetoothPermissionWarning: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Bluetooth Permission Required")
                .font(.headline)

            Text("GrowGuard needs Bluetooth access to discover and connect to your plant sensors. Please enable Bluetooth permission in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Settings")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

struct BluetoothPoweredOffWarning: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundColor(.red.opacity(0.7))

            Text("Bluetooth is Off")
                .font(.headline)

            Text("Please turn on Bluetooth to scan for plant sensors")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: "App-Prefs:Bluetooth") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Settings")
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.8))
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color.red.opacity(0.1))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}

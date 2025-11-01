//
//  AddDeviceDetails.swift
//  GrowGuard
//
//  Created by veitprogl on 22.03.25.
//

import SwiftUI
import CoreBluetooth
import SwiftData

import SwiftUI
import CoreBluetooth
import CoreData

// Defines all possible navigation destinations in the app
enum NavigationDestination: Hashable {
    case deviceDetails(CBPeripheral)
    case deviceDetailsSpecies(VMSpecies)
    case deviceList
    case addDeviceWithoutSensor
    case home
    case deviceView(FlowerDeviceDTO) // Add this new case
}

@Observable class NavigationService {
    static let shared = NavigationService()
    
    var path = NavigationPath()
    var selectedTab: NavigationTabs = .overview
    
    private init() {}
    
    // Navigation destination methods
    func navigateToDeviceDetails(device: CBPeripheral) {
        path.append(NavigationDestination.deviceDetails(device))
    }
    
    func navigateToDeviceDetails(flower: VMSpecies) {
        path.append(NavigationDestination.deviceDetailsSpecies(flower))
    }
    
    func navigateToAddDeviceWithoutSensor() {
        path.append(NavigationDestination.addDeviceWithoutSensor)
    }
    
    func popToRoot() {
        path = NavigationPath()
    }
    
    func navigateToDeviceView(flowerDevice: FlowerDeviceDTO) {
        // Ensure we start from a clean stack so we don't push multiple detail views at once
        popToRoot()
        path.append(NavigationDestination.deviceView(flowerDevice))
    }
    
    // Tab selection methods
    func switchToTab(_ tab: NavigationTabs) {
        popToRoot()
        selectedTab = tab
    }
}

@Observable class AddDeviceDetailsViewModel {
    var device:  CBPeripheral?
    var allSavedDevices: [FlowerDeviceDTO] = []
    var alertView: Alert = .empty
    var showAlert = false
    var flower: FlowerDeviceDTO
    private let repositoryManager = RepositoryManager.shared
    var searchedFlower: VMSpecies? {
        didSet {
            guard let searched = searchedFlower else { return }
            
            // Create updated optimal range
            let optimalRange = OptimalRangeDTO(
                minMoisture: Int16(searched.minMoisture ?? 0),
                maxMoisture: Int16(searched.maxMoisture ?? 100),
                deviceUUID: flower.uuid
            )
            
            // Update flower with new data
            flower = FlowerDeviceDTO(
                id: flower.id,
                name: searched.name,
                uuid: flower.uuid,
                peripheralID: flower.peripheralID,
                battery: flower.battery,
                firmware: flower.firmware,
                isSensor: flower.isSensor,
                added: flower.added,
                lastUpdate: flower.lastUpdate,
                optimalRange: optimalRange,
                potSize: flower.potSize,
                selectedFlower: searched, // Set the searched flower as selectedFlower
                sensorData: flower.sensorData
            )
        }
    }

    init(device: CBPeripheral) {
        self.device = device
        self.flower = FlowerDeviceDTO(
            name: device.name ?? L10n.Device.unknownDevice,
            uuid: device.identifier.uuidString,
            peripheralID: device.identifier,
            isSensor: true,
            added: Date(),
            lastUpdate: Date()
        )

        Task {
            await fetchSavedDevices()
        }
    }
    
    init(flower: VMSpecies) {
        let optimalRange = OptimalRangeDTO(
            minMoisture: Int16(flower.minMoisture ?? 0),
            maxMoisture: Int16(flower.maxMoisture ?? 100),
            deviceUUID: UUID().uuidString
        )
        
        self.flower = FlowerDeviceDTO(
            name: flower.name,
            uuid: optimalRange.deviceUUID,
            isSensor: false,
            added: Date(),
            lastUpdate: Date(),
            optimalRange: optimalRange,
            selectedFlower: flower
        )
    }
    
    @MainActor
    func save() async {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == self.device?.identifier.uuidString
        })
        if isSaved {
            self.alertView = Alert(title: Text(L10n.Alert.info),
                                   message: Text(L10n.Device.Error.alreadyAdded))
            self.showAlert = true
        } else {
            if allSavedDevices.contains(where: { device in
                device.name == self.flower.name
            }) {
                self.alertView = Alert(title: Text(L10n.Alert.info),
                                       message: Text(L10n.Device.Error.nameExists))
                self.showAlert = true
                return
            }
            
            do {
                try await repositoryManager.flowerDeviceRepository.saveDevice(flower)
                
                // Save optimal range if it exists
                if let optimalRange = flower.optimalRange {
                    try await repositoryManager.optimalRangeRepository.saveOptimalRange(optimalRange)
                }
                
            } catch {
                self.alertView = Alert(title: Text(L10n.Alert.error), message: Text(error.localizedDescription))
                self.showAlert = true
                return
            }
        }
        NavigationService.shared.switchToTab(.overview)
        
        NavigationService.shared.navigateToDeviceView(flowerDevice: flower)
    }
    
    @MainActor
    func fetchSavedDevices() async {
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
        } catch {
            print("Error fetching devices: \(error.localizedDescription)")
        }
    }
}

struct AddDeviceDetails:  View {
    init(viewModel: AddDeviceDetailsViewModel) {
        self.viewModel = viewModel
    }
    
    @State var viewModel: AddDeviceDetailsViewModel

    var calculatedVolume: Double? {
        guard viewModel.flower.potSize?.width ?? 0 > 0, viewModel.flower.potSize?.height ?? 0 > 0 else { return nil }
        guard let radius = viewModel.flower.potSize?.width else { return nil }
        return Double.pi * pow(radius, 2) * (viewModel.flower.potSize?.height ?? 0)
    }
    
    var body: some View {
        VStack {
            Form {
                Section(header: Text("Plant Selection")) {
                    NavigationLink {
                        AddWithoutSensor(flower: $viewModel.searchedFlower, searchMode: true)
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.blue)
                            Text(L10n.Device.searchFlower)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let selectedFlower = viewModel.searchedFlower {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.15))
                                    .frame(width: 50, height: 50)

                                Image(systemName: "leaf.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedFlower.name)
                                    .font(.headline)

                                if let minMoisture = selectedFlower.minMoisture,
                                   let maxMoisture = selectedFlower.maxMoisture {
                                    Text("Moisture: \(minMoisture)% - \(maxMoisture)%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Device Name")) {
                    HStack {
                        Image(systemName: "textformat")
                            .foregroundColor(.blue)
                            .frame(width: 30)
                        TextField(L10n.Device.name, text: Binding(
                            get: { viewModel.flower.name ?? "" },
                            set: { viewModel.flower.name = $0 }
                        ))
                    }
                }

                Section(header: Text("Pot Size")) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "arrow.left.and.right")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            Text(L10n.Pot.radius)
                            Spacer()
                            TextField("0", value: Binding(
                                get: { viewModel.flower.potSize?.width ?? 0},
                                set: { viewModel.flower.potSize?.width = $0 }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }

                        HStack {
                            Image(systemName: "arrow.up.and.down")
                                .foregroundColor(.blue)
                                .frame(width: 30)
                            Text(L10n.Pot.height)
                            Spacer()
                            TextField("0", value: Binding(
                                get: { viewModel.flower.potSize?.height ?? 0},
                                set: { viewModel.flower.potSize?.height = $0 }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "cube")
                                    .foregroundColor(.blue)
                                    .frame(width: 30)
                                Text(L10n.Pot.volume)
                                Spacer()
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.potSize?.volume ?? 0},
                                    set: { viewModel.flower.potSize?.volume = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }

                            if let calculated = calculatedVolume {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Calculated: \(String(format: "%.1f", calculated)) cm³")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Button {
                                        viewModel.flower.potSize?.volume = calculated
                                    } label: {
                                        HStack {
                                            Image(systemName: "checkmark.circle")
                                            Text(L10n.Pot.acceptCalculation)
                                        }
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    }
                                }
                                .padding(.leading, 30)
                            }
                        }
                    }
                }

                Section(header: Text("Optimal Ranges")) {
                    if let selectedFlower = viewModel.searchedFlower,
                       selectedFlower.minMoisture != nil || selectedFlower.maxMoisture != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Values from \(selectedFlower.name)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 4)
                    }

                    VStack(spacing: 16) {
                        // Moisture
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.Sensor.moisture, systemImage: "drop.fill")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)

                            HStack {
                                Text("Min")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.minMoisture ?? 0 },
                                    set: { viewModel.flower.optimalRange?.minMoisture = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("%")
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("Max")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.maxMoisture ?? 0 },
                                    set: { viewModel.flower.optimalRange?.maxMoisture = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("%")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Temperature
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.Sensor.temperature, systemImage: "thermometer")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)

                            HStack {
                                Text("Min")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.minTemperature ?? 0 },
                                    set: { viewModel.flower.optimalRange?.minTemperature = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("°C")
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("Max")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.maxTemperature ?? 0 },
                                    set: { viewModel.flower.optimalRange?.maxTemperature = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("°C")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Brightness
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.Sensor.brightness, systemImage: "sun.max.fill")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.yellow)

                            HStack {
                                Text("Min")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.minBrightness ?? 0 },
                                    set: { viewModel.flower.optimalRange?.minBrightness = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("lux")
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("Max")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.maxBrightness ?? 0 },
                                    set: { viewModel.flower.optimalRange?.maxBrightness = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("lux")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Conductivity
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.Sensor.conductivity, systemImage: "bolt.fill")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.green)

                            HStack {
                                Text("Min")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.minConductivity ?? 0 },
                                    set: { viewModel.flower.optimalRange?.minConductivity = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("µS/cm")
                                    .foregroundColor(.secondary)
                                    .font(.caption)

                                Spacer()

                                Text("Max")
                                    .frame(width: 50, alignment: .leading)
                                TextField("0", value: Binding(
                                    get: { viewModel.flower.optimalRange?.maxConductivity ?? 0 },
                                    set: { viewModel.flower.optimalRange?.maxConductivity = $0 }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("µS/cm")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            await viewModel.save()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                            Text(L10n.Alert.save)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L10n.Navigation.addDeviceDetails)
        }.alert(isPresented: $viewModel.showAlert, content: { viewModel.alertView })
    }
}

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
    
    func navigateToDeviceList() {
        path.append(NavigationDestination.deviceList)
    }
    
    func navigateToAddDeviceWithoutSensor() {
        path.append(NavigationDestination.addDeviceWithoutSensor)
    }
    
    func navigateToHome() {
        path.append(NavigationDestination.home)
    }
    
    func popToRoot() {
        path = NavigationPath()
    }
    
    func pop() {
        if !path.isEmpty {
            path.removeLast()
        }
    }
    
    func navigateToDeviceView(flowerDevice: FlowerDeviceDTO) {
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
                
                NavigationLink {
                    AddWithoutSensor(flower: $viewModel.searchedFlower, searchMode: true)
                } label: {
                    Text(L10n.Device.searchFlower)
                }
                
                Section {
                    TextField(L10n.Device.name, text: Binding(
                        get: { viewModel.flower.name ?? "" },
                        set: { viewModel.flower.name = $0 }
                    ))
                }
                
                Section(header: Text(L10n.Pot.section)) {
                    HStack {
                        Text(L10n.Pot.radius)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.potSize?.width ?? 0},
                            set: { viewModel.flower.potSize?.width = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text(L10n.Pot.height)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.potSize?.height ?? 0},
                            set: { viewModel.flower.potSize?.height = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    VStack {
                        Text(L10n.Pot.volumeDescription)
                            .font(.caption)
                        HStack {
                            Text(L10n.Pot.volume)
                            TextField("0", value: Binding(
                                get: { viewModel.flower.potSize?.volume ?? 0},
                                set: { viewModel.flower.potSize?.volume = $0 }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                        }
                        if let calculated = calculatedVolume {
                            Text(L10n.Pot.calculatedVolume(Float(calculated)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                viewModel.flower.potSize?.volume = calculated
                            } label: {
                                Text(L10n.Pot.acceptCalculation)
                            }

                        }
                    }
                }
                
                Section(header: Text(L10n.Sensor.brightness)) {
                    HStack {
                        Text(L10n.Sensor.minBrightness)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minBrightness ?? 0 },
                            set: { viewModel.flower.optimalRange?.minBrightness = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text(L10n.Sensor.maxBrightness)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxBrightness ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxBrightness = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text(L10n.Sensor.temperature)) {
                    HStack {
                        Text(L10n.Sensor.minTemperature)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minTemperature ?? 0 },
                            set: { viewModel.flower.optimalRange?.minTemperature = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text(L10n.Sensor.maxTemperature)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxTemperature ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxTemperature = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                
                Section(header: Text(L10n.Sensor.moisture)) {
                    HStack {
                        Text(L10n.Sensor.minMoisture)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minMoisture ?? 0 },
                            set: { viewModel.flower.optimalRange?.minMoisture = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text(L10n.Sensor.maxMoisture)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxMoisture ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxMoisture = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text(L10n.Sensor.conductivity)) {
                    HStack {
                        Text(L10n.Sensor.minConductivity)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minConductivity ?? 0 },
                            set: { viewModel.flower.optimalRange?.minConductivity = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text(L10n.Sensor.maxConductivity)
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxConductivity ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxConductivity = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                Button {
                    Task {
                        await viewModel.save()
                    }
                } label: {
                    Text(L10n.Alert.save)
                }
                .buttonStyle(BorderedButtonStyle())

            }
            .navigationTitle(L10n.Navigation.addDeviceDetails)
        }.alert(isPresented: $viewModel.showAlert, content: { viewModel.alertView })
    }
}


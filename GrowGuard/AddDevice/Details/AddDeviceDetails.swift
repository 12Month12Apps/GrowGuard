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
    case deviceView(FlowerDevice) // Add this new case
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
    
    func navigateToDeviceView(flowerDevice: FlowerDevice) {
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
    var allSavedDevices: [FlowerDevice] = []
    var alertView: Alert = .empty
    var showAlert = false
    var flower: FlowerDevice
    var searchedFlower: VMSpecies? {
        didSet {
            guard let searched = searchedFlower else { return }

            flower.name = searched.name
            if let minMoisture = searched.minMoisture {
                flower.optimalRange?.minMoisture = Int16(minMoisture)
            }
            if let maxMoisture = searched.maxMoisture {
                flower.optimalRange?.maxMoisture = Int16(maxMoisture)
            }
        }
    }

    init(device: CBPeripheral) {
        self.device = device
        self.flower = FlowerDevice(context: DataService.shared.context)

        
        self.flower.added = Date()
        self.flower.lastUpdate = Date()
        self.flower.peripheralID = device.identifier
        
        self.flower.isSensor = true

        Task {
            await fetchSavedDevices()
        }
    }
    
    init(flower: VMSpecies) {
        self.flower = FlowerDevice(context: DataService.shared.context)
        self.flower.name = flower.name
        self.flower.uuid = UUID().uuidString
        self.flower.isSensor = false
        self.flower.optimalRange = OptimalRange(context: DataService.shared.context)
        self.flower.optimalRange?.minTemperature = 0
        self.flower.optimalRange?.minBrightness = 0
        self.flower.optimalRange?.minMoisture = Int16(flower.minMoisture ?? 0)
        self.flower.optimalRange?.minConductivity = 0
        self.flower.optimalRange?.maxTemperature = 0
        self.flower.optimalRange?.maxBrightness = 0
        self.flower.optimalRange?.maxMoisture = Int16(flower.maxMoisture ?? 0)
        self.flower.optimalRange?.maxConductivity = 0
    }
    
    @MainActor
    func save() {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == self.device?.identifier.uuidString
        })
        if isSaved {
            self.alertView = Alert(title: Text("Info"),
                                   message: Text("The Device is already added!"))
            self.showAlert = true
        } else {
            DataService.shared.context.insert(flower)
            
            if allSavedDevices.contains(where: { device in
                device.name == self.flower.name
            }) {
                self.alertView = Alert(title: Text("Info"),
                                       message: Text("The Device name already exists, please pick an unquie one"))
                self.showAlert = true
            }
            
            do {
                try DataService.shared.context.save()
            } catch {
                self.alertView = Alert(title: Text("Error"), message: Text(error.localizedDescription))
                self.showAlert = true
            }
        }
        NavigationService.shared.switchToTab(.overview)
        
        if let device = device {
            NavigationService.shared.navigateToDeviceDetails(device: device)
        }
    }
    
    @MainActor
    func fetchSavedDevices() {
        let request = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        
        do {
            let result = try DataService.shared.context.fetch(request)
            allSavedDevices = result
        } catch{
            print(error.localizedDescription)
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
                    Text("Search Flower")
                }
                
                Section {
                    TextField("Device Name", text: Binding(
                        get: { viewModel.flower.name ?? "" },
                        set: { viewModel.flower.name = $0 }
                    ))
                }
                
                Section(header: Text("Flower Pot")) {
                    HStack {
                        Text("Pot radius (cm)")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.potSize?.width ?? 0},
                            set: { viewModel.flower.potSize?.width = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Pot height (cm)")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.potSize?.height ?? 0},
                            set: { viewModel.flower.potSize?.height = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    VStack {
                        Text("Volume can be automaticily be calculated, but if you know yours please enter it here to be more precise")
                            .font(.caption)
                        HStack {
                            Text("Pot volume")
                            TextField("0", value: Binding(
                                get: { viewModel.flower.potSize?.volume ?? 0},
                                set: { viewModel.flower.potSize?.volume = $0 }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                        }
                        if let calculated = calculatedVolume {
                            Text("Automatisch berechnetes Volumen: \(String(format: "%.1f", calculated)) cm³")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                viewModel.flower.potSize?.volume = calculated
                            } label: {
                                Text("Accpet calculation")
                            }

                        }
                    }
                }
                
                Section(header: Text("Brigtness")) {
                    HStack {
                        Text("Min Brigtness")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minBrightness ?? 0 },
                            set: { viewModel.flower.optimalRange?.minBrightness = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Brigtness")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxBrightness ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxBrightness = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text("Temperature")) {
                    HStack {
                        Text("Min Temperature")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minTemperature ?? 0 },
                            set: { viewModel.flower.optimalRange?.minTemperature = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Temperature")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxTemperature ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxTemperature = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                
                Section(header: Text("Moisture")) {
                    HStack {
                        Text("Min Moisture")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minMoisture ?? 0 },
                            set: { viewModel.flower.optimalRange?.minMoisture = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Moisture")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxMoisture ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxMoisture = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text("Conductivity")) {
                    HStack {
                        Text("Min Conductivity")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.minConductivity ?? 0 },
                            set: { viewModel.flower.optimalRange?.minConductivity = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Conductivity")
                        TextField("0", value: Binding(
                            get: { viewModel.flower.optimalRange?.maxConductivity ?? 0 },
                            set: { viewModel.flower.optimalRange?.maxConductivity = $0 }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                Button {
                    viewModel.save()
                } label: {
                    Text("Save")
                }
                .buttonStyle(BorderedButtonStyle())

            }
            .navigationTitle("Add Device Details")
        }.alert(isPresented: $viewModel.showAlert, content: { viewModel.alertView })
    }
}


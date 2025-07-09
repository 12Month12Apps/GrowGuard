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
                flower.optimalRange.minMoisture = UInt8(minMoisture)
            }
            if let maxMoisture = searched.maxMoisture {
                flower.optimalRange.maxMoisture = UInt8(maxMoisture)
            }
        }
    }

    init(device: CBPeripheral) {
        self.device = device
        self.flower = FlowerDevice(added: Date(), lastUpdate: Date(), peripheral: device)
        self.flower.isSensor = true

        Task {
            await fetchSavedDevices()
        }
    }
    
    init(flower: VMSpecies) {
        self.flower = FlowerDevice(name: flower.name, uuid: UUID().uuidString)
        self.flower.isSensor = false
        self.flower.optimalRange = OptimalRange(minTemperature: 0, minBrightness: 0, minMoisture: UInt8(flower.minMoisture ?? 0), minConductivity: 0, maxTemperature: 0, maxBrightness: 0, maxMoisture: UInt8(flower.maxMoisture ?? 0), maxConductivity: 0)
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
            DataService.sharedModelContainer.mainContext.insert(flower)
            
            if allSavedDevices.contains(where: { device in
                device.name == self.flower.name
            }) {
                self.alertView = Alert(title: Text("Info"),
                                       message: Text("The Device name already exists, please pick an unquie one"))
                self.showAlert = true
            }
            
            do {
                try DataService.sharedModelContainer.mainContext.save()
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
        let fetchDescriptor = FetchDescriptor<FlowerDevice>()

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
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

//    var calculatedVolume: Double? {
//        guard viewModel.flower.potSize.width > 0, viewModel.flower.potSize.height > 0 else { return nil }
//        let radius = viewModel.flower.potSize.width
//        return Double.pi * pow(radius, 2) * viewModel.flower.potSize.height
//    }
    
    var body: some View {
        VStack {
            Form {
                
                NavigationLink {
                    AddWithoutSensor(flower: $viewModel.searchedFlower, searchMode: true)
                } label: {
                    Text("Search Flower")
                }
                
                Section {
                    TextField("Device Name", text: $viewModel.flower.name)
                }
                
//                Section(header: Text("Flower Pot")) {
//                    HStack {
//                        Text("Pot radius (cm)")
//                        TextField("0", value: $viewModel.flower.potSize.width, format: .number)
//                            .keyboardType(.decimalPad)
//                    }
//                    
//                    HStack {
//                        Text("Pot height (cm)")
//                        TextField("0", value: $viewModel.flower.potSize.height, format: .number)
//                            .keyboardType(.decimalPad)
//                    }
//                    
//                    VStack {
//                        Text("Volume can be automaticily be calculated, but if you know yours please enter it here to be more precise")
//                            .font(.caption)
//                        HStack {
//                            Text("Pot volume")
//                            TextField("0", value: $viewModel.flower.potSize.volume, format: .number)
//                                .keyboardType(.decimalPad)
//                        }
//                        if let calculated = calculatedVolume {
//                            Text("Automatisch berechnetes Volumen: \(String(format: "%.1f", calculated)) cm³")
//                                .font(.caption)
//                                .foregroundColor(.secondary)
//                            Button {
//                                viewModel.flower.potSize.volume = calculated
//                            } label: {
//                                Text("Accpet calculation")
//                            }
//
//                        }
//                    }
//                }
                
                Section(header: Text("Brigtness")) {
                    HStack {
                        Text("Min Brigtness")
                        TextField("0", value: $viewModel.flower.optimalRange.minBrightness, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Brigtness")
                        TextField("0", value: $viewModel.flower.optimalRange.maxBrightness, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text("Temperature")) {
                    HStack {
                        Text("Min Temperature")
                        TextField("0", value: $viewModel.flower.optimalRange.minTemperature, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Temperature")
                        TextField("0", value: $viewModel.flower.optimalRange.maxTemperature, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                
                Section(header: Text("Moisture")) {
                    HStack {
                        Text("Min Moisture")
                        TextField("0", value: $viewModel.flower.optimalRange.minMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Moisture")
                        TextField("0", value: $viewModel.flower.optimalRange.maxMoisture, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }

                Section(header: Text("Conductivity")) {
                    HStack {
                        Text("Min Conductivity")
                        TextField("0", value: $viewModel.flower.optimalRange.minConductivity, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    
                    HStack {
                        Text("Max Conductivity")
                        TextField("0", value: $viewModel.flower.optimalRange.maxConductivity, format: .number)
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


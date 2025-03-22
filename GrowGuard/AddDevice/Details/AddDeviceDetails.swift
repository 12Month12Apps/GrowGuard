//
//  AddDeviceDetails.swift
//  GrowGuard
//
//  Created by veitprogl on 22.03.25.
//

import SwiftUI
import CoreBluetooth
import SwiftData

@Observable class AddDeviceDetailsViewModel {
    var device:  CBPeripheral
    var allSavedDevices: [FlowerDevice] = []
    var alertView: Alert = .empty
    var showAlert = false
    var flower: FlowerDevice

    init(device: CBPeripheral) {
        self.device = device
        self.flower = FlowerDevice(added: Date(), lastUpdate: Date(), peripheral: device)
        
        Task {
            await fetchSavedDevices()
        }
    }
    
    @MainActor
    func save() {
        let isSaved = allSavedDevices.contains(where: { device in
            device.uuid == self.device.identifier.uuidString
        })
        if isSaved {
            self.alertView = Alert(title: Text("Info"),
                                   message: Text("The Device is already added!"))
            self.showAlert = true
        } else {
            DataService.sharedModelContainer.mainContext.insert(flower)
            
            if allSavedDevices.contains(where: { device in
                device.name == self.device.name
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
    
    var body: some View {
        VStack {
            Form {
                Section {
                    TextField("Device Name", text: $viewModel.flower.name)
                }
                
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

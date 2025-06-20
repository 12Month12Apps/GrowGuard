//
//  AddDeviceView.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI

struct AddDeviceView: View {
    @State var viewModel: AddDeviceViewModel
    @State var loading: Bool = false

    init(/*allSavedDevices: [FlowerDevice]*/) {
        self.viewModel = AddDeviceViewModel(/*allSavedDevices: allSavedDevices*/)
    }

    var body: some View {
        VStack {
            List() {
                
                Section() {
                    Button {
                        NavigationService.shared.navigateToAddDeviceWithoutSensor()
                    } label: {
                        Text("Add without Sensor")
                    }
                }
                
                Section(header: Text("Available Sensors")) {
                    if viewModel.loading {
                        ProgressView().foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(viewModel.devices, id: \.identifier.uuidString) { device in
                        Button {
                            NavigationService.shared.navigateToDeviceDetails(device: device)
                        } label: {
                            HStack {
                                Text(device.name ?? "error")
                                Spacer()
                                if viewModel.allSavedDevices.contains(where: { savedDevice in
                                    savedDevice.uuid == device.identifier.uuidString
                                }) {
                                    Image(systemName: "checkmark").foregroundColor(.green)
                                } else {
                                    Image(systemName: "info.circle")
                                }
                            }
                        }
                        .navigationLinkStyle()
                        .contentShape(Rectangle())
                    }
                }
            }
        }.onAppear {
            Task {
                viewModel.fetchSavedDevices()
            }
        }
        .navigationTitle("Add Device")
    }
}

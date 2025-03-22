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
        NavigationView {
            List(viewModel.devices, id: \.identifier.uuidString) { device in
                NavigationLink {
                    AddDeviceDetails(viewModel: AddDeviceDetailsViewModel(device: device))
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
                
                
            }.onAppear {
                Task {
                    viewModel.fetchSavedDevices()
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                }
            }
            .navigationTitle("Add Device")
        }
    }
}

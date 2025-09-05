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

    init(/*allSavedDevices: [FlowerDeviceDTO]*/) {
        self.viewModel = AddDeviceViewModel(/*allSavedDevices: allSavedDevices*/)
    }

    var body: some View {
        VStack {
            List() {
                
                Section() {
                    Button {
                        NavigationService.shared.navigateToAddDeviceWithoutSensor()
                    } label: {
                        Text(L10n.Device.addWithoutSensor)
                    }
                }
                
                Section(header: Text(L10n.Device.availableSensors)) {
                    if viewModel.loading {
                        ProgressView().foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(viewModel.devices, id: \.identifier.uuidString) { device in
                        Button {
                            NavigationService.shared.navigateToDeviceDetails(device: device)
                        } label: {
                            HStack {
                                Text(device.name ?? L10n.Common.error)
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
                await viewModel.fetchSavedDevices()
            }
        }
        .navigationTitle(L10n.Navigation.addDevice)
    }
}

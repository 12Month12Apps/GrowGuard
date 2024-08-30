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
        List(viewModel.devices, id: \.name) { device in
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
            .onTapGesture {
                viewModel.tapOnDevice(peripheral: device)
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
    }
}

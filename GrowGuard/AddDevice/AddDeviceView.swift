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

    init(allSavedDevices: [FlowerDevice]) {
        self.viewModel = AddDeviceViewModel(allSavedDevices: allSavedDevices)
    }

    var body: some View {
        List(viewModel.devices, id: \.name) { device in
            HStack {
                Text(device.name ?? "error")
                Spacer()
                Image(systemName: "info.circle")
            }
            .onTapGesture {
                viewModel.tapOnDevice(peripheral: device)
            }
            .background {
                if viewModel.allSavedDevices.contains(where: { saved in
                    device.identifier.uuidString == saved.uuid
                }) {
                    Color.red
                }
            }
        }.onAppear {

        }
    }
}

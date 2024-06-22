//
//  DeviceDetailsView.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import Foundation
import SwiftUI

struct DeviceDetailsView: View {
    var viewModel: DeviceDetailsViewModel
    
    init(device: FlowerDevice) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        VStack {
            Text(viewModel.device.name ?? "")
            .font(.headline)
            Text("Added: ") + Text(viewModel.device.added, format: .dateTime)
            Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
            
            Button("Delete") {
                print("deleted me :(")
            }.buttonStyle(BorderedProminentButtonStyle())
            
            
            Text(String(viewModel.sensorData?.moisture ?? 0))
            Text(String(viewModel.sensorData?.temperature ?? 0))
            Text(String(viewModel.sensorData?.brightness ?? 0))

        }.onAppear {
            self.viewModel.loadDetails()
        }
    }
}

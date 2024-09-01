//
//  DeviceDetailsView.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import SwiftUI

struct DeviceDetailsView: View {
    @State var viewModel: DeviceDetailsViewModel

    init(device: FlowerDevice) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        List {
            TextField("Device Name", text: $viewModel.device.name)
            Text("Added: ") + Text(viewModel.device.added, format: .dateTime)
            Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.brightness,
                            title: "Brightness",
                            dataType: "lux",
                            selectedChartType: .bars)
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.moisture,
                            title: "Moisture",
                            dataType: "%",
                            selectedChartType: .water)
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData,
                            keyPath: \.temperature,
                            title: "Temperature",
                            dataType: "C",
                            selectedChartType: .bars)
            
            Button {
                viewModel.delete()
            } label: {
                Text("Delete")
            }

        }.onAppear {
            self.viewModel.loadDetails()
        }
        .navigationTitle(viewModel.device.name)
    }
}



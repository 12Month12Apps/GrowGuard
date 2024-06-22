//
//  OverviewList.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI

struct OverviewList: View {
    @State var viewModel: OverviewListViewModel
    
    init(allSavedDevices: [FlowerDevice]) {
        self.viewModel = OverviewListViewModel(allSavedDevices: allSavedDevices)
    }
    
    var body: some View {
        NavigationView {
            VStack {
                List(viewModel.allSavedDevices) { device in
                    NavigationLink(destination: DeviceDetailsView(device: device)) {
                        Text(device.name ?? "error")
                        Text(device.lastUpdate, format: .dateTime)
                    }
                }
            }.navigationTitle("Overview")
        }
    }
}

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
    @State var showAddFlowerSheet = false
    @State var loading: Bool = false

    init() {
        self.viewModel = OverviewListViewModel()
    }
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(viewModel.allSavedDevices) { device in
                        NavigationLink(destination: DeviceDetailsView(device: device)) {
                            Text(device.name ?? "error")
                            Text(device.lastUpdate, format: .dateTime)
                        }
                    }
                    .onDelete(perform: delete)
                }
                Button("Add Flower") {
                    self.showAddFlowerSheet.toggle()
                }
            }.navigationTitle("Overview")
        }
        .sheet(isPresented: self.$showAddFlowerSheet) {
            VStack {
                Button("Close") {
                    self.showAddFlowerSheet.toggle()
                }               
                
                AddDeviceView(/*allSavedDevices: viewModel.allSavedDevices*/)
            }
        }
        .onAppear {
            self.loading = true
            Task {
                viewModel.fetchSavedDevices()
                self.loading = false
            }
        }
        .overlay {
            if loading {
                ProgressView()
            }
        }
    }
    
    func delete(at offsets: IndexSet) {
        let model = viewModel.allSavedDevices[offsets.first!]
        viewModel.allSavedDevices.remove(atOffsets: offsets)
        
        DataService.sharedModelContainer.mainContext.delete(model)
        
        do {
            try DataService.sharedModelContainer.mainContext.save()
        } catch {
            
        }
    }
}

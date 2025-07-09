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
    @State var progress: Double = 0

    init() {
        self.viewModel = OverviewListViewModel()
    }
    
    var body: some View {
        VStack {
            List {
                Section {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CircularProgressView(progress: progress, color: .red, icon: Image(systemName: "thermometer.variable"))
                                .frame(width: 80, height: 80)
                            Spacer()
                            CircularProgressView(progress: progress, color: .green, icon: Image(systemName: "sun.max"))
                                .frame(width: 80, height: 80)
                            Spacer()
                            CircularProgressView(progress: progress, color: .blue, icon: Image(systemName: "drop.fill"))
                               .frame(width: 80, height: 80)
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Slider(value: $progress, in: 0...1)
                        }
                    }
                }
                
                Section {
                    ForEach(viewModel.allSavedDevices) { device in
                        Button {
                            // Add a new method to NavigationService
                            NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                        } label: {
                            Text(device.name ?? "")
                            if let lastUpdate = device.lastUpdate {
                                Text(lastUpdate, format: .dateTime)
                            }
                        }
                        .navigationLinkStyle()
                        .contentShape(Rectangle())
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            EditButton()
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
        
        DataService.shared.context.delete(model)
        
        do {
            try DataService.shared.context.save()
        } catch {
            
        }
    }
}

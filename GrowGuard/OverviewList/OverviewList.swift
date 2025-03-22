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
        VStack {
            List {
                ForEach(viewModel.allSavedDevices) { device in
                    Button {
                        // Add a new method to NavigationService
                        NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                    } label: {
                        Text(device.name ?? "error")
                        Text(device.lastUpdate, format: .dateTime)
                    }
                    .navigationLinkStyle()
                    .contentShape(Rectangle())
                }
                .onDelete(perform: delete)
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
        
        DataService.sharedModelContainer.mainContext.delete(model)
        
        do {
            try DataService.sharedModelContainer.mainContext.save()
        } catch {
            
        }
    }
}

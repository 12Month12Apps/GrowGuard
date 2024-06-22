//
//  ContentView.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI
import SwiftData

class ContentViewModel: Observable {
    var allSavedDevices: [FlowerDevice] = []

    @MainActor
    func fetchSavedDevices() {
        let fetchDescriptor = FetchDescriptor<FlowerDevice>()

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
            allSavedDevices = result
        } catch{
            print(error.localizedDescription)
        }
    }
}


struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State var viewModel = ContentViewModel()
    
    var body: some View {
        VStack {
            if viewModel.allSavedDevices.count == 0 {
                AddDeviceView(allSavedDevices: viewModel.allSavedDevices)
            } else {
                OverviewList(allSavedDevices: viewModel.allSavedDevices)
            }
        }.onAppear {
            viewModel.fetchSavedDevices()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FlowerDevice.self, inMemory: true)
}

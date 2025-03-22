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

    init(allSavedDevices: [FlowerDevice] = []) {
        self.allSavedDevices = allSavedDevices
        
//        Task {
//            await self.fetchSavedDevices()
//        }
    }
    
//    @MainActor
//    func fetchSavedDevices() {
//        let fetchDescriptor = FetchDescriptor<FlowerDevice>()
//
//        do {
//            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
//            allSavedDevices = result
//            
//        } catch{
//            print(error.localizedDescription)
//        }
//    }
}

enum NavigationTabs {
    case overview
    case addDevice
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State var viewModel = ContentViewModel()
    @State var showOnboarding = true
    @State var selectedTab : NavigationTabs = .overview

    var body: some View {
        VStack {
            if showOnboarding {
                OnbordingView(selectedTab: $selectedTab, showOnboarding: $showOnboarding)
            } else {
                TabView(selection: $selectedTab) {
                    Tab("Menu", systemImage: "leaf", value: .overview) {
                        OverviewList(/*allSavedDevices: viewModel.allSavedDevices*/)
                    }
                    
                    Tab("Add", systemImage: "plus.app", value: .addDevice) {
                        AddDeviceView(/*allSavedDevices: */)
                    }
                }
            }
        }.onAppear {
            let defaults = UserDefaults.standard
            showOnboarding = !defaults.bool(forKey: UserDefaultsKeys.showOnboarding.rawValue)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FlowerDevice.self, inMemory: true)
}

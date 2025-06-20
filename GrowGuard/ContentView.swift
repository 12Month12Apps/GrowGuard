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
    @State private var navigationService = NavigationService.shared

    var body: some View {
        VStack {
            if showOnboarding {
                OnbordingView(selectedTab: $navigationService.selectedTab, showOnboarding: $showOnboarding)
            } else {
                TabView(selection: $navigationService.selectedTab) {
                    Tab("Menu", systemImage: "leaf", value: .overview) {
                        OverviewList()
                    }
                    
                    Tab("Add", systemImage: "plus.app", value: .addDevice) {
                        AddDeviceView()
                    }
                }
            }
        }.onAppear {
            let defaults = UserDefaults.standard
            showOnboarding = !defaults.bool(forKey: UserDefaultsKeys.showOnboarding.rawValue)
        }
    }
}

import SwiftUI

struct MainNavigationView: View {
    @State private var navigationService = NavigationService.shared
    @State private var flower: VMSpecies? = nil
    
    var body: some View {
        NavigationStack(path: $navigationService.path) {
            // Your main/home view here
            ContentView()
                .navigationDestination(for: NavigationDestination.self) { destination in
                    switch destination {
                    case .deviceDetails(let device):
                        let viewModel = AddDeviceDetailsViewModel(device: device)
                        AddDeviceDetails(viewModel: viewModel)
                    case .deviceList:
                        OverviewList()
                    case .home:
                        ContentView()
                    case .deviceView(let device):
                        DeviceDetailsView(device: device)
                    case .addDeviceWithoutSensor:
                        AddWithoutSensor(flower: $flower)
                    case .deviceDetailsSpecies(let flower):
                        let viewModel = AddDeviceDetailsViewModel(flower: flower)
                        AddDeviceDetails(viewModel: viewModel)
                    }
                }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FlowerDevice.self, inMemory: true)
}

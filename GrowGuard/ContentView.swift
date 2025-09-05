//
//  ContentView.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI
import SwiftData
import CoreData

class ContentViewModel: Observable {
    var allSavedDevices: [FlowerDeviceDTO] = []
    private let repositoryManager = RepositoryManager.shared

    init(allSavedDevices: [FlowerDeviceDTO] = []) {
        self.allSavedDevices = allSavedDevices
        
        Task {
            await self.fetchSavedDevices()
        }
    }
    
    @MainActor
    func fetchSavedDevices() async {
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
        } catch {
            print(L10n.Device.Error.fetchingDevices(error.localizedDescription))
        }
    }
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
                    Tab(L10n.Navigation.menu, systemImage: "leaf", value: .overview) {
                        OverviewList()
                    }
                    
                    Tab(L10n.Navigation.add, systemImage: "plus.app", value: .addDevice) {
                        AddDeviceView()
                    }
                }
            }
        }.onAppear {
            let defaults = UserDefaults.standard
            showOnboarding = !defaults.bool(forKey: L10n.Userdefaults.showOnboarding)
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
}

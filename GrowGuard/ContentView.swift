//
//  ContentView.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI

enum NavigationTabs {
    case overview
    case addDevice
    case settings
}

struct ContentView: View {
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

                    Tab(L10n.Navigation.settings, systemImage: "gear", value: .settings) {
                        NavigationStack {
                            AppSettingsView()
                        }
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

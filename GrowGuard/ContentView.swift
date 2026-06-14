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
                        OverviewTab()
                    }

                    Tab(L10n.Navigation.add, systemImage: "plus.app", value: .addDevice) {
                        AddDeviceTab()
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

/// Overview tab — owns its own navigation stack so pushes are scoped to this tab
/// and never have to fight the surrounding `TabView`.
private struct OverviewTab: View {
    @State private var navigationService = NavigationService.shared

    var body: some View {
        NavigationStack(path: $navigationService.overviewPath) {
            OverviewList()
                .navigationDestination(for: OverviewRoute.self) { route in
                    switch route {
                    case .deviceDetail(let device):
                        DeviceDetailsView(device: device)
                    }
                }
        }
    }
}

/// Add Device tab — owns its own navigation stack for the onboarding flow.
private struct AddDeviceTab: View {
    @State private var navigationService = NavigationService.shared
    @State private var pendingSpecies: VMSpecies? = nil

    var body: some View {
        NavigationStack(path: $navigationService.addDevicePath) {
            AddDeviceView()
                .navigationDestination(for: AddDeviceRoute.self) { route in
                    switch route {
                    case .sensorDetails(let device, let name):
                        // Prefer the suggested sequential name, fallback to BLE name.
                        let displayName = name ?? device.name ?? L10n.Device.unknownDevice
                        AddDeviceDetails(viewModel: AddDeviceDetailsViewModel(device: device, suggestedName: displayName))
                    case .speciesDetails(let flower):
                        AddDeviceDetails(viewModel: AddDeviceDetailsViewModel(flower: flower))
                    case .withoutSensor:
                        AddWithoutSensor(flower: $pendingSpecies)
                    }
                }
        }
    }
}

struct MainNavigationView: View {
    var body: some View {
        ContentView()
    }
}

#Preview {
    ContentView()
}

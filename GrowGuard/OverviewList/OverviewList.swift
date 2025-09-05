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
    @State private var deviceToDelete: IndexSet?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false

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
                
                NavigationLink(destination: LogExportView()) {
                    Text(L10n.Debug.menu)
                }
                
                Section {
                    ForEach(viewModel.allSavedDevices) { device in
                        Button {
                            // Add a new method to NavigationService
                            NavigationService.shared.navigateToDeviceView(flowerDevice: device)
                        } label: {
                            Text(device.name ?? "")
                            Text(device.lastUpdate , format: .dateTime)
                        }
                        .navigationLinkStyle()
                        .contentShape(Rectangle())
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle(L10n.Navigation.overview)
        .toolbar {
            EditButton()
        }
        .onAppear {
            self.loading = true
            Task {
                await viewModel.fetchSavedDevices()
                self.loading = false
            }
        }
        .overlay {
            if loading {
                ProgressView()
            }
        }
        .alert(L10n.Device.delete, isPresented: $showDeleteConfirmation) {
            Button(L10n.Alert.cancel, role: .cancel) {
                deviceToDelete = nil
            }
            Button(L10n.Alert.delete, role: .destructive) {
                confirmDelete()
            }
        } message: {
            if let offsets = deviceToDelete, let index = offsets.first {
                Text(L10n.Device.deleteConfirmation(viewModel.allSavedDevices[index].name ?? "this device"))
            }
        }
        .alert(L10n.Alert.error, isPresented: $showDeleteError) {
            Button(L10n.Alert.ok) {
                viewModel.deleteError = nil
            }
        } message: {
            if let error = viewModel.deleteError {
                Text(error)
            }
        }
        .onChange(of: viewModel.deleteError) { _, newError in
            showDeleteError = newError != nil
        }
    }
    
    func delete(at offsets: IndexSet) {
        deviceToDelete = offsets
        showDeleteConfirmation = true
    }
    
    private func confirmDelete() {
        guard let offsets = deviceToDelete else { return }
        Task {
            await viewModel.deleteDevice(at: offsets)
        }
        deviceToDelete = nil
    }
}

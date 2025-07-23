//
//  OverviewListViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import CoreData

@Observable class OverviewListViewModel {
    var allSavedDevices: [FlowerDeviceDTO] = []
    private let repositoryManager = RepositoryManager.shared

    init() {
        Task {
            await fetchSavedDevices()
        }
    }
    
    @MainActor
    func fetchSavedDevices() async {
        do {
            allSavedDevices = try await repositoryManager.flowerDeviceRepository.getAllDevices()
        } catch {
            print("Error fetching devices: \(error.localizedDescription)")
        }
    }
    
}

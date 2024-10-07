//
//  OverviewListViewModel.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import SwiftUI
import SwiftData

@Observable class OverviewListViewModel {
    var allSavedDevices: [FlowerDevice] = []

    init() {
        Task {
            await fetchSavedDevices()
        }
    }
    
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

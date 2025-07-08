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
    var allSavedDevices: [FlowerDevice] = []

    init() {
        Task {
            await fetchSavedDevices()
        }
    }
    
    @MainActor
    func fetchSavedDevices() {
        let fetchRequest = NSFetchRequest<FlowerDevice>(entityName: "FlowerDevice")
        do {
            let result = try DataService.shared.context.fetch(fetchRequest)
            allSavedDevices = result
        } catch {
            print(error.localizedDescription)
        }
    }
    
}

//
//  AddWithoutSensorViewModel.swift
//  GrowGuard
//
//  Created by veitprogl on 11.06.25.
//
import SwiftUI

@Observable class AddWithoutSensorViewModel {
    private var flowerSearch: FlowerSearch
    
    var searchName: String = ""
    var searchResult: [VMSpecies] = []
    
    init(flowerSearch: FlowerSearch = FlowerSearch()) {
        self.flowerSearch = flowerSearch
        
        Task {
            do {
                try await flowerSearch.seachFamiles()
            } catch {
                
            }
        }
    }
    
    func searchFlower() async {
        do {
            searchResult = try await flowerSearch.seach(flower: searchName).map { spec in
                VMSpecies(name: spec.scientificNname, id: spec.id, imageUrl: spec.imageUrl, minMoisture: spec.minMoisture, maxMoisture: spec.maxMoisture)
            }
        } catch {
            
        }
    }
    
    func navigateToFlowerDetail(flower: VMSpecies) {
        NavigationService.shared.navigateToDeviceDetails(flower: flower)
    }
}


struct VMSpecies: Identifiable, Equatable, Hashable {
        var name: String
        var id: Int64
        var imageUrl: String?
        var minMoisture: Int? = nil
        var maxMoisture: Int? = nil
    }

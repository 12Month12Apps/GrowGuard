//
//  FlowerSelectionView.swift
//  GrowGuard
//
//  Created for Settings screen flower selection
//

import SwiftUI

struct FlowerSelectionView: View {
    @Environment(\.dismiss) var dismiss
    @State private var viewModel = FlowerSelectionViewModel()
    @Binding var selectedFlower: VMSpecies?
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        TextField(text: $viewModel.searchName, label: {
                            Label("Search Flower", systemImage: "leaf")
                        })
                        .submitLabel(.search)
                        .onSubmit {
                            Task {
                                await viewModel.searchFlower()
                            }
                        }
                        
                        Button(action: {
                            Task {
                                await viewModel.searchFlower()
                            }
                        }) {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    
                    if let currentFlower = selectedFlower {
                        VStack(alignment: .leading) {
                            Text("Currently Selected:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text(currentFlower.name)
                                    .font(.headline)
                                Spacer()
                                Button("Remove") {
                                    selectedFlower = nil
                                }
                                .foregroundColor(.red)
                            }
                            if let minMoisture = currentFlower.minMoisture,
                               let maxMoisture = currentFlower.maxMoisture {
                                Text("Recommended Moisture: \(minMoisture)% - \(maxMoisture)%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if !viewModel.searchResult.isEmpty {
                    Section("Search Results") {
                        ForEach(viewModel.searchResult) { flower in
                            VStack(alignment: .leading) {
                                Text(flower.name)
                                    .font(.headline)
                                
                                if let minMoisture = flower.minMoisture,
                                   let maxMoisture = flower.maxMoisture {
                                    Text("Recommended Moisture: \(minMoisture)% - \(maxMoisture)%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Will update your moisture settings")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedFlower = flower
                                dismiss()
                            }
                        }
                    }
                }
                
                if viewModel.searchName.isEmpty && viewModel.searchResult.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "leaf.circle")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            
                            Text("Search for a flower")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Text("Enter a flower name to find optimal growing conditions and care recommendations.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
            }
            .navigationTitle("Select Flower")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

@Observable class FlowerSelectionViewModel {
    private var flowerSearch: FlowerSearch
    
    var searchName: String = ""
    var searchResult: [VMSpecies] = []
    var isLoading: Bool = false
    
    init(flowerSearch: FlowerSearch = FlowerSearch()) {
        self.flowerSearch = flowerSearch
    }
    
    func searchFlower() async {
        guard !searchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResult = []
            return
        }
        
        isLoading = true
        do {
            searchResult = try await flowerSearch.seach(flower: searchName).map { spec in
                VMSpecies(
                    name: spec.scientificNname,
                    id: spec.id,
                    imageUrl: spec.imageUrl,
                    minMoisture: spec.minMoisture,
                    maxMoisture: spec.maxMoisture,
                    commonNames: spec.commonNames
                )
            }
        } catch {
            print("Error searching flowers: \(error)")
            searchResult = []
        }
        isLoading = false
    }
}

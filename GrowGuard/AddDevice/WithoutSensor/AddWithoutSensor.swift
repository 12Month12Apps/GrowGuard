//
//  AddWithoutSensor.swift
//  GrowGuard
//
//  Created by veitprogl on 11.06.25.
//

import SwiftUI
//import FoundationModels

struct AddWithoutSensor: View {
    @Environment(\.dismiss) var dismiss
    @State var viewModel = AddWithoutSensorViewModel()
    @Binding var flower: VMSpecies?
    var searchMode: Bool = false
    
    var body: some View {
        List {
            Section {
                HStack {
                    TextField(text: $viewModel.searchName, label: {
                        Label(L10n.Device.searchFlower, systemImage: "camera.macro") //TODO: Why is icon not shown?
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
                
            }
            
            ForEach(viewModel.searchResult) { flower in
                VStack(alignment: .leading) {
                    Text(flower.name)
                        .font(.headline)
                    
                    if flower.minMoisture != nil {
                        Text(L10n.Plant.soilMoisture(flower.minMoisture ?? 0, flower.maxMoisture ?? 100))
                    }
                }.onTapGesture {
                    if searchMode {
                        self.flower = flower
                        dismiss()
                    } else {
                        viewModel.navigateToFlowerDetail(flower: flower)
                    }
                }
            }
        }
        .navigationTitle(L10n.Plant.addFlower)
        .onAppear {
//                Task {
//                    let instructions = """
//                    Suggest the name of the flower. And make sure they are procise as possible. 
//                    """
//
//                    if #available(iOS 26.0, *) {
//                        print("Using LanguageModelSession")
//                        let session = LanguageModelSession(instructions: instructions)
//
//                        let prompt = "image base64 data: \(UIImage(named: "testflower")?.base64 ?? "" )"
//                        print("Using prompt: \(prompt)")
//                        let response = try await session.respond(to: prompt)
//                        print(response)
//                    } else {
//                        // Fallback on earlier versions
//                    }
//                }
        }
    }
}


//
//  PotView.swift
//  GrowGuard
//
//  Created by veitprogl on 19.07.25.
//

import SwiftUI

struct PotView: View {
    @State private var waterFill: CGFloat = 0.0
    @State private var waterFillProzentage: CGFloat = 0.0
    @Binding var potSize: PotSize
    
    var body: some View {
        Section {
            VStack {
                WaterFillPotView(fill: $waterFillProzentage)
                
                Divider()
                
                HStack(alignment: .center) {
                    Button {
                            waterFill -= 0.1
                            waterFillProzentage = round(waterFill / (potSize.volume / 1000) * 100) / 100
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    
                    Text("100ml")
                    
                    Button {
                            waterFill += 0.1
                            waterFillProzentage = round(waterFill / (potSize.volume / 1000) * 100) / 100
                            print(waterFill)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                
                VStack {
                    Text("Max pot volume: \(potSize.volume / 1000, specifier: "%.1f")l")
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Current fill volume: \(waterFill, specifier: "%.1f")l")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                
                VStack {
                    Button("Save Water") {
//                        viewModel.device.sensorData.append(SensorData(temperature: 0,
//                                                                      brightness: 0,
//                                                                      moisture: UInt8(waterFillProzentage * 100),
//                                                                      conductivity: 0,
//                                                                      date: Date(),
//                                                                      device: viewModel.device))
//                        viewModel.saveDatabase()
                    }
                }
            }
        }
    }
}

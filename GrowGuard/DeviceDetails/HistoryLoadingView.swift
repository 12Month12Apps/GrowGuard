//
//  HistoryLoadingView.swift
//  GrowGuard
//
//  Created by veitprogl on 23.03.25.
//

import SwiftUI
import Combine

struct HistoryLoadingView: View {
    @State private var progress: Double = 0
    @State private var currentCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var loadingState: FlowerCareManager.LoadingState = .idle
    @State private var errorMessage: String = ""
    @State private var connectionQuality: FlowerCareManager.ConnectionQuality = .unknown
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        VStack(spacing: 20) {
            if loadingState == .loading {
                Text("Loading Historical Data")
                    .font(.headline)
                
                // Connection quality indicator
                connectionQualityView
                    .padding(.vertical, 8)
                
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 250)
                
                Text("\(currentCount) of \(totalCount) entries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("Please keep the app open")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            } else if loadingState == .completed {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("Loading Complete!")
                        .font(.headline)
                    
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else if case .error(let message) = loadingState {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    
                    Text("Error Loading Data")
                        .font(.headline)
                    
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity)
                    
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .frame(width: 340, height: 300) // Increased size to accommodate connection info
        .onAppear {
            setupSubscribers()
        }
        .onDisappear {
            FlowerCareManager.shared.cancelHistoryDataLoading()
        }
    }
    
    // Connection quality view
    private var connectionQualityView: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Connection Quality: ")
                    .font(.caption)
                
                Text(qualityText)
                    .font(.caption.bold())
                    .foregroundColor(qualityColor)
            }
            
            // Signal strength bars
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<3) { index in
                    Rectangle()
                        .fill(barColor(for: index))
                        .frame(width: 10, height: CGFloat(8 + (index * 6)))
                        .cornerRadius(2)
                }
            }
            
            // Show recommendation if connection is poor
            if connectionQuality == .poor {
                Text("Please move closer to the device")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.top, 4)
            }
        }
    }
    
    private var qualityText: String {
        switch connectionQuality {
        case .unknown:
            return "Checking..."
        case .poor:
            return "Poor"
        case .fair:
            return "Fair"
        case .good:
            return "Good"
        }
    }
    
    private var qualityColor: Color {
        switch connectionQuality {
        case .unknown:
            return .gray
        case .poor:
            return .orange
        case .fair:
            return .yellow
        case .good:
            return .green
        }
    }
    
    private func barColor(for index: Int) -> Color {
        switch connectionQuality {
        case .unknown:
            return .gray
        case .poor:
            return index == 0 ? .orange : .gray
        case .fair:
            return index <= 1 ? .yellow : .gray
        case .good:
            return .green
        }
    }
    
    private func setupSubscribers() {
        FlowerCareManager.shared.loadingProgressPublisher
            .sink { current, total in
                self.currentCount = current
                self.totalCount = total
                self.progress = total > 0 ? Double(current) / Double(total) : 0
            }
            .store(in: &cancellables)
        
        FlowerCareManager.shared.loadingStatePublisher
            .sink { state in
                self.loadingState = state
                if case .error(let message) = state {
                    self.errorMessage = message
                }
            }
            .store(in: &cancellables)
        
        // Add subscriber for connection quality updates
        FlowerCareManager.shared.connectionQualityPublisher
            .sink { quality in
                self.connectionQuality = quality
            }
            .store(in: &cancellables)
    }
}

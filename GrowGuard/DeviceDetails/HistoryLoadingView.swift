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
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        VStack(spacing: 20) {
            if loadingState == .loading {
                Text("Loading Historical Data")
                    .font(.headline)
                
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
        .frame(width: 300, height: 200)
        .onAppear {
            setupSubscribers()
        }
        .onDisappear {
            FlowerCareManager.shared.cancelHistoryDataLoading()
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
    }
}

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
    @State private var showingDetails: Bool = false
    @State private var connectionQuality: FlowerCareManager.ConnectionQuality = .unknown
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var cancellables = Set<AnyCancellable>()
    
    // Time tracking for accurate speed calculation
    @State private var loadingStartTime: Date?
    @State private var lastProgressTime: Date?
    @State private var recentSpeeds: [Double] = [] // Rolling average of recent speeds
    @State private var lastCount: Int = 0
    
    var body: some View {
        ZStack {
            // Background with subtle gradient
            LinearGradient(
                gradient: Gradient(colors: [Color(.systemBackground), Color(.systemGray6)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // Single unified view for all states
            unifiedView
            .padding(32)
        }
        .onAppear {
            setupSubscribers()
        }
        .onDisappear {
            FlowerCareManager.shared.cancelHistoryDataLoading()
        }
    }
    
    // MARK: - Unified View (handles all states)
    private var unifiedView: some View {
        VStack(spacing: 24) {
            // Dynamic icon based on state
            Group {
                if loadingState == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundColor(.green)
                        .scaleEffect(1.0)
                } else {
                    Image(systemName: "leaf.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green.gradient)
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: loadingState == .loading)
                }
            }
            
            // Dynamic title and subtitle
            VStack(spacing: 8) {
                Group {
                    if loadingState == .completed {
                        Text("History Loaded!")
                    } else {
                        Text("Loading Plant History")
                    }
                }
                .font(.title2.bold())
                .foregroundColor(.primary)
                
                Group {
                    if loadingState == .completed {
                        if totalCount > 0 {
                            Text("\(totalCount) entries loaded successfully")
                        } else {
                            Text("Your plant history is up to date")
                        }
                    } else {
                        if totalCount > 0 {
                            Text("\(currentCount) of \(totalCount) entries")
                        } else {
                            Text("Connecting to your plant sensor...")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            
            // Dynamic content based on state
            if loadingState == .completed {
                // Completed state - just the done button
                Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
            } else {
                // Loading state - progress and details
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .green))
                        .frame(height: 8)
                        .scaleEffect(x: 1.0, y: 1.5)
                    
                    if progress > 0 {
                        Text("\(Int(progress * 100))% complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Error message display (if there's an error)
                    if case .error(let message) = loadingState {
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Issue detected - retrying automatically...")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                
                // Connection status
                connectionStatusView
                
                // Expandable details
                Button(action: {
                    withAnimation(.spring()) {
                        showingDetails.toggle()
                    }
                }) {
                    HStack {
                        Text(showingDetails ? "Hide Details" : "Show Details")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .rotationEffect(.degrees(showingDetails ? 180 : 0))
                    }
                }
                
                if showingDetails {
                    detailsView
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
    
    
    // MARK: - Connection Status (Simplified)
    private var connectionStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
                .scaleEffect(connectionQuality == .good ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: connectionQuality == .good)
            
            Text(connectionStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(20)
    }
    
    private var connectionColor: Color {
        switch connectionQuality {
        case .unknown: return .gray
        case .poor: return .red
        case .fair: return .orange  
        case .good: return .green
        }
    }
    
    private var connectionStatusText: String {
        switch connectionQuality {
        case .unknown: return "Connecting..."
        case .poor: return "Weak signal"
        case .fair: return "Fair connection"
        case .good: return "Strong connection"
        }
    }
    
    // MARK: - Expandable Details
    private var detailsView: some View {
        VStack(spacing: 16) {
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                DetailRow(title: "Progress", value: totalCount > 0 ? "\(currentCount)/\(totalCount)" : "Initializing...")
                DetailRow(title: "Status", value: connectionStatusText)
                DetailRow(title: "Speed", value: estimatedTimeRemaining)
                
                if connectionQuality == .poor {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Move closer to your plant sensor for better speed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.top, 8)
    }
    
    private var estimatedTimeRemaining: String {
        guard totalCount > 0, currentCount > 0, progress > 0.01 else {
            return "Calculating..."
        }
        
        // Need at least some speed data to make an estimate
        guard !recentSpeeds.isEmpty else {
            return "Estimating..."
        }
        
        let remainingEntries = totalCount - currentCount
        
        // Use rolling average of recent speeds for more accurate estimation
        let averageSpeed = recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)
        
        // Ensure we have a reasonable minimum speed to avoid infinite times
        let effectiveSpeed = max(averageSpeed, 0.05) // At least 1 entry per 20 seconds
        
        let secondsRemaining = Double(remainingEntries) / effectiveSpeed
        
        // Cap maximum estimate at 30 minutes to avoid showing ridiculous times
        let cappedSeconds = min(secondsRemaining, 1800) // 30 minutes max
        
        if cappedSeconds < 60 {
            return "\(Int(cappedSeconds))s remaining"
        } else {
            let minutes = Int(cappedSeconds / 60)
            if minutes == 1 {
                return "1m remaining"
            } else {
                return "\(minutes)m remaining"
            }
        }
    }
    
    // MARK: - Old Connection Quality View (keeping for compatibility)
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
                let now = Date()
                
                // Initialize timing if this is the first progress update
                if self.loadingStartTime == nil && current > 0 {
                    self.loadingStartTime = now
                    self.lastProgressTime = now
                    self.lastCount = current
                }
                
                // Calculate speed if we have progress and time data
                if let lastTime = self.lastProgressTime, current > self.lastCount {
                    let timeDiff = now.timeIntervalSince(lastTime)
                    if timeDiff > 0.5 { // Only update every 0.5 seconds to avoid noise
                        let entriesDiff = current - self.lastCount
                        let currentSpeed = Double(entriesDiff) / timeDiff // entries per second
                        
                        // Keep rolling average of recent speeds (last 10 measurements)
                        self.recentSpeeds.append(currentSpeed)
                        if self.recentSpeeds.count > 10 {
                            self.recentSpeeds.removeFirst()
                        }
                        
                        self.lastProgressTime = now
                        self.lastCount = current
                    }
                }
                
                self.currentCount = current
                self.totalCount = total
                self.progress = total > 0 ? Double(current) / Double(total) : 0
            }
            .store(in: &cancellables)
        
        FlowerCareManager.shared.loadingStatePublisher
            .sink { state in
                // Reset timing when loading starts
                if case .loading = state, case .idle = self.loadingState {
                    self.loadingStartTime = nil
                    self.lastProgressTime = nil
                    self.recentSpeeds = []
                    self.lastCount = 0
                }
                
                self.loadingState = state
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

// MARK: - Detail Row Component
struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.caption.bold())
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Preview
struct HistoryLoadingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            HistoryLoadingView()
                .previewDisplayName("Loading")
            
            HistoryLoadingView()
                .previewDisplayName("Dark Mode")
                .preferredColorScheme(.dark)
        }
    }
}

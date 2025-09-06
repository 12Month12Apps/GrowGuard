//
//  HistoryListView.swift
//  GrowGuard
//
//  Created by Claude Code on 05.09.25.
//

import SwiftUI

struct HistoryListView: View {
    let device: FlowerDeviceDTO
    @State private var allHistoryData: [SensorDataDTO] = []
    @State private var groupedData: [Date: [SensorDataDTO]] = [:]
    @State private var sortedDays: [Date] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    private let repositoryManager = RepositoryManager.shared
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    VStack {
                        ProgressView()
                        Text("Loading sensor data...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(L10n.Error.loadingData)
                            .font(.headline)
                            .padding(.top, 8)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .padding()
                } else if allHistoryData.isEmpty {
                    VStack {
                        Image(systemName: "clock")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(L10n.History.noData)
                            .font(.headline)
                            .padding(.top, 8)
                        Text(L10n.History.noDataDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(sortedDays, id: \.self) { day in
                            Section(header: Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day().year())) {
                                if let dayData = groupedData[day] {
                                    ForEach(dayData) { entry in
                                        HistoryEntryRow(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.History.title)
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            loadHistoryData()
        }
        .refreshable {
            loadHistoryData()
        }
    }
    
    private func loadHistoryData() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let data = try await repositoryManager.sensorDataRepository.getSensorData(for: device.uuid, limit: nil)
                
                await MainActor.run {
                    self.allHistoryData = data.sorted { $0.date > $1.date }
                    self.groupDataByDays()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func groupDataByDays() {
        let calendar = Calendar.current
        var grouped: [Date: [SensorDataDTO]] = [:]
        
        for entry in allHistoryData {
            let dayStart = calendar.startOfDay(for: entry.date)
            if grouped[dayStart] != nil {
                grouped[dayStart]?.append(entry)
            } else {
                grouped[dayStart] = [entry]
            }
        }
        
        // Sort entries within each day by time
        for (day, entries) in grouped {
            grouped[day] = entries.sorted { $0.date > $1.date }
        }
        
        self.groupedData = grouped
        self.sortedDays = Array(grouped.keys).sorted { $0 > $1 }
    }
}

struct HistoryEntryRow: View {
    let entry: SensorDataDTO
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "drop.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("\(entry.moisture)%")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("\(entry.temperature, specifier: "%.1f")°C")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .foregroundColor(.yellow)
                        .font(.caption2)
                    Text("\(entry.brightness) lux")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.green)
                        .font(.caption2)
                    Text("\(entry.conductivity) µS/cm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HistoryListView(device: FlowerDeviceDTO(
        id: "test-id",
        name: "Test Plant",
        uuid: "test-uuid",
        peripheralID: nil,
        battery: 75,
        firmware: "1.0",
        isSensor: true,
        added: Date(),
        lastUpdate: Date(),
        optimalRange: nil,
        potSize: nil,
        selectedFlower: nil,
        sensorData: []
    ))
}
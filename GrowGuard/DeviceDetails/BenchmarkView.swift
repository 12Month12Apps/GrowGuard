//
//  BenchmarkView.swift
//  GrowGuard
//
//  UI for BLE Performance Benchmarks
//

import SwiftUI

struct BenchmarkView: View {
    let deviceUUID: String

    @StateObject private var benchmark = BLEBenchmark.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("BLE Performance Benchmark")
                            .font(.title2.bold())

                        Text("Compare FlowerManager vs ConnectionPool")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()

                    // Start Button
                    if !benchmark.isRunning {
                        Button(action: {
                            Task {
                                await benchmark.runBenchmark(deviceUUID: deviceUUID)
                            }
                        }) {
                            Label("Start Benchmark", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    } else {
                        // Running indicator
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)

                            Text("Running: \(benchmark.currentTest)")
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                        .padding()
                    }

                    // Results
                    if let fm = benchmark.flowerManagerResult {
                        resultCard(result: fm, color: .orange)
                    }

                    if let cp = benchmark.connectionPoolResult {
                        resultCard(result: cp, color: .green)
                    }

                    // Comparison
                    if let fm = benchmark.flowerManagerResult,
                       let cp = benchmark.connectionPoolResult {
                        comparisonCard(flowerManager: fm, connectionPool: cp)
                    }

                    // Logs
                    if !benchmark.logs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Debug Logs")
                                    .font(.headline)

                                Spacer()

                                Button(action: {
                                    copyLogsToClipboard()
                                }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(benchmark.logs.suffix(50), id: \.self) { log in
                                        Text(log)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(height: 200)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(8)
                        }
                        .padding()
                        .background(Color(.systemGroupedBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Result Card

    private func resultCard(result: BenchmarkResult, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: result.implementation == "FlowerManager" ? "briefcase.fill" : "gearshape.2.fill")
                    .foregroundColor(color)

                Text(result.implementation)
                    .font(.headline)

                Spacer()

                Text("\(String(format: "%.1f", result.successRate))%")
                    .font(.title3.bold())
                    .foregroundColor(color)
            }

            Divider()

            VStack(spacing: 8) {
                metricRow(label: "Connection", value: "\(String(format: "%.2f", result.connectionTime))s")
                metricRow(label: "Authentication", value: "\(String(format: "%.2f", result.authenticationTime))s")
                metricRow(label: "First Entry", value: "\(String(format: "%.2f", result.firstEntryTime))s")
                metricRow(label: "Total Time", value: "\(String(format: "%.2f", result.totalDownloadTime))s")

                Divider()

                metricRow(label: "Entries", value: "\(result.totalEntries)")
                metricRow(label: "Speed", value: "\(String(format: "%.1f", result.entriesPerSecond)) entries/s", highlight: true)

                Divider()

                metricRow(label: "Retries", value: "\(result.retryCount)")
                metricRow(label: "Errors", value: "\(result.errorCount)")
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color, lineWidth: 2)
        )
        .padding(.horizontal)
    }

    private func metricRow(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(highlight ? .headline : .body)
                .foregroundColor(highlight ? .primary : .secondary)
        }
    }

    // MARK: - Comparison Card

    private func comparisonCard(flowerManager: BenchmarkResult, connectionPool: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(.blue)

                Text("Performance Comparison")
                    .font(.headline)

                Spacer()

                let winner = connectionPool.entriesPerSecond > flowerManager.entriesPerSecond ? "New" : "Legacy"
                Text("Winner: \(winner)")
                    .font(.caption.bold())
                    .foregroundColor(.blue)
            }

            Divider()

            // Speed comparison
            comparisonRow(
                title: "Speed",
                oldValue: flowerManager.entriesPerSecond,
                newValue: connectionPool.entriesPerSecond,
                unit: " entries/s",
                higherIsBetter: true
            )

            // Time comparison
            comparisonRow(
                title: "Total Time",
                oldValue: flowerManager.totalDownloadTime,
                newValue: connectionPool.totalDownloadTime,
                unit: "s",
                higherIsBetter: false
            )

            // Error comparison
            HStack {
                Text("Errors")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(flowerManager.errorCount) → \(connectionPool.errorCount)")
                    .font(.body)
                    .foregroundColor(connectionPool.errorCount < flowerManager.errorCount ? .green : .orange)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue, lineWidth: 2)
        )
        .padding(.horizontal)
    }

    private func comparisonRow(title: String, oldValue: Double, newValue: Double, unit: String, higherIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                // Old value
                Text("\(String(format: "%.2f", oldValue))\(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // New value
                Text("\(String(format: "%.2f", newValue))\(unit)")
                    .font(.body.bold())

                Spacer()

                // Percentage change
                let diff = ((newValue - oldValue) / oldValue) * 100
                let isImprovement = higherIsBetter ? diff > 0 : diff < 0

                HStack(spacing: 4) {
                    Image(systemName: isImprovement ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)

                    Text("\(String(format: "%.1f", abs(diff)))%")
                        .font(.caption.bold())
                }
                .foregroundColor(isImprovement ? .green : .red)
            }
        }
    }

    // MARK: - Helpers

    private func copyLogsToClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = benchmark.logs.joined(separator: "\n")
        #endif
    }
}

#Preview {
    BenchmarkView(deviceUUID: "12345678-1234-1234-1234-123456789ABC")
}

//
//  GrowGuardWidgetsLiveActivity.swift
//  GrowGuardWidgets
//
//  Created by veitprogl on 21.11.25.
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity widget for displaying history loading progress
/// Appears in Dynamic Island (iPhone 14 Pro+) and Lock Screen
struct GrowGuardWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HistoryLoadingAttributes.self) { context in
            // Lock Screen / StandBy view
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view (long press on Dynamic Island)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(.green)
                        Text(context.attributes.deviceName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if let timeString = context.state.estimatedTimeString {
                        VStack(alignment: .trailing) {
                            Text(timeString)
                                .font(.headline)
                                .monospacedDigit()
                            Text("remaining")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(context.state.progressPercentage)
                            .font(.headline)
                            .monospacedDigit()
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        // Progress bar
                        ProgressView(value: context.state.progress)
                            .progressViewStyle(.linear)
                            .tint(.green)

                        HStack {
                            // Status indicator
                            HStack(spacing: 4) {
                                Image(systemName: context.state.connectionStatus.systemImage)
                                    .font(.caption)
                                Text(context.state.connectionStatus.displayString)
                                    .font(.caption)
                            }
                            .foregroundStyle(statusColor(for: context.state.connectionStatus))

                            Spacer()

                            // Entry count
                            Text(context.state.entryCountString)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Compact leading (left side of Dynamic Island pill)
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                // Compact trailing (right side of Dynamic Island pill)
                Text(context.state.progressPercentage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.green)
            } minimal: {
                // Minimal view (when another Live Activity takes priority)
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: context.state.progress)
                        .stroke(Color.green, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func statusColor(for status: HistoryLoadingAttributes.ConnectionStatus) -> Color {
        switch status {
        case .connecting, .reconnecting:
            return .orange
        case .connected, .loading:
            return .green
        case .completed:
            return .blue
        case .failed:
            return .red
        }
    }
}

// MARK: - Lock Screen View

struct LockScreenView: View {
    let context: ActivityViewContext<HistoryLoadingAttributes>

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // Device info
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(.green)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.deviceName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Loading History")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Progress percentage
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.progressPercentage)
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()

                    if let timeString = context.state.estimatedTimeString {
                        Text("\(timeString) left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Progress bar
            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
                .tint(.green)

            // Bottom info row
            HStack {
                // Status
                HStack(spacing: 4) {
                    if context.state.isPaused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: context.state.connectionStatus.systemImage)
                            .foregroundStyle(statusColor)
                    }
                    Text(context.state.isPaused ? "Paused" : context.state.connectionStatus.displayString)
                        .font(.caption)
                }

                Spacer()

                // Entry count
                Text(context.state.entryCountString)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Error message if any
            if let error = context.state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.8))
        .activitySystemActionForegroundColor(.white)
    }

    private var statusColor: Color {
        switch context.state.connectionStatus {
        case .connecting, .reconnecting:
            return .orange
        case .connected, .loading:
            return .green
        case .completed:
            return .blue
        case .failed:
            return .red
        }
    }
}

// MARK: - Preview

#Preview("Lock Screen", as: .content, using: HistoryLoadingAttributes(
    deviceName: "Living Room Plant",
    deviceUUID: "ABC123"
)) {
    GrowGuardWidgetsLiveActivity()
} contentStates: {
    HistoryLoadingAttributes.ContentState(
        currentEntry: 150,
        totalEntries: 500,
        connectionStatus: .loading,
        estimatedSecondsRemaining: 180,
        isPaused: false
    )
    HistoryLoadingAttributes.ContentState(
        currentEntry: 450,
        totalEntries: 500,
        connectionStatus: .loading,
        estimatedSecondsRemaining: 30,
        isPaused: false
    )
    HistoryLoadingAttributes.ContentState(
        currentEntry: 100,
        totalEntries: 500,
        connectionStatus: .reconnecting,
        estimatedSecondsRemaining: nil,
        isPaused: true
    )
}

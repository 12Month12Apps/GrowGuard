//
//  BatteryIndicator.swift
//  GrowGuard
//
//  Honest battery chip: symbol and colour by level, "–" when never read,
//  age caption when the read is older than SensorHealth.staleBatteryAfter.
//

import SwiftUI

struct BatteryIndicator: View {
    enum Style {
        /// Overview row: caption-sized, single line, no background
        case compact
        /// Details header: padded chip with tinted background
        case chip
    }

    let device: FlowerDeviceDTO
    let health: SensorHealth
    let style: Style

    private var readAt: Date? { device.batteryReadAt }

    private var isStale: Bool {
        guard let readAt else { return false }
        return Date().timeIntervalSince(readAt) > SensorHealth.staleBatteryAfter
    }

    private var symbolName: String {
        guard readAt != nil else { return "battery.0percent" }
        switch Int(device.battery) {
        case 88...: return "battery.100percent"
        case 63...87: return "battery.75percent"
        case 38...62: return "battery.50percent"
        case 13...37: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var color: Color {
        switch health {
        case .batteryCritical: return .red
        case .batteryLow: return .orange
        case .batteryUnknown: return .secondary
        case .unreachable(_, let lastKnown, _):
            guard let lastKnown else { return .secondary }
            return lastKnown <= SensorHealth.criticalBattery ? .red : (lastKnown <= SensorHealth.lowBattery ? .orange : .green)
        case .ok: return .green
        }
    }

    private var valueLabel: Text {
        readAt == nil
            ? Text(L10n.SensorHealth.Battery.unknown)
            : Text(Int(device.battery), format: .percent)
    }

    private func staleCaption(_ readAt: Date) -> String {
        L10n.SensorHealth.Battery.readAgo(readAt.formatted(.relative(presentation: .named)))
    }

    var body: some View {
        switch style {
        case .compact: compactBody
        case .chip: chipBody
        }
    }

    /// The overview row has a fixed height, so everything stays on one line and
    /// the age is dropped entirely when the unreachable line already says the
    /// sensor is silent.
    private var compactBody: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.caption2)
                .foregroundColor(color)
            valueLabel
                .font(.caption)
            if isStale, !health.isUnreachable, let readAt {
                Text("· " + staleCaption(readAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chipBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.body)
                    .foregroundColor(color)
                valueLabel
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            if isStale, let readAt {
                Text(staleCaption(readAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
        .cornerRadius(10)
    }
}

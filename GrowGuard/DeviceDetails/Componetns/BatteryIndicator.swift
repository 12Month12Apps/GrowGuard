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
        /// Overview row: caption-sized, no background
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

    private var valueText: String {
        readAt == nil ? L10n.SensorHealth.Battery.unknown : "\(Int(device.battery)) %"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: style == .chip ? 6 : 4) {
                Image(systemName: symbolName)
                    .font(style == .chip ? .body : .caption2)
                    .foregroundColor(color)
                Text(valueText)
                    .font(style == .chip ? .subheadline : .caption)
                    .fontWeight(style == .chip ? .medium : .regular)
            }
            if isStale, let readAt {
                Text(L10n.SensorHealth.Battery.readAgo(readAt.formatted(.relative(presentation: .named))))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, style == .chip ? 16 : 0)
        .padding(.vertical, style == .chip ? 10 : 0)
        .background(style == .chip ? color.opacity(0.1) : Color.clear)
        .cornerRadius(style == .chip ? 10 : 0)
    }
}

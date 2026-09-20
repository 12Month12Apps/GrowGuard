//
//  SensorHealthBanner.swift
//  GrowGuard
//
//  Unreachable state. `.line` replaces the connection-status line in the
//  overview row; `.banner` is the full-width block in the details header.
//  Renders nothing unless health is .unreachable.
//

import SwiftUI

struct SensorHealthBanner: View {
    enum Style { case line, banner }

    let device: FlowerDeviceDTO
    let health: SensorHealth
    let style: Style
    /// Shown as "Tell the app where this sensor is" when the verdict is
    /// unconfirmed, the device has no location and other sensors exist.
    var onSetLocation: (() -> Void)? = nil

    var body: some View {
        if case .unreachable(let since, let lastKnown, let confirmed) = health {
            let days = SensorHealth.daysSilent(since: since, now: Date())
            switch style {
            case .line:
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    // Short form: the row is one line wide and the battery sits next to it
                    Text(confirmed ? L10n.SensorHealth.Banner.Confirmed.line(days)
                                   : L10n.SensorHealth.Banner.Unconfirmed.title(days))
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundColor(.red)
                .layoutPriority(1)

            case .banner:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(confirmed ? L10n.SensorHealth.Banner.Confirmed.title(days)
                                       : L10n.SensorHealth.Banner.Unconfirmed.title(days))
                            .fontWeight(.semibold)
                    }
                    Text(explanation(confirmed: confirmed))
                        .font(.subheadline)
                    if let lastKnown {
                        Text(L10n.SensorHealth.Banner.lastKnown(lastKnown))
                            .font(.caption)
                    }
                    if !confirmed, device.location == nil, let onSetLocation {
                        Button(L10n.SensorHealth.Banner.setLocation, action: onSetLocation)
                            .font(.caption)
                            .fontWeight(.medium)
                            .tint(.red)
                    }
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }

    private func explanation(confirmed: Bool) -> String {
        switch (confirmed, device.location) {
        case (true, let location?): return L10n.SensorHealth.Banner.Confirmed.textLocation(location)
        case (true, nil): return L10n.SensorHealth.Banner.Confirmed.text
        case (false, let location?): return L10n.SensorHealth.Banner.Unconfirmed.textLocation(location)
        case (false, nil): return L10n.SensorHealth.Banner.Unconfirmed.text
        }
    }
}

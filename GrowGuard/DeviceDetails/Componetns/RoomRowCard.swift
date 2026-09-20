//
//  RoomRowCard.swift
//  GrowGuard
//
//  The one room row on the details page: where the plant stands and who
//  shares the room. Tapping opens the room picker.
//

import SwiftUI

struct RoomRowCard: View {
    let device: FlowerDeviceDTO
    /// Names of the other plants in the same room (RoomCatalog.companions)
    let companions: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: RoomCatalog.symbolName(for: device.location))
                    .font(.title3)
                    .foregroundColor(.green)
                    .frame(width: 44, height: 44)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Room.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(device.location ?? L10n.Room.choose)
                        .font(.headline)
                        .foregroundColor(device.location == nil ? .green : .primary)
                        .lineLimit(1)
                    if device.location != nil {
                        Text(RoomText.companions(companions))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same material and shadow as the sibling cards on the details
            // page; systemBackground would be invisible there in dark mode.
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

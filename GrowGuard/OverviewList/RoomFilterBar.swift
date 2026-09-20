//
//  RoomFilterBar.swift
//  GrowGuard
//
//  One slim, horizontally scrolling row of room chips under "My Plants"
//  (spec docs/superpowers/specs/2026-09-20-rooms-ui-design.md).
//

import SwiftUI

struct RoomFilterBar: View {
    let catalog: RoomCatalog
    @Binding var selection: RoomFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.all, title: L10n.Room.all, count: catalog.totalCount, alert: false)
                ForEach(catalog.rooms) { room in
                    chip(.room(room.name ?? ""), title: room.name ?? "", count: room.plantCount, alert: room.hasSilentSensor)
                }
                if let unassigned = catalog.unassigned {
                    chip(.unassigned, title: L10n.Room.noRoom, count: unassigned.plantCount, alert: unassigned.hasSilentSensor)
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ filter: RoomFilter, title: String, count: Int, alert: Bool) -> some View {
        let isOn = selection == filter
        return Button {
            selection = filter
        } label: {
            HStack(spacing: 6) {
                if alert {
                    Circle()
                        .fill(isOn ? Color.white : Color.red)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .fontWeight(.medium)
                Text("\(count)")
                    .foregroundColor(isOn ? .white.opacity(0.8) : .secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundColor(isOn ? .white : .primary)
            .background(isOn ? Color.green : Color(.systemBackground))
            .clipShape(Capsule())
            // In dark mode systemBackground is black on a black page: without
            // the hairline an inactive chip has no visible edge at all.
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(isOn ? 0 : 0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

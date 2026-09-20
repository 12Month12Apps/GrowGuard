//
//  RoomPickerView.swift
//  GrowGuard
//
//  Pick a room from the ones that exist, clear it, or create a new one
//  (spec docs/superpowers/specs/2026-09-20-rooms-ui-design.md). The search
//  field doubles as the input for a new name. All room logic lives in
//  RoomCatalog; this view only renders it.
//

import SwiftUI

/// Count and companion copy shared by the picker and the details room row
enum RoomText {
    static func plants(_ count: Int) -> String {
        count == 1 ? L10n.Room.Plants.one : L10n.Room.Plants.other(count)
    }

    static func sensors(_ count: Int) -> String {
        count == 1 ? L10n.Room.Sensors.one : L10n.Room.Sensors.other(count)
    }

    static func companions(_ names: [String]) -> String {
        guard let first = names.first else { return L10n.Room.Companions.none }
        return names.count == 1
            ? L10n.Room.Companions.one(first)
            : L10n.Room.Companions.more(first, names.count - 1)
    }
}

struct RoomPickerView: View {
    @Binding var selection: String?
    let devices: [FlowerDeviceDTO]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var catalog: RoomCatalog { RoomCatalog(devices: devices, now: Date()) }

    var body: some View {
        let catalog = self.catalog
        let matches = catalog.search(query)
        let suggestions = catalog.suggestions(for: query)

        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(L10n.Room.Picker.search, text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(submit)
                }
            }

            if let newName = catalog.nameToCreate(from: query) {
                Section {
                    Button { pick(newName) } label: {
                        row(symbol: "plus.circle",
                            title: L10n.Room.Picker.create(newName),
                            subtitle: L10n.Room.Picker.createHint,
                            tint: .green,
                            isSelected: false)
                    }
                }
            }

            if !matches.isEmpty {
                Section(header: Text(L10n.Room.Picker.yourRooms)) {
                    ForEach(matches) { room in
                        Button { pick(room.name) } label: {
                            row(symbol: RoomCatalog.symbolName(for: room.name),
                                title: room.name ?? L10n.Room.none,
                                subtitle: "\(RoomText.plants(room.plantCount)) · \(RoomText.sensors(room.sensorCount))",
                                tint: .green,
                                isSelected: room.name == selection)
                        }
                    }
                }
            }

            if query.isEmpty {
                Section {
                    Button { pick(nil) } label: {
                        row(symbol: RoomCatalog.symbolName(for: nil),
                            title: L10n.Room.none,
                            subtitle: nil,
                            tint: .secondary,
                            isSelected: selection == nil)
                    }
                }
            }

            if !suggestions.isEmpty {
                Section(header: Text(L10n.Room.Picker.suggestions)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                // .bordered keeps each chip its own tap target inside a List row
                                Button(suggestion) { pick(suggestion) }
                                    .buttonStyle(.bordered)
                                    .tint(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text(L10n.Device.locationFooter)
            }
        }
        .navigationTitle(L10n.Room.title)
        .navigationBarTitleDisplayMode(.large)
    }

    /// Return key: take an exact existing room, else create, else do nothing
    private func submit() {
        if let existing = catalog.room(named: query) {
            pick(existing.name)
        } else if let newName = catalog.nameToCreate(from: query) {
            pick(newName)
        }
    }

    private func pick(_ name: String?) {
        selection = FlowerDeviceDTO.normalizeLocation(name)
        dismiss()
    }

    private func row(symbol: String, title: String, subtitle: String?, tint: Color, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Form row that opens the picker. Used by the device settings and the
/// add-device form; the chosen value is saved together with the form.
struct RoomFormSection: View {
    @Binding var location: String?
    let devices: [FlowerDeviceDTO]

    var body: some View {
        Section {
            NavigationLink {
                RoomPickerView(selection: $location, devices: devices)
            } label: {
                HStack {
                    Image(systemName: RoomCatalog.symbolName(for: location))
                        .foregroundColor(.green)
                        .frame(width: 30)
                    Text(L10n.Room.title)
                    Spacer()
                    Text(location ?? L10n.Room.none)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text(L10n.Device.locationFooter)
        }
    }
}

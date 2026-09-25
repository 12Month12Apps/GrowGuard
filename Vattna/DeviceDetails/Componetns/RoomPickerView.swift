//
//  RoomPickerView.swift
//  Vattna
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
        guard let first = names.first else { return L10n.Room.Companions.alone }
        return names.count == 1
            ? L10n.Room.Companions.one(first)
            : L10n.Room.Companions.more(first, names.count - 1)
    }
}

// @MainActor: the edit helpers below drive the main-actor RoomEditor and
// write @State / the selection binding straight after.
@MainActor
struct RoomPickerView: View {
    @Binding var selection: String?
    let devices: [FlowerDeviceDTO]
    /// Lets the host refresh its own copy after a room was renamed or deleted
    var onRoomsChanged: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Reloaded after an edit; nil until then (use the host's snapshot)
    @State private var reloadedDevices: [FlowerDeviceDTO]?
    @State private var editingRoom: Room?
    @State private var roomPendingDeletion: Room?
    @State private var showEditError = false

    private var currentDevices: [FlowerDeviceDTO] { reloadedDevices ?? devices }

    private var catalog: RoomCatalog { RoomCatalog(devices: currentDevices, now: Date()) }

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
                        HStack(spacing: 4) {
                            Button { pick(room.name) } label: {
                                row(symbol: RoomCatalog.symbolName(for: room.name),
                                    title: room.name ?? L10n.Room.noRoom,
                                    subtitle: "\(RoomText.plants(room.plantCount)) · \(RoomText.sensors(room.sensorCount))",
                                    tint: .green,
                                    isSelected: room.name == selection)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button { editingRoom = room } label: { Label(L10n.Room.Action.edit, systemImage: "pencil") }
                                Button(role: .destructive) { roomPendingDeletion = room } label: { Label(L10n.Alert.delete, systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.Room.Action.more)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { roomPendingDeletion = room } label: { Label(L10n.Alert.delete, systemImage: "trash") }
                            Button { editingRoom = room } label: { Label(L10n.Room.Action.edit, systemImage: "pencil") }
                                .tint(.blue)
                        }
                    }
                }
            }

            if query.isEmpty {
                Section {
                    Button { pick(nil) } label: {
                        row(symbol: RoomCatalog.symbolName(for: nil),
                            title: L10n.Room.noRoom,
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
        .sheet(item: $editingRoom) { room in
            RoomEditView(room: room, devices: currentDevices) { newName in
                Task { await roomChanged(from: room.name, to: newName) }
            }
        }
        // An alert, not a confirmationDialog: on iOS 26 the dialog is an
        // anchored popover that lands over the navigation bar and hides its
        // own Cancel button, leaving a destructive action without a way back.
        // `presenting:` hands the room to the action and the message, so
        // neither reads state that the dismissal has already reset.
        .alert(L10n.Room.Edit.DeleteConfirm.title(roomPendingDeletion?.name ?? ""),
               isPresented: Binding(get: { roomPendingDeletion != nil }, set: { if !$0 { roomPendingDeletion = nil } }),
               presenting: roomPendingDeletion) { room in
            Button(L10n.Room.Edit.delete, role: .destructive) {
                if let name = room.name {
                    Task { await deleteRoom(named: name) }
                }
            }
            Button(L10n.Alert.cancel, role: .cancel) { /* the alert dismisses itself */ }
        } message: { room in
            Text(room.plantCount == 1 ? L10n.Room.Edit.DeleteConfirm.one
                                      : L10n.Room.Edit.DeleteConfirm.other(room.plantCount))
        }
        .alert(L10n.Alert.error, isPresented: $showEditError) {
            Button(L10n.Alert.ok) { /* the alert dismisses itself */ }
        } message: {
            Text(L10n.Room.Edit.failed)
        }
    }

    /// A failed delete still reloads: some plants may already have moved, and
    /// the list has to show what is really there. The selection stays on the
    /// room, which still exists.
    private func deleteRoom(named name: String) async {
        do {
            _ = try await RoomEditor().delete(name)
            await roomChanged(from: name, to: nil)
        } catch {
            showEditError = true
            await roomChanged(from: name, to: name)
        }
    }

    /// A room was renamed (new name) or deleted (nil): keep the selection on
    /// it, reload the list, tell the host. The picker stays open.
    private func roomChanged(from oldName: String?, to newName: String?) async {
        if selection == oldName {
            selection = newName
        }
        reloadedDevices = try? await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
        await onRoomsChanged?()
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
    /// Forwarded to the picker: the host refreshes after a rename or delete
    var onRoomsChanged: (() async -> Void)? = nil

    var body: some View {
        Section {
            NavigationLink {
                RoomPickerView(selection: $location, devices: devices, onRoomsChanged: onRoomsChanged)
            } label: {
                HStack {
                    Image(systemName: RoomCatalog.symbolName(for: location))
                        .foregroundColor(.green)
                        .frame(width: 30)
                    Text(L10n.Room.title)
                    Spacer()
                    Text(location ?? L10n.Room.noRoom)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text(L10n.Device.locationFooter)
        }
    }
}

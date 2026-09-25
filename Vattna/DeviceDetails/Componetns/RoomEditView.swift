//
//  RoomEditView.swift
//  Vattna
//
//  Rename a room, choose its icon, delete it. Presented as a sheet from the
//  room picker. All data work is RoomEditor / RoomIconStore.
//

import SwiftUI

// @MainActor: the stored editor/icon store and the init's store lookup are
// main-actor state, and a view's default property values are not isolated
// on their own.
@MainActor
struct RoomEditView: View {
    let room: Room
    let devices: [FlowerDeviceDTO]
    /// The room's name after the change; nil when it was deleted
    let onFinished: (String?) -> Void

    private let editor = RoomEditor()
    private let icons = RoomIconStore.shared

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// nil = automatic
    @State private var symbol: String?
    @State private var mergeTarget: String?
    @State private var showDeleteConfirm = false
    @State private var showError = false
    @State private var isWorking = false

    private let originalName: String
    private let originalSymbol: String?

    init(room: Room, devices: [FlowerDeviceDTO], onFinished: @escaping (String?) -> Void) {
        self.room = room
        self.devices = devices
        self.onFinished = onFinished
        let roomName = room.name ?? ""
        let stored = RoomIconStore.shared.symbol(for: roomName)
        self.originalName = roomName
        self.originalSymbol = stored
        _name = State(initialValue: roomName)
        _symbol = State(initialValue: stored)
    }

    private var members: [FlowerDeviceDTO] {
        devices.filter { $0.location == originalName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trimmedName: String? { FlowerDeviceDTO.normalizeLocation(name) }

    private var previewSymbol: String {
        symbol ?? RoomCatalog.defaultSymbolName(for: trimmedName ?? originalName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(L10n.Room.Edit.name)) {
                    HStack(spacing: 12) {
                        Image(systemName: previewSymbol)
                            .foregroundColor(.green)
                            .frame(width: 34, height: 34)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Circle())
                        TextField(L10n.Room.Edit.name, text: $name)
                            .autocorrectionDisabled()
                    }
                }

                Section(header: Text(L10n.Room.Edit.icon)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 5), spacing: 10) {
                        iconCell(symbolName: nil)
                        ForEach(RoomIconStore.choices, id: \.self) { choice in
                            iconCell(symbolName: choice)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !members.isEmpty {
                    Section(header: Text(L10n.Room.Edit.plants)) {
                        ForEach(members) { plant in
                            Label(plant.name, systemImage: plant.isSensor ? "sensor.fill" : "leaf.fill")
                        }
                    }
                }

                Section {
                    Button(L10n.Room.Edit.delete, role: .destructive) { showDeleteConfirm = true }
                }
            }
            .disabled(isWorking)
            .navigationTitle(L10n.Room.Edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Alert.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Alert.save) { Task { await save(confirmedTarget: nil) } }
                        .disabled(trimmedName == nil || isWorking)
                }
            }
            // `presenting:` hands the confirmed spelling to the action, so the
            // rename lands in exactly the room the alert named — the dismissal
            // resetting `mergeTarget` cannot race the write.
            .alert(L10n.Room.Edit.MergeConfirm.title(mergeTarget ?? ""),
                   isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
                   presenting: mergeTarget) { target in
                Button(L10n.Alert.cancel, role: .cancel) { mergeTarget = nil }
                Button(L10n.Room.Edit.merge) { Task { await save(confirmedTarget: target) } }
            } message: { _ in
                Text(L10n.Room.Edit.MergeConfirm.message)
            }
            // An alert, not a confirmationDialog: on iOS 26 the dialog is an
            // anchored popover that lands on top of the icon grid and hides
            // its own Cancel button.
            .alert(L10n.Room.Edit.DeleteConfirm.title(originalName), isPresented: $showDeleteConfirm) {
                Button(L10n.Room.Edit.delete, role: .destructive) { Task { await delete() } }
                Button(L10n.Alert.cancel, role: .cancel) { /* the alert dismisses itself */ }
            } message: {
                Text(members.count == 1 ? L10n.Room.Edit.DeleteConfirm.one
                                        : L10n.Room.Edit.DeleteConfirm.other(members.count))
            }
            .alert(L10n.Alert.error, isPresented: $showError) {
                Button(L10n.Alert.ok) { /* the alert dismisses itself */ }
            } message: {
                Text(L10n.Room.Edit.failed)
            }
        }
    }

    /// One cell of the icon grid; `nil` is "Automatic"
    private func iconCell(symbolName: String?) -> some View {
        let isSelected = symbol == symbolName
        return Button {
            symbol = symbolName
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbolName ?? RoomCatalog.defaultSymbolName(for: trimmedName ?? originalName))
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .foregroundColor(isSelected ? .white : .green)
                    .background(isSelected ? Color.green : Color.green.opacity(0.15))
                    .clipShape(Circle())
                if symbolName == nil {
                    Text(L10n.Room.Edit.iconAutomatic)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .buttonStyle(.plain)
        // Same cell height with or without the "Automatic" caption, so the grid rows line up
        .frame(height: 62, alignment: .top)
        .accessibilityLabel(symbolName ?? L10n.Room.Edit.iconAutomatic)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `confirmedTarget` is the merge the user just agreed to in the alert;
    /// nil means "ask first if this turns out to be a merge".
    private func save(confirmedTarget: String?) async {
        guard let newName = trimmedName else {
            showError = true
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            if confirmedTarget == nil,
               let target = try await editor.mergeTarget(renaming: originalName, to: newName) {
                mergeTarget = target
                return
            }
            let outcome = try await editor.rename(originalName, to: newName, mergingInto: confirmedTarget)
            mergeTarget = nil
            let finalName: String
            let isMerge: Bool
            switch outcome {
            case .invalid:
                showError = true
                return
            case .unchanged:
                finalName = originalName
                isMerge = false
            case .renamed(let to, _):
                finalName = to
                isMerge = false
            case .merged(let into, _):
                finalName = into
                isMerge = true
            }
            // A merge dissolves this room into another one: `originalSymbol`
            // is the dissolved room's icon, so comparing against it here
            // would write over — or wipe — the target's own look.
            if !isMerge, symbol != originalSymbol {
                icons.setSymbol(symbol, for: finalName)
            }
            onFinished(finalName)
            dismiss()
        } catch {
            showError = true
        }
    }

    private func delete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await editor.delete(originalName)
            onFinished(nil)
            dismiss()
        } catch {
            showError = true
        }
    }
}

//
//  LocationField.swift
//  GrowGuard
//
//  "Location" form section: one text field plus tappable chips with the
//  locations other devices already use. The chips are the whole
//  de-duplication mechanism ("Balcony" vs "balcony").
//

import SwiftUI

struct LocationField: View {
    @Binding var location: String
    let suggestions: [String]

    private var chips: [String] {
        suggestions.filter { $0 != location.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var body: some View {
        Section {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.blue)
                    .frame(width: 30)
                TextField(L10n.Device.location, text: $location)
                    .autocorrectionDisabled()
            }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Button(chip) { location = chip }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.Device.location)
        } footer: {
            Text(L10n.Device.locationFooter)
        }
    }
}

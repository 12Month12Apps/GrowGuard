//
//  NavigationLink.swift
//  GrowGuard
//
//  Created by veitprogl on 22.03.25.
//
import SwiftUI

struct NavigationLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(.systemGray3))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // This ensures the entire area is clickable
        .background(configuration.isPressed ? Color(.systemGray5) : Color.clear)
    }
}

extension Button {
    func navigationLinkStyle() -> some View {
        self.buttonStyle(NavigationLinkButtonStyle())
    }
}

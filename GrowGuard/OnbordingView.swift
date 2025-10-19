//
//  OnbordingView.swift
//  GrowGuard
//
//  Created by veitprogl on 28.02.25.
//

import SwiftUI

struct OnbordingView: View {
    @Binding var selectedTab : NavigationTabs
    @Binding var showOnboarding: Bool

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.green.opacity(0.1), Color.blue.opacity(0.05)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer()
                        .frame(height: 40)

                    // App logo
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .cornerRadius(32)
                        .shadow(color: Color.black.opacity(0.1), radius: 16, x: 0, y: 4)

                    // Welcome section
                    VStack(spacing: 12) {
                        Text(L10n.Onboarding.welcome)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)

                        Text(L10n.Onboarding.description)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 32)
                    }

                    // Features section
                    VStack(spacing: 20) {
                        Text(L10n.Onboarding.features)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.top, 8)

                        VStack(spacing: 16) {
                            FeatureRow(
                                icon: "sensor.fill",
                                iconColor: .blue,
                                text: L10n.Onboarding.feature1
                            )

                            FeatureRow(
                                icon: "chart.xyaxis.line",
                                iconColor: .green,
                                text: L10n.Onboarding.feature2
                            )

                            FeatureRow(
                                icon: "bell.badge.fill",
                                iconColor: .orange,
                                text: L10n.Onboarding.feature3
                            )
                        }
                        .padding(.horizontal, 24)
                    }

                    // Get started text
                    Text(L10n.Onboarding.getStarted)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)

                    // CTA Button
                    Button(action: {
                        let defaults = UserDefaults.standard
                        defaults.setValue(true, forKey: L10n.Userdefaults.showOnboarding)
                        selectedTab = .addDevice
                        self.showOnboarding = false
                        print("Add new device")
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "leaf.fill")
                                .font(.headline)
                            Text(L10n.Onboarding.addDevice)
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.green, Color.green.opacity(0.8)]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: Color.green.opacity(0.3), radius: 12, x: 0, y: 6)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                    Spacer()
                        .frame(height: 40)
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(iconColor)
            }

            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

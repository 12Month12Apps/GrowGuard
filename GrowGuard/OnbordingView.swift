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
        NavigationView {
            ScrollView {
                VStack {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .cornerRadius(19)
                    
                    Text(L10n.Onboarding.welcome)
                        .font(.title)
                        .padding()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .bold()
                    
                    Text(L10n.Onboarding.description)
                        .padding()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    Text(L10n.Onboarding.features)
                        .padding()
                        .bold()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    Text(L10n.Onboarding.feature1)
                    Text(L10n.Onboarding.feature2)
                    Text(L10n.Onboarding.feature3)
                    
                    Text(L10n.Onboarding.getStarted)
                        .padding()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    Button(action: {
                        let defaults = UserDefaults.standard
                        defaults.setValue(true, forKey: L10n.Userdefaults.showOnboarding)
                        selectedTab = .addDevice
                        self.showOnboarding = false
                        print("Add new device")
                    }) {
                        Text(L10n.Onboarding.addDevice)
                    }
                }
            }
        }
    }
}

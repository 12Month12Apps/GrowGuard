//
//  OnbordingView.swift
//  GrowGuard
//
//  Created by veitprogl on 28.02.25.
//

import SwiftUI

struct OnbordingView: View {
    var body: some View {
        VStack {
            
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .cornerRadius(19)
            
            Text("Welcome to GrowGuard")
                .font(.title)
                .padding()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .bold()
            
            Text("This app is designed to help you take care of your plants.")
                .padding()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Text("Features")
                .padding()
                .bold()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Text("See your current envoirment conditions of your plants")
            Text("Get notified when something is wrong")
            Text("Add multiple devices to monitor multiple plants")

            Text("To get started, please add a new device.")
                .padding()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Button(action: {
                print("Add new device")
            }) {
                Text("Add Device")
            }
        }
    }
}

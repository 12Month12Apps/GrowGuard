//
//  CircularProgress.swift
//  GrowGuard
//
//  Created by veitprogl on 13.06.25.
//

import SwiftUI

struct CircularProgressView: View {
    let progress: Double
    let color: Color
    let icon: Image
    
    var body: some View {
        ZStack {
            
            VStack(spacing: 5) {
                icon
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(color)
        
                
                Text("\(progress * 100, specifier: "%.0f")")
                    .font(.caption)
            }.padding(17)
            
            Circle()
                .stroke(
                    color.opacity(0.5),
                    lineWidth: 15
                )
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: 15,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)

        }
    }
}


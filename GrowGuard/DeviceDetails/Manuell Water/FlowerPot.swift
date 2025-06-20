//
//  FlowerPot.swift
//  GrowGuard
//
//  Created by veitprogl on 18.06.25.
//
import SwiftUI

struct FlowerPotShape: Shape {
    var topDiameter: CGFloat
    var bottomDiameter: CGFloat
    var height: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let scale = rect.height / height
        let topWidth = topDiameter * scale
        let bottomWidth = bottomDiameter * scale

        let xOffset = (rect.width - topWidth) / 2
        let bottomXOffset = (rect.width - bottomWidth) / 2

        path.move(to: CGPoint(x: xOffset, y: 0)) // oben links
        path.addLine(to: CGPoint(x: xOffset + topWidth, y: 0)) // oben rechts
        path.addLine(to: CGPoint(x: bottomXOffset + bottomWidth, y: rect.height)) // unten rechts
        path.addLine(to: CGPoint(x: bottomXOffset, y: rect.height)) // unten links
        path.closeSubpath()

        return path
    }
}

struct WaveShape: Shape {
    var fillLevel: CGFloat // 0.0 ... 1.0
    var waveHeight: CGFloat = 10
    var waveLength: CGFloat = 1.5
    var phase: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width + 30
        let height = rect.height

        let yOffset = height * (1 - fillLevel)

        path.move(to: CGPoint(x: 0, y: height))

        // Wellenlinie oben
        for x in stride(from: 0, through: width, by: 1) {
            let relativeX = x / width
            let sine = sin((relativeX + phase) * .pi * waveLength)
            let y = yOffset + sine * waveHeight
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()

        return path
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fillLevel, phase) }
        set {
            fillLevel = newValue.first
            phase = newValue.second
        }
    }
}


struct WaterFillPotView: View {
    @Binding var fill: CGFloat // 0.0 ... 1.0
    @State private var wavePhase: CGFloat = 0

    var body: some View {
        let topDiameter: CGFloat = 20
        let bottomDiameter: CGFloat = 12
        let height: CGFloat = 18

        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Topfumriss
                FlowerPotShape(
                    topDiameter: topDiameter,
                    bottomDiameter: bottomDiameter,
                    height: height
                )
                .stroke(Color.brown, lineWidth: 5)
                    
                
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let speed: Double = 0.1 // kleiner = langsamer
                    let phase = CGFloat((time * speed).truncatingRemainder(dividingBy: 1))

                    FlowerPotShape(
                        topDiameter: topDiameter,
                        bottomDiameter: bottomDiameter,
                        height: height
                    )
                    .fill(Color.blue.opacity(0.6))
                    .mask(
                        WaveShape(
                            fillLevel: fill,
                            waveHeight: 6,
                            waveLength: 5,
                            phase: phase
                        )
                        .offset(x: -15)
                    )
                    .padding(2)
                }
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 1.5)) {
                        fill = fill == 1 ? 0 : 1 // Toggle fill level on tap
                    }
                }
                
                VStack(alignment: .center) {
                    Text(fill, format: .percent)
                        .bold()
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .aspectRatio(1, contentMode: .fit)
    }
}

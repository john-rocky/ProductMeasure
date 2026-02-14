//
//  StatusVignetteView.swift
//  ProductMeasure
//

import SwiftUI
import UIKit

/// Full-screen radial gradient vignette that flashes green (OK) or red (NG)
/// around the screen edges when measurement status is revealed.
struct StatusVignetteView: View {
    let isNG: Bool
    @Binding var isVisible: Bool

    @State private var opacity: Double = 0

    private var vignetteColor: Color {
        isNG ? PMTheme.red : PMTheme.cyan
    }

    var body: some View {
        ZStack {
            // Thick edge band — high opacity at screen border
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.35),
                    .init(color: vignetteColor.opacity(0.30), location: 0.6),
                    .init(color: vignetteColor.opacity(0.65), location: 0.85),
                    .init(color: vignetteColor.opacity(0.85), location: 1.0),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: UIScreen.main.bounds.height * 0.6
            )

            // Corner intensifiers — extra glow in corners
            Rectangle()
                .fill(vignetteColor.opacity(0.25))
                .mask(
                    LinearGradient(
                        colors: [vignetteColor, .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            Rectangle()
                .fill(vignetteColor.opacity(0.25))
                .mask(
                    LinearGradient(
                        colors: [vignetteColor, .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                )
        }
        .opacity(opacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            if isNG {
                runDoublePulse()
            } else {
                runSinglePulse()
            }
        }
    }

    private func runSinglePulse() {
        withAnimation(.easeIn(duration: 0.2)) {
            opacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            isVisible = false
        }
    }

    private func runDoublePulse() {
        // First pulse
        withAnimation(.easeIn(duration: 0.15)) {
            opacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.2)) {
                opacity = 0.1
            }
        }
        // Second pulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeIn(duration: 0.15)) {
                opacity = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 1.2)) {
                opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            isVisible = false
        }
    }
}

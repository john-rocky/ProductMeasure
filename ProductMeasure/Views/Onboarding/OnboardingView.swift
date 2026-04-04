//
//  OnboardingView.swift
//  SnapMeasure
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0

    private let steps: [(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey)] = [
        ("hand.tap.fill", "Tap to Measure", "Point at any object and tap to instantly measure its dimensions with LiDAR."),
        ("doc.text.viewfinder", "Scan Labels", "Read barcodes and shipping labels — attach label data to measurements."),
        ("square.and.arrow.up", "Save & Export", "Review your measurements, add notes, and export as CSV or JSON."),
    ]

    var body: some View {
        ZStack {
            PMTheme.surfaceDark
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // App title
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 48))
                        .foregroundColor(PMTheme.green)

                    Text("SnapMeasure")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    Text("LiDAR One-Tap 3D Measurement")
                        .font(PMTheme.mono(14))
                        .foregroundColor(PMTheme.textSecondary)
                }

                Spacer()

                // Tutorial step
                VStack(spacing: 16) {
                    Image(systemName: steps[currentPage].icon)
                        .font(.system(size: 44))
                        .foregroundColor(PMTheme.green)

                    Text(steps[currentPage].title)
                        .font(PMTheme.mono(18, weight: .bold))
                        .foregroundColor(.white)

                    Text(steps[currentPage].subtitle)
                        .font(PMTheme.mono(13))
                        .foregroundColor(PMTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(.horizontal, 32)

                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? PMTheme.green : PMTheme.textDimmed)
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                // Button
                Button(action: {
                    if currentPage < steps.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        hasCompletedOnboarding = true
                        dismiss()
                    }
                }) {
                    Text(currentPage < steps.count - 1 ? "Next" : "Get Started")
                        .font(PMTheme.mono(16, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(PMTheme.green)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}

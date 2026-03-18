//
//  OnboardingView.swift
//  SnapMeasure
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage("appMode") private var appMode: AppMode = .measure
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.dismiss) private var dismiss

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

                // Mode selection cards
                VStack(spacing: 12) {
                    Text("Choose your mode")
                        .font(PMTheme.mono(13, weight: .bold))
                        .foregroundColor(PMTheme.cyan)

                    ForEach(AppMode.allCases, id: \.self) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: appMode == mode,
                            onSelect: { appMode = mode }
                        )
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // Start button
                Button(action: {
                    hasCompletedOnboarding = true
                    dismiss()
                }) {
                    Text("Get Started")
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

// MARK: - Mode Card

private struct ModeCard: View {
    let mode: AppMode
    let isSelected: Bool
    let onSelect: () -> Void

    private var icon: String {
        switch mode {
        case .warehouse: return "shippingbox"
        case .shipping: return "shippingbox.and.arrow.backward"
        case .measure: return "ruler"
        case .labelOnly: return "doc.text.viewfinder"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? PMTheme.green : PMTheme.cyan)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(PMTheme.mono(14, weight: .bold))
                        .foregroundColor(.white)

                    Text(mode.description)
                        .font(PMTheme.mono(11))
                        .foregroundColor(PMTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(PMTheme.green)
                }
            }
            .padding(14)
            .background(isSelected ? PMTheme.green.opacity(0.1) : PMTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? PMTheme.green.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
    }
}

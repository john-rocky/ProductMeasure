//
//  MultiScanOverlay.swift
//  ProductMeasure
//
//  UI overlay for multi-angle scanning mode with progress indicators
//  and scan guidance.
//

import SwiftUI

/// Overlay view for multi-scan mode with progress and controls
struct MultiScanOverlay: View {
    @ObservedObject var sessionManager: MultiScanSessionManager
    let unit: MeasurementUnit
    let onAddScan: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var showingQualityDetails = false

    var body: some View {
        VStack(spacing: 0) {
            // Top info bar
            topInfoBar

            Spacer()

            // Bottom control panel
            bottomControlPanel
        }
    }

    // MARK: - Top Info Bar

    private var topInfoBar: some View {
        HStack(spacing: 16) {
            // Scan count badge
            scanCountBadge

            Spacer()

            // Coverage indicator
            coverageIndicator
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var scanCountBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .foregroundColor(sessionManager.hasEnoughScans ? .green : .orange)

            Text("\(sessionManager.scanCount) / \(MultiScanSessionManager.minimumScansRequired)")
                .font(.headline)
                .monospacedDigit()

            Text("scans")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray6))
        )
    }

    private var coverageIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Text("Coverage")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(Int(sessionManager.coverageProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.systemGray5))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(coverageColor)
                        .frame(width: geometry.size.width * CGFloat(sessionManager.coverageProgress))
                }
            }
            .frame(width: 80, height: 6)
        }
    }

    private var coverageColor: Color {
        switch sessionManager.coverageProgress {
        case 0.8...: return .green
        case 0.5..<0.8: return .yellow
        default: return .orange
        }
    }

    // MARK: - Bottom Control Panel

    private var bottomControlPanel: some View {
        VStack(spacing: 16) {
            // Stats row
            statsRow

            // Guidance text
            guidanceText

            // Action buttons
            actionButtons
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            // Point count
            statItem(
                icon: "circle.grid.3x3.fill",
                value: formatPointCount(sessionManager.accumulatedPointCount),
                label: "Points"
            )

            Divider()
                .frame(height: 40)

            // Last scan points
            statItem(
                icon: "plus.circle.fill",
                value: formatPointCount(sessionManager.currentScanPointCount),
                label: "Last scan"
            )

            Divider()
                .frame(height: 40)

            // Quality score
            Button(action: { showingQualityDetails.toggle() }) {
                let quality = sessionManager.evaluateScanQuality()
                statItem(
                    icon: "star.fill",
                    value: String(format: "%.0f%%", quality.overallScore * 100),
                    label: "Quality",
                    valueColor: qualityScoreColor(quality.overallScore)
                )
            }
            .popover(isPresented: $showingQualityDetails) {
                qualityDetailsView
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(
        icon: String,
        value: String,
        label: String,
        valueColor: Color = .primary
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(valueColor)
            }

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var guidanceText: some View {
        Group {
            if !sessionManager.hasEnoughScans {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)

                    Text("\(sessionManager.additionalScansNeeded) more scan(s) needed for accurate volume")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            } else if let suggestion = sessionManager.suggestNextCameraPosition() {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)

                    Text(suggestion)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            } else if sessionManager.coverageProgress >= 0.8 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)

                    Text("Good coverage! Ready to calculate volume")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)

                    Text("Move to a different angle and add more scans")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Cancel button
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            // Add Scan button
            Button(action: {
                print("[MultiScanOverlay] Add Scan button pressed, state: \(sessionManager.state)")
                onAddScan()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.viewfinder")
                    Text("Add Scan")
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)

            // Finish button
            Button(action: onFinish) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Calculate")
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!sessionManager.hasEnoughScans)
        }
    }

    // MARK: - Quality Details Popover

    private var qualityDetailsView: some View {
        let quality = sessionManager.evaluateScanQuality()

        return VStack(alignment: .leading, spacing: 16) {
            Text("Scan Quality Details")
                .font(.headline)

            VStack(spacing: 12) {
                qualityDetailRow(
                    label: "Coverage",
                    value: quality.coverageScore,
                    description: "Percentage of object surface scanned"
                )

                qualityDetailRow(
                    label: "Point Density",
                    value: quality.densityScore,
                    description: "Number of captured points"
                )

                qualityDetailRow(
                    label: "Angle Variety",
                    value: quality.angleVarietyScore,
                    description: "Diversity of viewing angles"
                )
            }

            if let recommendation = quality.recommendation {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)

                    Text(recommendation)
                        .font(.subheadline)
                }
            }
        }
        .padding(20)
        .frame(width: 280)
    }

    private func qualityDetailRow(label: String, value: Float, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(Int(value * 100))%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(qualityScoreColor(value))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.systemGray5))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(qualityScoreColor(value))
                        .frame(width: geometry.size.width * CGFloat(value))
                }
            }
            .frame(height: 6)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatPointCount(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1fK", Float(count) / 1000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Float(count) / 1000)
        } else {
            return "\(count)"
        }
    }

    private func qualityScoreColor(_ score: Float) -> Color {
        switch score {
        case 0.8...: return .green
        case 0.5..<0.8: return .yellow
        default: return .orange
        }
    }
}

// MARK: - Processing View

struct MultiScanProcessingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)

            Text(message)
                .font(.headline)
                .foregroundColor(.white)
        }
        .padding(32)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Scan Mode Toggle

struct ScanModeToggle: View {
    @Binding var isMultiScanMode: Bool
    let disabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(
                title: "Single",
                icon: "viewfinder",
                isSelected: !isMultiScanMode
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isMultiScanMode = false
                }
            }

            toggleButton(
                title: "Multi",
                icon: "camera.on.rectangle.fill",
                isSelected: isMultiScanMode
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isMultiScanMode = true
                }
            }
        }
        .background(Color(.systemGray5))
        .clipShape(Capsule())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func toggleButton(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)

                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Preview

#Preview("Multi-Scan Overlay - Scanning") {
    ZStack {
        Color.gray.ignoresSafeArea()

        MultiScanOverlay(
            sessionManager: {
                let manager = MultiScanSessionManager()
                return manager
            }(),
            unit: .centimeters,
            onAddScan: {},
            onFinish: {},
            onCancel: {}
        )
    }
}

#Preview("Scan Mode Toggle") {
    VStack(spacing: 20) {
        ScanModeToggle(isMultiScanMode: .constant(false), disabled: false)
        ScanModeToggle(isMultiScanMode: .constant(true), disabled: false)
        ScanModeToggle(isMultiScanMode: .constant(false), disabled: true)
    }
    .padding()
}

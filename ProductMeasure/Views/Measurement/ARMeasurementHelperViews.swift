//
//  ARMeasurementHelperViews.swift
//  ProductMeasure
//

import SwiftUI

// MARK: - Status Bar

struct StatusBar: View {
    let trackingMessage: String
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
                Text("Processing...")
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            } else {
                Image(systemName: trackingStatusIcon)
                    .foregroundColor(trackingStatusColor)
                    .symbolEffect(.pulse, options: .repeating, value: trackingMessage == "Ready to measure")
                Text(trackingMessage)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(PMTheme.cyan.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private var trackingStatusIcon: String {
        if trackingMessage == "Ready to measure" {
            return "checkmark.circle.fill"
        } else if trackingMessage.contains("not") || trackingMessage.contains("Not") {
            return "exclamationmark.triangle.fill"
        } else {
            return "arrow.triangle.2.circlepath"
        }
    }

    private var trackingStatusColor: Color {
        if trackingMessage == "Ready to measure" {
            return PMTheme.green
        } else if trackingMessage.contains("not") || trackingMessage.contains("Not") {
            return PMTheme.red
        } else {
            return PMTheme.amber
        }
    }
}

// MARK: - Scanning Indicator

struct ScanningIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(PMTheme.cyan.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(PMTheme.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Instruction Card

struct InstructionCard: View {
    enum Mode: Equatable {
        case tap, box, refine, secondTap, label
        case processing
        case ready(String)  // tracking message
    }

    var mode: Mode = .tap

    private var isProcessing: Bool {
        if case .processing = mode { return true }
        return false
    }

    private var iconName: String {
        switch mode {
        case .tap: return "hand.tap.fill"
        case .box: return "rectangle.dashed"
        case .refine: return "arrow.triangle.2.circlepath"
        case .secondTap: return "arrow.triangle.2.circlepath"
        case .label: return "doc.text.viewfinder"
        case .processing: return "circle.dotted"
        case .ready(let msg):
            if msg == "Ready to measure" { return "checkmark.circle.fill" }
            else if msg.contains("not") || msg.contains("Not") { return "exclamationmark.triangle.fill" }
            else { return "arrow.triangle.2.circlepath" }
        }
    }

    private var title: String {
        switch mode {
        case .tap: return "Tap on an object to measure"
        case .box: return "Draw a box to select"
        case .refine: return "Refine from a different angle"
        case .secondTap: return "Tap again from a different angle"
        case .label: return "Point at a label and tap"
        case .processing: return "Processing..."
        case .ready(let msg): return msg
        }
    }

    private var isLabelMode: Bool { mode == .label }

    private var accentColor: Color {
        if isLabelMode { return PMTheme.labelBlue }
        if case .ready(let msg) = mode {
            if msg == "Ready to measure" { return PMTheme.green }
            else if msg.contains("not") || msg.contains("Not") { return PMTheme.red }
            else { return PMTheme.amber }
        }
        return PMTheme.cyan
    }

    var body: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                    .symbolEffect(.pulse, options: .repeating, value: isReadyPulse)
            }

            Text(title)
                .font(PMTheme.mono(13))
                .foregroundColor(PMTheme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(accentColor.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private var isReadyPulse: Bool {
        if case .ready(let msg) = mode { return msg == "Ready to measure" }
        return false
    }
}

// MARK: - LiDAR Not Available View

struct LiDARNotAvailableView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("LiDAR Not Available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This app requires a device with a LiDAR sensor for accurate 3D measurements. Please use an iPhone Pro or iPad Pro with LiDAR.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

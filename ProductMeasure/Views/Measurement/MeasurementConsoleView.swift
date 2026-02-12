//
//  MeasurementConsoleView.swift
//  ProductMeasure
//

import SwiftUI

/// Full-screen console overlay showing measurement + label data with typing animation
struct MeasurementConsoleView: View {
    let width: String
    let height: String
    let length: String
    let volume: String
    let volumetricWeight: String
    let sizeClass: String
    let qualityLabel: String
    let pointCount: Int
    let labelData: LabelData?
    let lineRevealed: [Bool]
    let isComplete: Bool

    @State private var scanlineOffset: CGFloat = 0
    @State private var cursorVisible = true

    private var allLines: [ConsoleLine] {
        var lines: [ConsoleLine] = []

        // Dimensions section
        lines.append(ConsoleLine(icon: "ruler", label: "WIDTH", value: width, section: .dimensions))
        lines.append(ConsoleLine(icon: "ruler", label: "HEIGHT", value: height, section: .dimensions))
        lines.append(ConsoleLine(icon: "ruler", label: "LENGTH", value: length, section: .dimensions))
        lines.append(ConsoleLine(icon: "cube", label: "VOLUME", value: volume, section: .dimensions))
        lines.append(ConsoleLine(icon: "shippingbox", label: "VOL.WT", value: volumetricWeight, section: .dimensions))
        lines.append(ConsoleLine(icon: "rectangle.3.group", label: "SIZE", value: sizeClass, section: .dimensions))

        // Label data section
        if let labelData = labelData {
            for field in labelData.displayFields {
                lines.append(ConsoleLine(icon: field.icon, label: field.label, value: field.value, section: .label))
            }
        }

        // Quality section
        lines.append(ConsoleLine(icon: "gauge.with.dots.needle.33percent", label: "QUALITY", value: qualityLabel, section: .quality))
        lines.append(ConsoleLine(icon: "point.3.connected.trianglepath.dotted", label: "POINTS", value: "\(pointCount)", section: .quality))

        return lines
    }

    private var revealedCount: Int {
        lineRevealed.filter { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content lines
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let lines = allLines

                    ForEach(0..<lines.count, id: \.self) { index in
                        let line = lines[index]

                        if index < lineRevealed.count, lineRevealed[index] {
                            // Section header
                            if line.section != (index > 0 ? lines[index - 1].section : nil) {
                                sectionHeader(line.section)
                                    .transition(.opacity)
                            }

                            consoleLine(
                                icon: line.icon,
                                label: line.label,
                                value: line.value,
                                isLast: index == revealedCount - 1
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 300)

            // Scanline
            if !isComplete {
                scanlineView
            }
        }
        .background(Color.black.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(PMTheme.green.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: PMTheme.green.opacity(0.15), radius: 12, x: 0, y: 0)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                scanlineOffset = 1.0
            }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                cursorVisible.toggle()
            }
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ section: ConsoleSection) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(PMTheme.green.opacity(0.3))
                .frame(width: 12, height: 1)

            Text(section.title)
                .font(PMTheme.mono(PMTheme.consoleSectionFontSize, weight: .bold))
                .foregroundColor(PMTheme.green.opacity(0.6))

            Rectangle()
                .fill(PMTheme.green.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Console Line

    @ViewBuilder
    private func consoleLine(icon: String, label: String, value: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(PMTheme.green)
                .frame(width: 16)

            Text(label)
                .font(PMTheme.mono(10, weight: .semibold))
                .foregroundColor(PMTheme.green.opacity(0.6))
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(PMTheme.mono(PMTheme.consoleFieldFontSize, weight: .medium))
                .foregroundColor(PMTheme.green)
                .lineLimit(2)

            if isLast && !isComplete {
                Rectangle()
                    .fill(PMTheme.green)
                    .frame(width: 6, height: 14)
                    .opacity(cursorVisible ? 1.0 : 0.0)
            }

            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: - Scanline

    private var scanlineView: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            PMTheme.green.opacity(0),
                            PMTheme.green.opacity(0.15),
                            PMTheme.green.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .offset(y: scanlineOffset * geometry.size.height)
        }
        .frame(height: 4)
        .clipped()
    }

}

// MARK: - Supporting Types

enum ConsoleSection: Equatable {
    case dimensions
    case label
    case quality

    var title: String {
        switch self {
        case .dimensions: return "DIMENSIONS"
        case .label: return "LABEL DATA"
        case .quality: return "QUALITY"
        }
    }
}

struct ConsoleLine {
    let icon: String
    let label: String
    let value: String
    let section: ConsoleSection
}

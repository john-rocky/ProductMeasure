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
    let cartonId: String?
    let boxId: Int
    let lineRevealed: [Bool]
    let isComplete: Bool
    let onExportCSV: () -> Void
    let onClose: () -> Void
    var onReMeasure: (() -> Void)? = nil

    @State private var scanlineOffset: CGFloat = 0
    @State private var cursorVisible = true

    private var allLines: [ConsoleLine] {
        var lines: [ConsoleLine] = []

        let isSizeAlert = boxId == 2

        // WMS registration section (6 lines, indices 0-5)
        let ctnDisplay = cartonId ?? "N/A"
        lines.append(ConsoleLine(icon: "network", label: "CONNECT", value: "wms.warehouse.io:443", section: .wms))
        lines.append(ConsoleLine(icon: "arrow.up.circle", label: "REQUEST", value: "POST /wms/receipts", section: .wms))
        lines.append(ConsoleLine(icon: "doc.text", label: "BODY", value: "{\"ctn\":\"\(ctnDisplay)\"}", section: .wms))
        if isSizeAlert {
            lines.append(ConsoleLine(icon: "xmark.circle", label: "RESPONSE", value: "400 SIZE MISMATCH", section: .wms, isAlert: true))
            lines.append(ConsoleLine(icon: "exclamationmark.triangle", label: "REASON", value: "Exceeds size tolerance", section: .wms, isAlert: true))
            lines.append(ConsoleLine(icon: "arrow.counterclockwise", label: "ACTION", value: "Re-measure required", section: .wms, isAlert: true))
        } else {
            lines.append(ConsoleLine(icon: "checkmark.circle", label: "RESPONSE", value: "200 OK", section: .wms))
            lines.append(ConsoleLine(icon: "tray.and.arrow.down", label: "RECEIPT", value: "RCV-\(String(format: "%06d", Int.random(in: 100000...999999)))", section: .wms))
            lines.append(ConsoleLine(icon: "printer", label: "PRINT", value: "Label sent to printer", section: .wms))
        }

        // Dimensions section
        lines.append(ConsoleLine(icon: "ruler", label: "WIDTH", value: width, section: .dimensions))
        lines.append(ConsoleLine(icon: "ruler", label: "HEIGHT", value: height, section: .dimensions))
        lines.append(ConsoleLine(icon: "ruler", label: "LENGTH", value: length, section: .dimensions))
        lines.append(ConsoleLine(icon: "cube", label: "VOLUME", value: volume, section: .dimensions))
        lines.append(ConsoleLine(icon: "shippingbox", label: "VOL.WT", value: volumetricWeight, section: .dimensions))
        lines.append(ConsoleLine(icon: "rectangle.3.group", label: "SIZE", value: isSizeAlert ? "\(sizeClass) - OUT OF SPEC" : sizeClass, section: .dimensions, isAlert: isSizeAlert))

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
        ZStack {
            // Dim background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                headerView

                Divider()
                    .background(PMTheme.cyan.opacity(0.3))

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
                                    isLast: index == revealedCount - 1,
                                    section: line.section,
                                    isAlert: line.isAlert
                                )
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 400)

                // Scanline
                if !isComplete {
                    scanlineView
                }

                // Buttons
                if isComplete {
                    buttonRow
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(width: 340)
            .background(PMTheme.surfaceDark.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(PMTheme.cyan.opacity(0.3), lineWidth: 0.5)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                scanlineOffset = 1.0
            }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                cursorVisible.toggle()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundColor(PMTheme.cyan)

            Text("MEASUREMENT CONSOLE")
                .font(PMTheme.mono(PMTheme.consoleHeaderFontSize, weight: .bold))
                .foregroundColor(PMTheme.cyan)

            Spacer()

            Text(isComplete ? (boxId == 2 ? "SIZE ALERT" : "COMPLETE") : "LOADING...")
                .font(PMTheme.mono(10, weight: .medium))
                .foregroundColor(isComplete ? (boxId == 2 ? PMTheme.red : PMTheme.green) : PMTheme.cyan.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PMTheme.surfaceDark)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ section: ConsoleSection) -> some View {
        let accent = section == .wms ? PMTheme.green : PMTheme.cyan
        HStack(spacing: 6) {
            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(width: 12, height: 1)

            Text(section.title)
                .font(PMTheme.mono(PMTheme.consoleSectionFontSize, weight: .bold))
                .foregroundColor(accent.opacity(0.6))

            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Console Line

    @ViewBuilder
    private func consoleLine(icon: String, label: String, value: String, isLast: Bool, section: ConsoleSection = .dimensions, isAlert: Bool = false) -> some View {
        let valueColor: Color = isAlert ? PMTheme.red : (section == .wms ? PMTheme.green : PMTheme.textPrimary)
        let iconColor: Color = isAlert ? PMTheme.red : (section == .wms ? PMTheme.green : PMTheme.cyan)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(iconColor)
                .frame(width: 16)

            Text(label)
                .font(PMTheme.mono(10, weight: .semibold))
                .foregroundColor(PMTheme.textDimmed)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(PMTheme.mono(PMTheme.consoleFieldFontSize, weight: .medium))
                .foregroundColor(valueColor)
                .lineLimit(2)

            if isLast && !isComplete {
                Rectangle()
                    .fill(PMTheme.cyan)
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
                            PMTheme.cyan.opacity(0),
                            PMTheme.cyan.opacity(0.15),
                            PMTheme.cyan.opacity(0)
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

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 12) {
            if boxId == 2 {
                // Size out-of-spec: show RE-MEASURE button
                Button(action: { (onReMeasure ?? onClose)() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                        Text("RE-MEASURE")
                            .font(PMTheme.mono(12, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(PMTheme.red)
                    .clipShape(Capsule())
                }
            } else {
                Button(action: onClose) {
                    Text("CLOSE")
                        .font(PMTheme.mono(12, weight: .bold))
                        .foregroundColor(PMTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(PMTheme.surfaceElevated)
                        .clipShape(Capsule())
                }

                Button(action: onExportCSV) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text("EXPORT CSV")
                            .font(PMTheme.mono(12, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(PMTheme.cyan)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Supporting Types

enum ConsoleSection: Equatable {
    case wms
    case dimensions
    case label
    case quality

    var title: String {
        switch self {
        case .wms: return "WMS REGISTRATION"
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
    var isAlert: Bool = false
}

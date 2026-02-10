//
//  LabelResultView.swift
//  ProductMeasure
//

import SwiftUI

/// Cyberpunk neon-blue typing overlay showing parsed label fields
struct LabelResultView: View {
    let labelData: LabelData
    let lineRevealed: [Bool]
    let isComplete: Bool
    let onDismiss: () -> Void
    var dismissButtonLabel: String = "DONE"

    @State private var scanlineOffset: CGFloat = 0
    @State private var cursorVisible = true

    private let cardWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView

            Divider()
                .background(PMTheme.labelBlue.opacity(0.3))

            // Field lines
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let fields = labelData.displayFields

                    ForEach(0..<fields.count, id: \.self) { index in
                        if index < lineRevealed.count, lineRevealed[index] {
                            fieldLine(
                                icon: fields[index].icon,
                                label: fields[index].label,
                                value: fields[index].value,
                                isLast: index == revealedCount - 1
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    // Raw text fallback if no structured OCR fields matched
                    if !labelData.hasOCRFields, !labelData.rawText.isEmpty,
                       lineRevealed.first == true {
                        Text(labelData.rawText)
                            .font(PMTheme.mono(11))
                            .foregroundColor(PMTheme.textPrimary)
                            .lineLimit(10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 300)

            // Scanline effect
            if !isComplete {
                scanlineView
            }

            // Done button
            if isComplete {
                doneButton
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: cardWidth)
        .background(PMTheme.surfaceDark.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                scanlineOffset = 1.0
            }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                cursorVisible.toggle()
            }
        }
    }

    private var revealedCount: Int {
        lineRevealed.filter { $0 }.count
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "doc.text.viewfinder")
                .foregroundColor(PMTheme.labelBlue)

            Text("LABEL DATA")
                .font(PMTheme.mono(14, weight: .bold))
                .foregroundColor(PMTheme.labelBlue)

            Spacer()

            Text(isComplete ? "COMPLETE" : "READING...")
                .font(PMTheme.mono(10, weight: .medium))
                .foregroundColor(isComplete ? PMTheme.green : PMTheme.labelBlue.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PMTheme.surfaceDark)
    }

    // MARK: - Field Line

    @ViewBuilder
    private func fieldLine(icon: String, label: String, value: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(PMTheme.labelBlue)
                .frame(width: 16)

            Text(label)
                .font(PMTheme.mono(10, weight: .semibold))
                .foregroundColor(PMTheme.textDimmed)
                .frame(width: 65, alignment: .leading)

            Text(value)
                .font(PMTheme.mono(12, weight: .medium))
                .foregroundColor(PMTheme.textPrimary)
                .lineLimit(2)

            // Blinking cursor on the last revealed line
            if isLast && !isComplete {
                Rectangle()
                    .fill(PMTheme.labelBlue)
                    .frame(width: 6, height: 14)
                    .opacity(cursorVisible ? 1.0 : 0.0)
            }

            Spacer()
        }
    }

    // MARK: - Scanline

    private var scanlineView: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            PMTheme.labelBlue.opacity(0),
                            PMTheme.labelBlue.opacity(0.15),
                            PMTheme.labelBlue.opacity(0)
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

    // MARK: - Done Button

    private var doneButton: some View {
        Button(action: onDismiss) {
            Text(dismissButtonLabel)
                .font(PMTheme.mono(13, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(PMTheme.labelBlue.opacity(0.8))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

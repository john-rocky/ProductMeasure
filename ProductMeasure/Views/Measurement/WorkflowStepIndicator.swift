//
//  WorkflowStepIndicator.swift
//  SnapMeasure
//

import SwiftUI

/// Horizontal step indicator for guided measurement workflow
struct WorkflowStepIndicator: View {
    let currentStep: WorkflowStep
    let appMode: AppMode
    let onSkipLabel: (() -> Void)?

    private struct StepInfo {
        let icon: String
        let label: String
    }

    private var steps: [StepInfo] {
        switch appMode {
        case .warehouse:
            return [
                StepInfo(icon: "hand.tap", label: String(localized: "Measure")),
                StepInfo(icon: "arrow.triangle.2.circlepath", label: String(localized: "Refine")),
                StepInfo(icon: "doc.text.viewfinder", label: String(localized: "Label")),
                StepInfo(icon: "checkmark.rectangle", label: String(localized: "Review")),
                StepInfo(icon: "doc.text", label: String(localized: "Export")),
            ]
        case .shipping, .measure:
            return [
                StepInfo(icon: "hand.tap", label: String(localized: "Measure")),
                StepInfo(icon: "arrow.triangle.2.circlepath", label: String(localized: "Refine")),
                StepInfo(icon: "checkmark.rectangle", label: String(localized: "Result")),
            ]
        case .labelOnly:
            return [
                StepInfo(icon: "doc.text.viewfinder", label: String(localized: "Scan")),
                StepInfo(icon: "checkmark.rectangle", label: String(localized: "Result")),
            ]
        }
    }

    private var activeIndex: Int {
        switch appMode {
        case .warehouse:
            switch currentStep {
            case .idle: return 0
            case .awaitingSecondTap: return 1
            case .awaitingLabelScan, .showingLabelResult: return 2
            case .showingResult: return 3
            case .showingConsole, .showingCSV: return 4
            }
        case .shipping, .measure:
            switch currentStep {
            case .idle: return 0
            case .awaitingSecondTap: return 1
            case .showingResult, .showingConsole, .showingCSV: return 2
            default: return 0
            }
        case .labelOnly:
            switch currentStep {
            case .idle, .awaitingLabelScan, .showingLabelResult: return 0
            case .showingResult, .showingConsole, .showingCSV: return 1
            default: return 0
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { index in
                    stepDot(index: index)

                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(index < activeIndex ? PMTheme.cyan : PMTheme.textDimmed.opacity(0.3))
                            .frame(height: 1)
                    }
                }
            }

            // Skip button during label scan step (warehouse only)
            if appMode == .warehouse && currentStep == .awaitingLabelScan, let onSkip = onSkipLabel {
                Button(action: onSkip) {
                    HStack(spacing: 4) {
                        Text("SKIP")
                            .font(PMTheme.mono(10, weight: .bold))
                        Image(systemName: "forward.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(PMTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(PMTheme.surfaceElevated.opacity(0.8))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PMTheme.cyan.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func stepDot(index: Int) -> some View {
        let isActive = index == activeIndex
        let isComplete = index < activeIndex

        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(isActive ? PMTheme.cyan : isComplete ? PMTheme.cyan.opacity(0.6) : PMTheme.textDimmed.opacity(0.2))
                    .frame(width: isActive ? 26 : 20, height: isActive ? 26 : 20)

                Image(systemName: isComplete ? "checkmark" : steps[index].icon)
                    .font(.system(size: isActive ? 11 : 9, weight: .bold))
                    .foregroundColor(isActive || isComplete ? .black : PMTheme.textDimmed)
            }

            Text(steps[index].label)
                .font(PMTheme.mono(8, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? PMTheme.cyan : PMTheme.textDimmed)
        }
        .frame(maxWidth: .infinity)
    }
}

//
//  CSVDisplayView.swift
//  ProductMeasure
//

import SwiftUI
import UIKit

/// Monospace CSV text display with Copy/Share/Done buttons
struct CSVDisplayView: View {
    let csvString: String
    let onDone: () -> Void

    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(PMTheme.cyan)

                    Text("CSV EXPORT")
                        .font(PMTheme.mono(14, weight: .bold))
                        .foregroundColor(PMTheme.cyan)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(PMTheme.surfaceDark)

                Divider()
                    .background(PMTheme.cyan.opacity(0.3))

                // CSV content
                ScrollView([.horizontal, .vertical]) {
                    Text(csvString)
                        .font(PMTheme.mono(10))
                        .foregroundColor(PMTheme.textPrimary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(14)
                }
                .frame(maxHeight: 200)
                .background(PMTheme.surfaceCard)

                Divider()
                    .background(PMTheme.cyan.opacity(0.3))

                // Buttons
                HStack(spacing: 10) {
                    Button(action: copyToClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                            Text(copied ? "COPIED" : "COPY")
                                .font(PMTheme.mono(12, weight: .bold))
                        }
                        .foregroundColor(copied ? PMTheme.green : PMTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(PMTheme.surfaceElevated)
                        .clipShape(Capsule())
                    }

                    Button(action: shareCSV) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                            Text("SHARE")
                                .font(PMTheme.mono(12, weight: .bold))
                        }
                        .foregroundColor(PMTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(PMTheme.surfaceElevated)
                        .clipShape(Capsule())
                    }

                    Button(action: onDone) {
                        Text("DONE")
                            .font(PMTheme.mono(12, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(PMTheme.cyan)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = csvString
        withAnimation(.easeOut(duration: 0.2)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                copied = false
            }
        }
    }

    private func shareCSV() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        let activityVC = UIActivityViewController(activityItems: [csvString], applicationActivities: nil)

        // iPad popover
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        // Find the topmost presented controller
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(activityVC, animated: true)
    }
}

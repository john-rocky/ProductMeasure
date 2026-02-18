//
//  ScanningTipsView.swift
//  ProductMeasure
//

import SwiftUI

struct ScanningTipsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var generalExpanded = true
    @State private var twoTapExpanded = false
    @State private var avoidExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Section 1: General Scanning Tips
                    DisclosureGroup(isExpanded: $generalExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "iphone.radiowaves.left.and.right",
                                title: String(localized: "tip.general.angle.title"),
                                description: String(localized: "tip.general.angle.desc")
                            )
                            TipRow(
                                icon: "ruler",
                                title: String(localized: "tip.general.distance.title"),
                                description: String(localized: "tip.general.distance.desc")
                            )
                            TipRow(
                                icon: "hand.raised",
                                title: String(localized: "tip.general.steady.title"),
                                description: String(localized: "tip.general.steady.desc")
                            )
                            TipRow(
                                icon: "arrow.up.to.line",
                                title: String(localized: "tip.general.face.title"),
                                description: String(localized: "tip.general.face.desc")
                            )
                            TipRow(
                                icon: "exclamationmark.triangle",
                                title: String(localized: "tip.general.steep.title"),
                                description: String(localized: "tip.general.steep.desc")
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text(String(localized: "tip.section.general"))
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Section 2: Two-Tap Strategy
                    DisclosureGroup(isExpanded: $twoTapExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "1.circle",
                                title: String(localized: "tip.twotap.first.title"),
                                description: String(localized: "tip.twotap.first.desc")
                            )
                            TipRow(
                                icon: "2.circle",
                                title: String(localized: "tip.twotap.second.title"),
                                description: String(localized: "tip.twotap.second.desc")
                            )
                            TipRow(
                                icon: "angle",
                                title: String(localized: "tip.twotap.sameangle.title"),
                                description: String(localized: "tip.twotap.sameangle.desc")
                            )
                            TipRow(
                                icon: "arrow.left.and.right",
                                title: String(localized: "tip.twotap.samedist.title"),
                                description: String(localized: "tip.twotap.samedist.desc")
                            )
                            TipRow(
                                icon: "square.on.square",
                                title: String(localized: "tip.twotap.overlap.title"),
                                description: String(localized: "tip.twotap.overlap.desc")
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text(String(localized: "tip.section.twotap"))
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Section 3: What to Avoid
                    DisclosureGroup(isExpanded: $avoidExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "arrow.2.squarepath",
                                title: String(localized: "tip.avoid.sameangle.title"),
                                description: String(localized: "tip.avoid.sameangle.desc")
                            )
                            TipRow(
                                icon: "arrow.left.arrow.right",
                                title: String(localized: "tip.avoid.opposite.title"),
                                description: String(localized: "tip.avoid.opposite.desc")
                            )
                            TipRow(
                                icon: "arrow.down.to.line",
                                title: String(localized: "tip.avoid.above.title"),
                                description: String(localized: "tip.avoid.above.desc")
                            )
                            TipRow(
                                icon: "figure.walk",
                                title: String(localized: "tip.avoid.moving.title"),
                                description: String(localized: "tip.avoid.moving.desc")
                            )
                            TipRow(
                                icon: "eye.slash",
                                title: String(localized: "tip.avoid.surface.title"),
                                description: String(localized: "tip.avoid.surface.desc")
                            )
                            TipRow(
                                icon: "scope",
                                title: String(localized: "tip.avoid.distance.title"),
                                description: String(localized: "tip.avoid.distance.desc")
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text(String(localized: "tip.section.avoid"))
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "xmark.shield")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .background(PMTheme.surfaceDark)
            .navigationTitle(String(localized: "tip.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(PMTheme.textSecondary)
                    }
                }
            }
        }
    }
}

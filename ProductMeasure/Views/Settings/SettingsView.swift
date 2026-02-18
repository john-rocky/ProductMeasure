//
//  SettingsView.swift
//  ProductMeasure
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("appMode") private var appMode: AppMode = .warehouse
    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @AppStorage("roundingPrecision") private var roundingPrecision: RoundingPrecision = .millimeter1
    @AppStorage("measurementMode") private var measurementMode: MeasurementMode = .boxPriority
    @AppStorage("showQualityIndicators") private var showQualityIndicators = true
    @AppStorage("pipelineVersion") private var pipelineVersion: PipelineVersion = .standard
    @AppStorage("showScanningTips") private var showScanningTips = true
    #if DEBUG
    @AppStorage("showMaskPreview") private var showMaskPreview = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                // App mode section
                Section {
                    Picker("App Mode", selection: $appMode) {
                        ForEach(AppMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(appMode.description)
                        .font(PMTheme.mono(11))
                        .foregroundColor(PMTheme.textSecondary)
                } header: {
                    Text("APP MODE")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Units section
                Section {
                    Picker("Display Unit", selection: $measurementUnit) {
                        ForEach(MeasurementUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }

                    Picker("Rounding", selection: $roundingPrecision) {
                        ForEach(RoundingPrecision.allCases, id: \.self) { precision in
                            Text(precision.displayName).tag(precision)
                        }
                    }
                } header: {
                    Text("UNITS")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Measurement mode section
                Section {
                    Picker("Default Mode", selection: $measurementMode) {
                        ForEach(MeasurementMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                            }
                            .tag(mode)
                        }
                    }

                    Text(measurementMode.description)
                        .font(PMTheme.mono(11))
                        .foregroundColor(PMTheme.textSecondary)
                } header: {
                    Text("MEASUREMENT MODE")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Pipeline version section
                Section {
                    Picker("Pipeline", selection: $pipelineVersion) {
                        ForEach(PipelineVersion.allCases, id: \.self) { version in
                            Text(version.displayName).tag(version)
                        }
                    }

                    Text(pipelineVersion.description)
                        .font(PMTheme.mono(11))
                        .foregroundColor(PMTheme.textSecondary)
                } header: {
                    Text("PIPELINE VERSION")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Display section
                Section {
                    Toggle("Show Quality Indicators", isOn: $showQualityIndicators)
                } header: {
                    Text("DISPLAY")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Scanning tips section
                Section {
                    Toggle(String(localized: "setting.showScanningTips"), isOn: $showScanningTips)
                } header: {
                    Text("SCANNING TIPS")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                #if DEBUG
                // Debug section
                Section {
                    Toggle("Show Mask Preview", isOn: $showMaskPreview)
                } header: {
                    Text("DEBUG")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }
                #endif

                // Device info section
                Section {
                    HStack {
                        Text("LiDAR Sensor")
                        Spacer()
                        if LiDARChecker.isLiDARAvailable {
                            Label("Available", systemImage: "checkmark.circle.fill")
                                .foregroundColor(PMTheme.green)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle.fill")
                                .foregroundColor(PMTheme.red)
                        }
                    }

                    HStack {
                        Text("ARKit")
                        Spacer()
                        if LiDARChecker.isARKitSupported {
                            Label("Supported", systemImage: "checkmark.circle.fill")
                                .foregroundColor(PMTheme.green)
                        } else {
                            Label("Not Supported", systemImage: "xmark.circle.fill")
                                .foregroundColor(PMTheme.red)
                        }
                    }
                } header: {
                    Text("DEVICE CAPABILITIES")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // Tips section
                Section {
                    TipRow(
                        icon: "lightbulb",
                        title: "Good Lighting",
                        description: "Ensure good lighting for accurate depth sensing"
                    )
                    TipRow(
                        icon: "hand.draw",
                        title: "Steady Movement",
                        description: "Move device slowly for better tracking"
                    )
                    TipRow(
                        icon: "cube",
                        title: "Object Surface",
                        description: "Avoid transparent or reflective surfaces"
                    )
                    TipRow(
                        icon: "ruler",
                        title: "Distance",
                        description: "Keep 0.5-3m distance from objects"
                    )
                } header: {
                    Text("TIPS FOR ACCURATE MEASUREMENTS")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                }

                // About section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(PMTheme.textSecondary)
                    }

                    HStack {
                        Text("Accuracy")
                        Spacer()
                        Text("±5-10mm (typical)")
                            .foregroundColor(PMTheme.textSecondary)
                    }
                } header: {
                    Text("ABOUT")
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.cyan)
                } footer: {
                    Text("Measurements are estimates based on LiDAR depth sensing. Actual accuracy may vary based on lighting, surface properties, and distance.")
                        .font(PMTheme.mono(11))
                        .foregroundColor(PMTheme.textDimmed)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PMTheme.surfaceDark)
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Tip Row

struct TipRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(PMTheme.cyan)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PMTheme.mono(13, weight: .medium))
                Text(description)
                    .font(PMTheme.mono(11))
                    .foregroundColor(PMTheme.textSecondary)
            }
        }
    }
}

#Preview {
    SettingsView()
}

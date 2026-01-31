//
//  SettingsView.swift
//  ProductMeasure
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @AppStorage("roundingPrecision") private var roundingPrecision: RoundingPrecision = .millimeter1
    @AppStorage("measurementMode") private var measurementMode: MeasurementMode = .boxPriority
    @AppStorage("showQualityIndicators") private var showQualityIndicators = true

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Units")
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
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Measurement Mode")
                }

                // Display section
                Section {
                    Toggle("Show Quality Indicators", isOn: $showQualityIndicators)
                } header: {
                    Text("Display")
                }

                // Device info section
                Section {
                    HStack {
                        Text("LiDAR Sensor")
                        Spacer()
                        if LiDARChecker.isLiDARAvailable {
                            Label("Available", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        Text("ARKit")
                        Spacer()
                        if LiDARChecker.isARKitSupported {
                            Label("Supported", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Not Supported", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Device Capabilities")
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
                    Text("Tips for Accurate Measurements")
                }

                // About section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Accuracy")
                        Spacer()
                        Text("±5-10mm (typical)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Measurements are estimates based on LiDAR depth sensing. Actual accuracy may vary based on lighting, surface properties, and distance.")
                }
            }
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
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - AppStorage Conformances

extension MeasurementUnit: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "mm": self = .millimeters
        case "cm": self = .centimeters
        case "in": self = .inches
        default: return nil
        }
    }
}

extension RoundingPrecision: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "1mm": self = .millimeter1
        case "5mm": self = .millimeter5
        case "0.1cm": self = .centimeter01
        case "1cm": self = .centimeter1
        default: return nil
        }
    }
}

extension MeasurementMode: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "box": self = .boxPriority
        case "free": self = .freeObject
        default: return nil
        }
    }
}

#Preview {
    SettingsView()
}

//
//  HistoryDetailView.swift
//  ProductMeasure
//

import SwiftUI
import SwiftData
import simd

struct HistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let measurement: ProductMeasurement

    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @State private var showingShareSheet = false
    @State private var showingDeleteAlert = false
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Image section
                    imageSection

                    // Dimensions section
                    dimensionsSection

                    // Volume section
                    volumeSection

                    // Quality section
                    qualitySection

                    // Notes section
                    notesSection

                    // Metadata section
                    metadataSection
                }
                .padding()
            }
            .background(PMTheme.surfaceDark)
            .navigationTitle("Measurement Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { showingShareSheet = true }) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive, action: { showingDeleteAlert = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(measurement: measurement, unit: measurementUnit)
            }
            .alert("Delete Measurement", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    deleteMeasurement()
                }
            } message: {
                Text("Are you sure you want to delete this measurement? This action cannot be undone.")
            }
            .onAppear {
                notes = measurement.notes
            }
        }
    }

    // MARK: - Sections

    private var imageSection: some View {
        Group {
            if let imageData = measurement.annotatedImageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(PMTheme.surfaceCard)
                    .frame(height: 200)
                    .overlay {
                        VStack {
                            Image(systemName: "cube")
                                .font(.largeTitle)
                                .foregroundColor(PMTheme.cyan.opacity(0.30))
                            Text("No image available")
                                .font(PMTheme.mono(11))
                                .foregroundColor(PMTheme.textSecondary)
                        }
                    }
            }
        }
    }

    private var dimensionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DIMENSIONS")

            HStack(spacing: 16) {
                dimensionCard(label: "Length", value: measurement.lengthMeters)
                dimensionCard(label: "Width", value: measurement.widthMeters)
                dimensionCard(label: "Height", value: measurement.heightMeters)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dimensionCard(label: String, value: Float) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(PMTheme.mono(11))
                .foregroundColor(PMTheme.cyan)
            Text(formatDimension(value))
                .font(PMTheme.mono(16, weight: .semibold))
                .foregroundColor(PMTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(PMTheme.surfaceCard)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PMTheme.cyan.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var volumeSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bounding Box Volume")
                    .font(PMTheme.mono(14, weight: .semibold))
                    .foregroundColor(PMTheme.textPrimary)
                Text("(Estimated)")
                    .font(PMTheme.mono(11))
                    .foregroundColor(PMTheme.textSecondary)
            }

            Spacer()

            Text(measurement.formattedVolume(unit: measurementUnit))
                .font(PMTheme.mono(20, weight: .semibold))
                .foregroundColor(PMTheme.cyan)
        }
        .padding()
        .background(PMTheme.surfaceCard)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("QUALITY METRICS")

            VStack(spacing: 0) {
                qualityRow(label: "Overall Quality", value: measurement.quality.overallQuality.rawValue.capitalized, isFirst: true)
                qualityRow(label: "Depth Coverage", value: String(format: "%.0f%%", measurement.depthCoverage * 100))
                qualityRow(label: "Depth Confidence", value: String(format: "%.0f%%", measurement.depthConfidence * 100))
                qualityRow(label: "Point Count", value: "\(measurement.pointCount)")
                qualityRow(label: "Tracking State", value: measurement.trackingStateDescription, isLast: true)
            }
            .background(PMTheme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PMTheme.cyan.opacity(0.10), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func qualityRow(label: String, value: String, isFirst: Bool = false, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider()
                    .background(PMTheme.surfaceElevated)
            }
            HStack {
                Text(label)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(PMTheme.mono(13, weight: .medium))
                    .foregroundColor(PMTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("NOTES")

            TextEditor(text: $notes)
                .font(PMTheme.mono(13))
                .frame(minHeight: 80)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(PMTheme.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(PMTheme.cyan.opacity(0.10), lineWidth: 0.5)
                )
                .onChange(of: notes) { _, newValue in
                    measurement.notes = newValue
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("DETAILS")

            VStack(spacing: 0) {
                metadataRow(label: "Date", value: formattedDate, isFirst: true)
                metadataRow(label: "Mode", value: measurement.measurementMode.displayName)
                metadataRow(label: "ID", value: String(measurement.id.uuidString.prefix(8)), isLast: true)
            }
            .background(PMTheme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PMTheme.cyan.opacity(0.10), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(label: String, value: String, isFirst: Bool = false, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider()
                    .background(PMTheme.surfaceElevated)
            }
            HStack {
                Text(label)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(PMTheme.mono(13, weight: .medium))
                    .foregroundColor(PMTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(PMTheme.mono(11, weight: .bold))
            .foregroundColor(PMTheme.cyan)
            .padding(.horizontal, 4)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: measurement.timestamp)
    }

    private func formatDimension(_ meters: Float) -> String {
        let value = measurementUnit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f %@", value, measurementUnit.rawValue)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, measurementUnit.rawValue)
        } else {
            return String(format: "%.2f %@", value, measurementUnit.rawValue)
        }
    }

    private func deleteMeasurement() {
        modelContext.delete(measurement)
        dismiss()
    }
}

// MARK: - Share Sheet

struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let measurement: ProductMeasurement
    let unit: MeasurementUnit

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Preview
                if let imageData = measurement.annotatedImageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Share text preview
                Text(shareText)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Share") {
                    shareContent()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()
            }
            .padding()
            .background(PMTheme.surfaceDark)
            .navigationTitle("Share Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var shareText: String {
        """
        Measurement:
        \(measurement.formattedDimensions(unit: unit, precision: .millimeter1))
        Volume: \(measurement.formattedVolume(unit: unit))
        """
    }

    private func shareContent() {
        var items: [Any] = [shareText]

        if let imageData = measurement.annotatedImageData,
           let image = UIImage(data: imageData) {
            items.append(image)
        }

        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityVC, animated: true)
        }

        dismiss()
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ProductMeasurement.self, configurations: config)

    let sampleBox = BoundingBox3D(
        center: .zero,
        extents: SIMD3<Float>(0.1, 0.05, 0.15),
        rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    )
    let sampleQuality = MeasurementQuality(
        depthCoverage: 0.85,
        depthConfidence: 0.75,
        pointCount: 2500,
        trackingStateDescription: "Normal",
        trackingNormal: true
    )
    let measurement = ProductMeasurement(
        boundingBox: sampleBox,
        quality: sampleQuality,
        mode: .boxPriority
    )

    HistoryDetailView(measurement: measurement)
        .modelContainer(container)
}

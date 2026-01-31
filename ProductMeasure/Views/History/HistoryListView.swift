//
//  HistoryListView.swift
//  ProductMeasure
//

import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProductMeasurement.timestamp, order: .reverse) private var measurements: [ProductMeasurement]

    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @State private var searchText = ""
    @State private var selectedMeasurement: ProductMeasurement?
    @State private var showingExportSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if measurements.isEmpty {
                    emptyStateView
                } else {
                    measurementList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { showingExportSheet = true }) {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                        .disabled(measurements.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $selectedMeasurement) { measurement in
                HistoryDetailView(measurement: measurement)
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportSheet(measurements: measurements, unit: measurementUnit)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveMeasurement)) { notification in
            if let measurement = notification.object as? ProductMeasurement {
                modelContext.insert(measurement)
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "ruler")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Measurements")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Measurements you take will appear here")
                .foregroundColor(.secondary)
        }
    }

    private var measurementList: some View {
        List {
            ForEach(filteredMeasurements) { measurement in
                MeasurementRow(measurement: measurement, unit: measurementUnit)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMeasurement = measurement
                    }
            }
            .onDelete(perform: deleteMeasurements)
        }
        .searchable(text: $searchText, prompt: "Search measurements")
    }

    private var filteredMeasurements: [ProductMeasurement] {
        if searchText.isEmpty {
            return measurements
        } else {
            return measurements.filter { measurement in
                measurement.notes.localizedCaseInsensitiveContains(searchText) ||
                measurement.formattedDimensions(unit: measurementUnit, precision: .millimeter1)
                    .localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func deleteMeasurements(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredMeasurements[index])
        }
    }
}

// MARK: - Measurement Row

struct MeasurementRow: View {
    let measurement: ProductMeasurement
    let unit: MeasurementUnit

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            thumbnailView

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(measurement.formattedDimensions(unit: unit, precision: .millimeter1))
                    .font(.headline)

                Text(measurement.formattedVolume(unit: unit))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    qualityBadge
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var thumbnailView: some View {
        Group {
            if let imageData = measurement.annotatedImageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "cube")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var qualityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(qualityColor)
                .frame(width: 6, height: 6)
            Text(measurement.quality.overallQuality.rawValue.capitalized)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
    }

    private var qualityColor: Color {
        switch measurement.quality.overallQuality {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .red
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: measurement.timestamp)
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let measurements: [ProductMeasurement]
    let unit: MeasurementUnit

    @State private var exportFormat: ExportFormat = .csv
    @State private var isExporting = false

    enum ExportFormat: String, CaseIterable {
        case csv = "CSV"
        case json = "JSON"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export Format", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Data") {
                    Text("\(measurements.count) measurement(s)")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") {
                        exportData()
                    }
                    .disabled(isExporting)
                }
            }
        }
    }

    private func exportData() {
        isExporting = true

        let exportService = ExportService()
        let data: Data
        let filename: String

        switch exportFormat {
        case .csv:
            data = exportService.exportToCSV(measurements: measurements, unit: unit)
            filename = "measurements.csv"
        case .json:
            data = exportService.exportToJSON(measurements: measurements)
            filename = "measurements.json"
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: tempURL)

            let activityVC = UIActivityViewController(
                activityItems: [tempURL],
                applicationActivities: nil
            )

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(activityVC, animated: true)
            }
        } catch {
            print("Export failed: \(error)")
        }

        isExporting = false
        dismiss()
    }
}

#Preview {
    HistoryListView()
        .modelContainer(for: ProductMeasurement.self, inMemory: true)
}

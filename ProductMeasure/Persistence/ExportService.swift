//
//  ExportService.swift
//  ProductMeasure
//

import Foundation
import UIKit

/// Service for exporting measurements to various formats
class ExportService {
    // MARK: - CSV Export

    func exportToCSV(measurements: [ProductMeasurement], unit: MeasurementUnit) -> Data {
        var csv = "ID,Date,Length (\(unit.rawValue)),Width (\(unit.rawValue)),Height (\(unit.rawValue)),Volume (\(unit.volumeUnit())),Quality,Mode,Notes\n"

        let dateFormatter = ISO8601DateFormatter()

        for measurement in measurements {
            let id = measurement.id.uuidString
            let date = dateFormatter.string(from: measurement.timestamp)
            let length = unit.convert(meters: measurement.lengthMeters)
            let width = unit.convert(meters: measurement.widthMeters)
            let height = unit.convert(meters: measurement.heightMeters)
            let volume = unit.convertVolume(cubicMeters: measurement.volumeCubicMeters)
            let quality = measurement.quality.overallQuality.rawValue
            let mode = measurement.measurementMode.rawValue
            let notes = measurement.notes.replacingOccurrences(of: ",", with: ";")
                                         .replacingOccurrences(of: "\n", with: " ")

            csv += "\(id),\(date),\(String(format: "%.2f", length)),\(String(format: "%.2f", width)),\(String(format: "%.2f", height)),\(String(format: "%.2f", volume)),\(quality),\(mode),\"\(notes)\"\n"
        }

        return csv.data(using: .utf8) ?? Data()
    }

    // MARK: - JSON Export

    func exportToJSON(measurements: [ProductMeasurement]) -> Data {
        let exportData = measurements.map { measurement in
            MeasurementExport(
                id: measurement.id.uuidString,
                timestamp: ISO8601DateFormatter().string(from: measurement.timestamp),
                dimensions: DimensionsExport(
                    length: measurement.lengthMeters,
                    width: measurement.widthMeters,
                    height: measurement.heightMeters,
                    unit: "meters"
                ),
                volume: VolumeExport(
                    value: measurement.volumeCubicMeters,
                    unit: "cubic_meters"
                ),
                boundingBox: BoundingBoxExport(
                    center: [measurement.centerX, measurement.centerY, measurement.centerZ],
                    extents: [measurement.extentX, measurement.extentY, measurement.extentZ],
                    rotation: [measurement.rotationX, measurement.rotationY, measurement.rotationZ, measurement.rotationW]
                ),
                quality: QualityExport(
                    overall: measurement.quality.overallQuality.rawValue,
                    depthCoverage: measurement.depthCoverage,
                    depthConfidence: measurement.depthConfidence,
                    pointCount: measurement.pointCount,
                    trackingState: measurement.trackingStateDescription
                ),
                mode: measurement.measurementMode.rawValue,
                notes: measurement.notes
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            return try encoder.encode(exportData)
        } catch {
            print("JSON encoding failed: \(error)")
            return Data()
        }
    }

    // MARK: - Image Export

    func createAnnotatedImage(
        originalImage: UIImage,
        measurement: ProductMeasurement,
        unit: MeasurementUnit
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: originalImage.size)

        return renderer.image { context in
            // Draw original image
            originalImage.draw(at: .zero)

            // Add measurement overlay
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24),
                .foregroundColor: UIColor.white,
                .backgroundColor: UIColor.black.withAlphaComponent(0.7),
                .paragraphStyle: paragraphStyle
            ]

            let text = measurement.formattedDimensions(unit: unit, precision: .millimeter1)
            let textRect = CGRect(
                x: 20,
                y: originalImage.size.height - 80,
                width: originalImage.size.width - 40,
                height: 60
            )

            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    // MARK: - Share Items

    func createShareItems(
        measurement: ProductMeasurement,
        unit: MeasurementUnit,
        includeImage: Bool = true
    ) -> [Any] {
        var items: [Any] = []

        // Text summary
        let summary = """
        Measurement
        -----------
        Dimensions: \(measurement.formattedDimensions(unit: unit, precision: .millimeter1))
        Volume: \(measurement.formattedVolume(unit: unit))
        Date: \(DateFormatter.localizedString(from: measurement.timestamp, dateStyle: .medium, timeStyle: .short))
        Quality: \(measurement.quality.overallQuality.rawValue.capitalized)
        """
        items.append(summary)

        // Image if available
        if includeImage, let imageData = measurement.annotatedImageData, let image = UIImage(data: imageData) {
            items.append(image)
        }

        return items
    }
}

// MARK: - Export Data Structures

private struct MeasurementExport: Codable {
    let id: String
    let timestamp: String
    let dimensions: DimensionsExport
    let volume: VolumeExport
    let boundingBox: BoundingBoxExport
    let quality: QualityExport
    let mode: String
    let notes: String
}

private struct DimensionsExport: Codable {
    let length: Float
    let width: Float
    let height: Float
    let unit: String
}

private struct VolumeExport: Codable {
    let value: Float
    let unit: String
}

private struct BoundingBoxExport: Codable {
    let center: [Float]
    let extents: [Float]
    let rotation: [Float]
}

private struct QualityExport: Codable {
    let overall: String
    let depthCoverage: Float
    let depthConfidence: Float
    let pointCount: Int
    let trackingState: String
}

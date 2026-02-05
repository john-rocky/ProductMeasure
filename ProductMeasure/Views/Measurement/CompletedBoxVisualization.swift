//
//  CompletedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Simplified visualization for saved/completed boxes
/// Shows edges and dimension billboard only (no handles or rotation ring)
class CompletedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [ModelEntity] = []
    private var dimensionBillboardEntity: Entity?

    private(set) var boundingBox: BoundingBox3D
    private let height: Float
    private let length: Float
    private let width: Float
    private let unit: MeasurementUnit

    // MARK: - Constants

    // White wireframe (same as BoxVisualization)
    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.5)
    private let lineRadius: Float = 0.0004  // Thin (0.4mm)

    // Label styling (Apple Measure style - white background, black text)
    private let labelFontSize: CGFloat = 0.010
    private let labelBackgroundColor: UIColor = UIColor(white: 1.0, alpha: 0.9)
    private let labelTextColor: UIColor = UIColor(white: 0.0, alpha: 0.9)

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D, height: Float, length: Float, width: Float, unit: MeasurementUnit) {
        self.boundingBox = boundingBox
        self.height = height
        self.length = length
        self.width = width
        self.unit = unit
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    /// Update billboard orientation to face the camera
    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        guard let billboard = dimensionBillboardEntity else { return }

        let billboardPos = billboard.position(relativeTo: nil)
        let toCamera = cameraPosition - billboardPos
        let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

        if simd_length(toCameraHorizontal) > 0.01 {
            let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
            billboard.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    /// Show or hide the dimension billboard
    func setDimensionBillboardVisible(_ visible: Bool) {
        dimensionBillboardEntity?.isEnabled = visible
    }

    /// Check if this box is visible from camera
    func isVisibleFromCamera(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) -> Bool {
        let toBox = boundingBox.center - cameraPosition
        let distance = simd_length(toBox)
        let toBoxNormalized = toBox / distance
        let dot = simd_dot(toBoxNormalized, cameraForward)
        return dot > 0.3
    }

    /// Get the apparent size of this box from the camera
    func apparentSizeFromCamera(cameraPosition: SIMD3<Float>) -> Float {
        let distance = simd_length(boundingBox.center - cameraPosition)
        if distance < 0.01 { return 0 }
        let boxSize = boundingBox.extents.x * boundingBox.extents.y * boundingBox.extents.z
        return boxSize / (distance * distance)
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createDimensionBillboard()
    }

    // MARK: - Edge Creation

    private func createEdges() {
        let edges = boundingBox.edges

        for (index, (start, end)) in edges.enumerated() {
            let edgeEntity = createEdgeEntity(from: start, to: end, index: index)
            entity.addChild(edgeEntity)
            edgeEntities.append(edgeEntity)
        }
    }

    private func createEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> ModelEntity {
        let direction = end - start
        let length = simd_length(direction)

        let mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])
        let material = UnlitMaterial(color: lineColor)

        let edgeEntity = ModelEntity(mesh: mesh, materials: [material])
        edgeEntity.name = "completed_edge_\(index)"
        edgeEntity.position = (start + end) / 2
        edgeEntity.orientation = calculateOrientation(direction: direction)

        return edgeEntity
    }

    // MARK: - Dimension Billboard

    private func createDimensionBillboard() {
        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)

        let containerEntity = Entity()
        containerEntity.position = billboardPos

        // Format all dimension text
        let heightText = "H: \(formatDimension(height))"
        let depthText = "D: \(formatDimension(length))"
        let widthText = "W: \(formatDimension(width))"
        let volumeText = formatVolume()

        // Create multi-line text
        let fullText = "\(heightText)  \(widthText)  \(depthText)\n\(volumeText)"

        let textMesh = MeshResource.generateText(
            fullText,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: labelFontSize, weight: .medium),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        let textMaterial = UnlitMaterial(color: labelTextColor)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])

        // Get text bounds for background sizing
        let textBounds = textMesh.bounds
        let textWidth = textBounds.extents.x
        let textHeight = textBounds.extents.y

        // Create rounded rectangle background
        let padding: Float = 0.006
        let backgroundWidth = textWidth + padding * 2
        let backgroundHeight = textHeight + padding * 2
        let cornerRadius = min(backgroundHeight, backgroundWidth) * 0.15

        let backgroundMesh = MeshResource.generateBox(
            size: [backgroundWidth, backgroundHeight, 0.001],
            cornerRadius: cornerRadius
        )
        let backgroundMaterial = UnlitMaterial(color: labelBackgroundColor)
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])

        // Center the text and background
        backgroundEntity.position = SIMD3<Float>(textWidth / 2, textHeight / 2, -0.001)
        textEntity.position = SIMD3<Float>(0, 0, 0)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(textEntity)

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        dimensionBillboardEntity = containerEntity
    }

    private func formatDimension(_ meters: Float) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f %@", value, unit.rawValue)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, unit.rawValue)
        } else {
            return String(format: "%.2f %@", value, unit.rawValue)
        }
    }

    private func formatVolume() -> String {
        let cubicMeters = height * length * width
        let value = unit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            return String(format: "Vol: %.0f %@", value, unit.volumeUnit())
        } else if value >= 100 {
            return String(format: "Vol: %.1f %@", value, unit.volumeUnit())
        } else {
            return String(format: "Vol: %.2f %@", value, unit.volumeUnit())
        }
    }

    // MARK: - Helper Methods

    private func calculateOrientation(direction: SIMD3<Float>) -> simd_quatf {
        let defaultDirection = SIMD3<Float>(0, 0, 1)
        let normalizedDirection = simd_normalize(direction)
        let dot = simd_dot(defaultDirection, normalizedDirection)

        if dot > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }

        let axis = simd_cross(defaultDirection, normalizedDirection)
        let axisLength = simd_length(axis)
        if axisLength > 0.001 {
            return simd_quatf(angle: acos(simd_clamp(dot, -1, 1)), axis: axis / axisLength)
        }

        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
}

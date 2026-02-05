//
//  CompletedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Simplified visualization for saved/completed boxes
/// Shows edges and dimension labels only (no handles or rotation ring)
class CompletedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [ModelEntity] = []
    private var labelEntities: [Entity] = []

    private(set) var boundingBox: BoundingBox3D
    private let height: Float
    private let length: Float
    private let width: Float
    private let unit: MeasurementUnit

    // MARK: - Constants

    // White wireframe (same as BoxVisualization)
    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.5)
    private let lineRadius: Float = 0.0004  // Thin (0.4mm)

    // Label styling (Apple Measure style - matching BoxVisualization)
    private let labelFontSize: CGFloat = 0.010
    private let labelBackgroundColor: UIColor = UIColor(white: 0.0, alpha: 0.4)
    private let labelTextColor: UIColor = UIColor(white: 1.0, alpha: 0.85)
    private let labelOffset: Float = 0.02  // 2cm offset from edge

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

    /// Update label orientations to face the camera (billboard effect)
    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        for label in labelEntities {
            let labelWorldPos = label.position(relativeTo: nil)
            let toCamera = cameraPosition - labelWorldPos
            let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

            if simd_length(toCameraHorizontal) > 0.01 {
                let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
                label.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        }
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createDimensionLabels()
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

    // MARK: - Dimension Labels

    private func createDimensionLabels() {
        let edges = boundingBox.edges

        // Edge indices from BoundingBox3D:
        // Bottom face: (0,1), (1,2), (2,3), (3,0) - indices 0-3
        // Top face: (4,5), (5,6), (6,7), (7,4) - indices 4-7
        // Vertical edges: (0,4), (1,5), (2,6), (3,7) - indices 8-11

        // Height label: on a vertical edge (edge 8: corners 0-4)
        let heightEdge = edges[8]
        let heightMidpoint = (heightEdge.0 + heightEdge.1) / 2
        let heightLabelPos = heightMidpoint + boundingBox.localAxes.x * labelOffset
        let heightLabel = createLabelEntity(
            text: formatDimension(height),
            at: heightLabelPos
        )
        entity.addChild(heightLabel)
        labelEntities.append(heightLabel)

        // Length label: on top edge (edge 4: corners 4-5)
        let lengthEdge = edges[4]
        let lengthMidpoint = (lengthEdge.0 + lengthEdge.1) / 2
        let lengthLabelPos = lengthMidpoint + SIMD3<Float>(0, labelOffset * 0.75, 0)
        let lengthLabel = createLabelEntity(
            text: formatDimension(length),
            at: lengthLabelPos
        )
        entity.addChild(lengthLabel)
        labelEntities.append(lengthLabel)

        // Width label: on top edge perpendicular to length (edge 7: corners 7-4)
        let widthEdge = edges[7]
        let widthMidpoint = (widthEdge.0 + widthEdge.1) / 2
        let widthLabelPos = widthMidpoint + SIMD3<Float>(0, labelOffset * 0.75, 0)
        let widthLabel = createLabelEntity(
            text: formatDimension(width),
            at: widthLabelPos
        )
        entity.addChild(widthLabel)
        labelEntities.append(widthLabel)

        // Volume label: at box center
        let volumeLabel = createLabelEntity(
            text: formatVolume(),
            at: boundingBox.center
        )
        entity.addChild(volumeLabel)
        labelEntities.append(volumeLabel)
    }

    private func createLabelEntity(text: String, at position: SIMD3<Float>) -> Entity {
        let containerEntity = Entity()
        containerEntity.position = position

        // Create text mesh - Apple Measure style
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: labelFontSize, weight: .medium),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )

        let textMaterial = UnlitMaterial(color: labelTextColor)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])

        // Get text bounds for background sizing
        let textBounds = textMesh.bounds
        let textWidth = textBounds.extents.x
        let textHeight = textBounds.extents.y

        // Create pill-shaped background
        let padding: Float = 0.004
        let backgroundWidth = textWidth + padding * 2
        let backgroundHeight = textHeight + padding * 2
        let cornerRadius = backgroundHeight / 2

        let backgroundMesh = MeshResource.generateBox(
            size: [backgroundWidth, backgroundHeight, 0.001],
            cornerRadius: cornerRadius
        )
        let backgroundMaterial = UnlitMaterial(color: labelBackgroundColor)
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])

        // Position background behind text, centered
        backgroundEntity.position = SIMD3<Float>(textWidth / 2, textHeight / 2, -0.001)
        textEntity.position = SIMD3<Float>(0, 0, 0)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(textEntity)

        return containerEntity
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

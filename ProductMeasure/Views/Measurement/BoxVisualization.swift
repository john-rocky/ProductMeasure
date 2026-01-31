//
//  BoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box
class BoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var lineEntities: [Entity] = []
    private var handleEntities: [Entity] = []
    private var labelEntities: [Entity] = []

    private var boundingBox: BoundingBox3D

    // MARK: - Constants

    private let lineColor: UIColor = .systemBlue
    private let handleColor: UIColor = .systemYellow
    private let lineRadius: Float = 0.002
    private let handleRadius: Float = 0.01

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    func update(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        removeVisualization()
        createVisualization()
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createCornerHandles()
    }

    private func removeVisualization() {
        for child in entity.children {
            child.removeFromParent()
        }
        lineEntities.removeAll()
        handleEntities.removeAll()
        labelEntities.removeAll()
    }

    private func createEdges() {
        let edges = boundingBox.edges

        for (start, end) in edges {
            let lineEntity = createLineEntity(from: start, to: end)
            entity.addChild(lineEntity)
            lineEntities.append(lineEntity)
        }
    }

    private func createCornerHandles() {
        let corners = boundingBox.corners

        for corner in corners {
            let handleEntity = createHandleEntity(at: corner)
            entity.addChild(handleEntity)
            handleEntities.append(handleEntity)
        }
    }

    private func createLineEntity(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Entity {
        let direction = end - start
        let length = simd_length(direction)

        // Create a thin box as the line
        let mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])
        var material = SimpleMaterial()
        material.color = .init(tint: lineColor)

        let lineEntity = ModelEntity(mesh: mesh, materials: [material])

        // Position and orient the line
        let midpoint = (start + end) / 2
        lineEntity.position = midpoint

        // Calculate rotation to align with the line direction
        let defaultDirection = SIMD3<Float>(0, 0, 1)
        let normalizedDirection = simd_normalize(direction)

        if simd_length(normalizedDirection - defaultDirection) > 0.001 &&
           simd_length(normalizedDirection + defaultDirection) > 0.001 {
            let axis = simd_cross(defaultDirection, normalizedDirection)
            let axisLength = simd_length(axis)
            if axisLength > 0.001 {
                let normalizedAxis = axis / axisLength
                let angle = acos(simd_dot(defaultDirection, normalizedDirection))
                lineEntity.orientation = simd_quatf(angle: angle, axis: normalizedAxis)
            }
        } else if simd_length(normalizedDirection + defaultDirection) < 0.001 {
            // 180 degree rotation
            lineEntity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }

        return lineEntity
    }

    private func createHandleEntity(at position: SIMD3<Float>) -> Entity {
        let mesh = MeshResource.generateSphere(radius: handleRadius)
        var material = SimpleMaterial()
        material.color = .init(tint: handleColor)

        let handleEntity = ModelEntity(mesh: mesh, materials: [material])
        handleEntity.position = position

        return handleEntity
    }
}

// MARK: - Dimension Labels

extension BoxVisualization {
    func addDimensionLabels(unit: MeasurementUnit) {
        // Remove existing labels
        for label in labelEntities {
            label.removeFromParent()
        }
        labelEntities.removeAll()

        let corners = boundingBox.corners
        let dimensions = boundingBox.dimensions

        // Add labels for each dimension
        // Length label (between corners 0-1)
        let lengthMidpoint = (corners[0] + corners[1]) / 2
        let lengthLabel = createLabelEntity(
            text: formatDimension(dimensions.x, unit: unit),
            at: lengthMidpoint + SIMD3<Float>(0, 0.03, 0)
        )
        entity.addChild(lengthLabel)
        labelEntities.append(lengthLabel)

        // Width label (between corners 0-3)
        let widthMidpoint = (corners[0] + corners[3]) / 2
        let widthLabel = createLabelEntity(
            text: formatDimension(dimensions.y, unit: unit),
            at: widthMidpoint + SIMD3<Float>(0, 0.03, 0)
        )
        entity.addChild(widthLabel)
        labelEntities.append(widthLabel)

        // Height label (between corners 0-4)
        let heightMidpoint = (corners[0] + corners[4]) / 2
        let heightLabel = createLabelEntity(
            text: formatDimension(dimensions.z, unit: unit),
            at: heightMidpoint + SIMD3<Float>(0.03, 0, 0)
        )
        entity.addChild(heightLabel)
        labelEntities.append(heightLabel)
    }

    private func createLabelEntity(text: String, at position: SIMD3<Float>) -> Entity {
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.02),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )

        var material = SimpleMaterial()
        material.color = .init(tint: .white)

        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.position = position

        return textEntity
    }

    private func formatDimension(_ meters: Float, unit: MeasurementUnit) -> String {
        let value = unit.convert(meters: meters)
        return String(format: "%.1f %@", value, unit.rawValue)
    }
}

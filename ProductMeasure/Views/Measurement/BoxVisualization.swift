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
    private var edgeEntities: [ModelEntity] = []  // 12 edge entities
    private var faceHandleEntities: [Entity] = [] // 6 face handles
    private var rotationRingEntity: Entity?       // Rotation ring on top
    private var labelEntities: [Entity] = []
    private var floorDistanceEntity: Entity?      // Floor distance indicator
    private var floorDistanceLabel: Entity?

    private(set) var boundingBox: BoundingBox3D

    /// Floor Y position (default 0)
    var floorY: Float = 0 {
        didSet {
            updateFloorDistanceIndicator()
        }
    }

    /// Whether handles are interactive (draggable)
    var isInteractive: Bool = false {
        didSet {
            if oldValue != isInteractive {
                updateInteractiveState()
            }
        }
    }

    // MARK: - Constants

    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.9)  // Clean white
    private let lineRadius: Float = 0.0008  // Very thin (0.8mm)

    // Face handle colors by axis (vibrant but not too saturated)
    private let xAxisColor: UIColor = UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
    private let yAxisColor: UIColor = UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1.0)
    private let zAxisColor: UIColor = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0)

    // Handle dimensions
    private let handleSize: Float = 0.006        // Size of face handle sphere (6mm)
    private let handleCollisionRadius: Float = 0.012  // Larger for easy touch
    private let ringRadius: Float = 0.015        // Rotation ring radius
    private let ringThickness: Float = 0.003

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D, interactive: Bool = false) {
        self.boundingBox = boundingBox
        self.isInteractive = interactive
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    func update(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        updateEdgePositions()
        updateFaceHandlePositions()
        updateRotationRingPosition()
        updateFloorDistanceIndicator()
    }

    /// Identify what was hit: face handle, rotation ring, or nothing
    enum HitType {
        case faceHandle(HandleType)
        case rotationRing
        case none
    }

    /// Parse entity name to determine hit type
    static func parseHit(entityName: String) -> HitType {
        if let handleType = HandleType.from(name: entityName) {
            return .faceHandle(handleType)
        }
        if entityName == "rotation_ring" {
            return .rotationRing
        }
        return .none
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createFaceHandles()
        createRotationRing()
        createFloorDistanceIndicator()
        updateInteractiveState()
    }

    private func updateInteractiveState() {
        // Show/hide face handles and rotation ring
        for handle in faceHandleEntities {
            handle.isEnabled = isInteractive
        }
        rotationRingEntity?.isEnabled = isInteractive
    }

    private func removeVisualization() {
        for child in entity.children {
            child.removeFromParent()
        }
        edgeEntities.removeAll()
        faceHandleEntities.removeAll()
        rotationRingEntity = nil
        floorDistanceEntity = nil
        floorDistanceLabel = nil
        labelEntities.removeAll()
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

    private func updateEdgePositions() {
        let edges = boundingBox.edges

        guard edgeEntities.count == edges.count else {
            for edge in edgeEntities { edge.removeFromParent() }
            edgeEntities.removeAll()
            createEdges()
            return
        }

        for (index, (start, end)) in edges.enumerated() {
            updateEdgeEntity(edgeEntities[index], from: start, to: end)
        }
    }

    private func createEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> ModelEntity {
        let direction = end - start
        let length = simd_length(direction)

        let mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])
        var material = SimpleMaterial()
        material.color = .init(tint: lineColor)

        let edgeEntity = ModelEntity(mesh: mesh, materials: [material])
        edgeEntity.name = "edge_\(index)"
        edgeEntity.position = (start + end) / 2
        edgeEntity.orientation = calculateOrientation(direction: direction)

        return edgeEntity
    }

    private func updateEdgeEntity(_ edgeEntity: ModelEntity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let direction = end - start
        let length = simd_length(direction)

        edgeEntity.position = (start + end) / 2
        edgeEntity.model?.mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])
        edgeEntity.orientation = calculateOrientation(direction: direction)
    }

    // MARK: - Face Handle Creation

    private func createFaceHandles() {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        for handleType in handleTypes {
            let handleEntity = createFaceHandleEntity(for: handleType)
            entity.addChild(handleEntity)
            faceHandleEntities.append(handleEntity)
        }
    }

    private func createFaceHandleEntity(for handleType: HandleType) -> Entity {
        let parentEntity = Entity()
        parentEntity.name = handleType.entityName

        // Determine color based on axis
        let color: UIColor
        switch handleType {
        case .faceNegX, .facePosX: color = xAxisColor
        case .faceNegY, .facePosY: color = yAxisColor
        case .faceNegZ, .facePosZ: color = zAxisColor
        default: color = .white
        }

        // Create sphere handle
        let sphereMesh = MeshResource.generateSphere(radius: handleSize)
        var material = SimpleMaterial()
        material.color = .init(tint: color)
        let sphereEntity = ModelEntity(mesh: sphereMesh, materials: [material])

        // Add direction indicator (small arrow/pointer)
        let pointerMesh = MeshResource.generateBox(size: [handleSize * 0.3, handleSize * 0.3, handleSize * 0.8])
        let pointerEntity = ModelEntity(mesh: pointerMesh, materials: [material])
        pointerEntity.position = SIMD3<Float>(0, 0, handleSize * 0.6)

        parentEntity.addChild(sphereEntity)
        parentEntity.addChild(pointerEntity)

        // Add collision
        let collisionShape = ShapeResource.generateSphere(radius: handleCollisionRadius)
        parentEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        // Set position and orientation
        let localPos = handleType.localPosition(extents: boundingBox.extents)
        parentEntity.position = boundingBox.localToWorld(localPos)
        parentEntity.orientation = calculateHandleOrientation(for: handleType)

        parentEntity.isEnabled = isInteractive

        return parentEntity
    }

    private func updateFaceHandlePositions() {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        for (index, handleType) in handleTypes.enumerated() {
            guard index < faceHandleEntities.count else { continue }

            let localPos = handleType.localPosition(extents: boundingBox.extents)
            faceHandleEntities[index].position = boundingBox.localToWorld(localPos)
            faceHandleEntities[index].orientation = calculateHandleOrientation(for: handleType)
        }
    }

    private func calculateHandleOrientation(for handleType: HandleType) -> simd_quatf {
        let axes = boundingBox.localAxes

        let targetDirection: SIMD3<Float>
        switch handleType {
        case .faceNegX: targetDirection = -axes.x
        case .facePosX: targetDirection = axes.x
        case .faceNegY: targetDirection = -axes.y
        case .facePosY: targetDirection = axes.y
        case .faceNegZ: targetDirection = -axes.z
        case .facePosZ: targetDirection = axes.z
        default: return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        return calculateOrientation(direction: targetDirection)
    }

    // MARK: - Rotation Ring Creation

    private func createRotationRing() {
        let ringEntity = Entity()
        ringEntity.name = "rotation_ring"

        // Create ring segments (approximate circle with boxes)
        let segmentCount = 16
        let angleStep = Float.pi * 2 / Float(segmentCount)

        for i in 0..<segmentCount {
            let angle = Float(i) * angleStep
            let nextAngle = Float(i + 1) * angleStep

            let segmentLength = ringRadius * angleStep * 1.1
            let segmentMesh = MeshResource.generateBox(size: [ringThickness, ringThickness, segmentLength])

            var material = SimpleMaterial()
            material.color = .init(tint: .systemOrange)

            let segmentEntity = ModelEntity(mesh: segmentMesh, materials: [material])

            // Position at midpoint of arc
            let midAngle = (angle + nextAngle) / 2
            segmentEntity.position = SIMD3<Float>(
                cos(midAngle) * ringRadius,
                0,
                sin(midAngle) * ringRadius
            )

            // Rotate to be tangent to circle
            segmentEntity.orientation = simd_quatf(angle: -midAngle, axis: SIMD3<Float>(0, 1, 0))

            ringEntity.addChild(segmentEntity)
        }

        // Add collision (torus approximated as flat ring)
        let collisionShape = ShapeResource.generateBox(size: [ringRadius * 2.2, ringThickness * 3, ringRadius * 2.2])
        ringEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        updateRotationRingTransform(ringEntity)
        ringEntity.isEnabled = isInteractive

        entity.addChild(ringEntity)
        rotationRingEntity = ringEntity
    }

    private func updateRotationRingPosition() {
        guard let ringEntity = rotationRingEntity else { return }
        updateRotationRingTransform(ringEntity)
    }

    private func updateRotationRingTransform(_ ringEntity: Entity) {
        // Position above the top face
        let topFaceY = boundingBox.extents.y
        let localPos = SIMD3<Float>(0, topFaceY + handleSize * 1.5, 0)
        ringEntity.position = boundingBox.localToWorld(localPos)

        // Align with box rotation (only horizontal rotation)
        ringEntity.orientation = boundingBox.rotation
    }

    // MARK: - Floor Distance Indicator

    private func createFloorDistanceIndicator() {
        let indicatorEntity = Entity()
        indicatorEntity.name = "floor_distance"
        entity.addChild(indicatorEntity)
        floorDistanceEntity = indicatorEntity

        updateFloorDistanceIndicator()
    }

    private func updateFloorDistanceIndicator() {
        guard let indicatorEntity = floorDistanceEntity else { return }

        // Remove old children
        for child in indicatorEntity.children {
            child.removeFromParent()
        }

        // Calculate bottom center of box
        let bottomLocalY = -boundingBox.extents.y
        let bottomCenter = boundingBox.localToWorld(SIMD3<Float>(0, bottomLocalY, 0))

        // Distance to floor
        let distanceToFloor = bottomCenter.y - floorY

        // Only show if box is above floor
        guard distanceToFloor > 0.001 else {
            indicatorEntity.isEnabled = false
            return
        }
        indicatorEntity.isEnabled = true

        // Create vertical dashed line from bottom to floor
        let floorPoint = SIMD3<Float>(bottomCenter.x, floorY, bottomCenter.z)
        let lineHeight = distanceToFloor

        // Create line segments (dashed effect)
        let dashLength: Float = 0.01
        let gapLength: Float = 0.008
        let segmentLength = dashLength + gapLength
        let numSegments = Int(lineHeight / segmentLength)

        for i in 0..<max(1, numSegments) {
            let segmentY = floorY + Float(i) * segmentLength + dashLength / 2
            if segmentY > bottomCenter.y { break }

            let dashMesh = MeshResource.generateBox(size: [0.001, dashLength, 0.001])
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor(white: 0.8, alpha: 0.7))

            let dashEntity = ModelEntity(mesh: dashMesh, materials: [material])
            dashEntity.position = SIMD3<Float>(bottomCenter.x, segmentY, bottomCenter.z)
            indicatorEntity.addChild(dashEntity)
        }

        // Create distance label
        let labelPosition = SIMD3<Float>(bottomCenter.x + 0.02, (bottomCenter.y + floorY) / 2, bottomCenter.z)
        let distanceCm = distanceToFloor * 100
        let labelText = String(format: "%.1f cm", distanceCm)

        let textMesh = MeshResource.generateText(
            labelText,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.012, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )

        var textMaterial = SimpleMaterial()
        textMaterial.color = .init(tint: UIColor(white: 0.9, alpha: 0.9))

        let labelEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        labelEntity.position = labelPosition
        indicatorEntity.addChild(labelEntity)

        // Small floor marker
        let markerMesh = MeshResource.generateBox(size: [0.02, 0.001, 0.02])
        var markerMaterial = SimpleMaterial()
        markerMaterial.color = .init(tint: UIColor(white: 0.7, alpha: 0.5))

        let markerEntity = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
        markerEntity.position = floorPoint
        indicatorEntity.addChild(markerEntity)
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

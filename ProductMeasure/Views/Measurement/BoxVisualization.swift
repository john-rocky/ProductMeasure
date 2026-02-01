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

    // Handle color (white, semi-transparent for Apple-style appearance)
    private let handleColor: UIColor = UIColor(white: 1.0, alpha: 0.85)

    // Handle dimensions (capsule shape)
    private let handleLength: Float = 0.018      // Length of capsule (18mm)
    private let handleRadius: Float = 0.004      // Radius of capsule (4mm)
    private let handleCollisionRadius: Float = 0.015  // Larger for easy touch

    // Rotation handle (circular arrow at bottom corner)
    private let rotationArcRadius: Float = 0.014     // Arc radius (14mm)
    private let rotationArcThickness: Float = 0.002  // Arc thickness (2mm)
    private let rotationArcAngle: Float = .pi * 1.2  // 216 degree arc

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

    /// Highlight a handle to show it's being touched
    func highlightHandle(_ handleType: HandleType) {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        guard let index = handleTypes.firstIndex(of: handleType),
              index < faceHandleEntities.count else { return }

        let handle = faceHandleEntities[index]
        handle.scale = SIMD3<Float>(repeating: 1.3)  // Scale up 30%
    }

    /// Highlight rotation handle
    func highlightRotationHandle() {
        rotationRingEntity?.scale = SIMD3<Float>(repeating: 1.3)
    }

    /// Remove all handle highlights
    func unhighlightAllHandles() {
        for handle in faceHandleEntities {
            handle.scale = SIMD3<Float>(repeating: 1.0)
        }
        rotationRingEntity?.scale = SIMD3<Float>(repeating: 1.0)
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

        // Create clean capsule handle using a single rounded box
        var material = SimpleMaterial()
        material.color = .init(tint: handleColor)

        // Single rounded box with full corner radius for smooth capsule appearance
        let capsuleMesh = MeshResource.generateBox(
            size: [handleRadius * 2, handleRadius * 2, handleLength],
            cornerRadius: handleRadius
        )
        let capsuleEntity = ModelEntity(mesh: capsuleMesh, materials: [material])

        parentEntity.addChild(capsuleEntity)

        // Add collision (capsule approximated as box)
        let collisionShape = ShapeResource.generateCapsule(height: handleLength, radius: handleCollisionRadius)
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

        // Capsule default orientation is along Z axis
        // For edge handles, orient along the edge direction
        // For face handles (Y), orient perpendicular to the face (up/down)
        let targetDirection: SIMD3<Float>
        switch handleType {
        case .faceNegX, .facePosX:
            // X edge handles on top face - orient along Z axis (edge direction)
            targetDirection = axes.z
        case .faceNegZ, .facePosZ:
            // Z edge handles on top face - orient along X axis (edge direction)
            targetDirection = axes.x
        case .faceNegY, .facePosY:
            // Y handles (top/bottom center) - orient along X axis (horizontal capsule)
            targetDirection = axes.x
        default:
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        return calculateOrientation(direction: targetDirection)
    }

    // MARK: - Rotation Handle Creation (Smooth torus arc at bottom corner)

    private func createRotationRing() {
        let handleEntity = Entity()
        handleEntity.name = "rotation_ring"

        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(white: 1.0, alpha: 0.5))  // Lighter, more transparent

        // Create smooth torus arc mesh
        if let torusMesh = createTorusArcMesh(
            majorRadius: rotationArcRadius,
            minorRadius: rotationArcThickness / 2,
            startAngle: -.pi / 6,
            arcAngle: rotationArcAngle
        ) {
            let torusEntity = ModelEntity(mesh: torusMesh, materials: [material])
            handleEntity.addChild(torusEntity)
        }

        // Add arrow head at the end of the arc
        let endAngle: Float = -.pi / 6 + rotationArcAngle
        let arrowSize: Float = rotationArcThickness * 2.0

        // Create triangular arrow using a flattened box rotated
        let arrowMesh = MeshResource.generateBox(
            size: [arrowSize * 1.8, rotationArcThickness * 0.8, arrowSize * 1.8],
            cornerRadius: rotationArcThickness / 4
        )
        let arrowHead = ModelEntity(mesh: arrowMesh, materials: [material])

        // Position at end of arc, slightly outward
        arrowHead.position = SIMD3<Float>(
            cos(endAngle) * rotationArcRadius,
            0,
            sin(endAngle) * rotationArcRadius
        )

        // Rotate to point tangentially (like an arrow head)
        // Rotate 45 degrees to make diamond shape pointing in arc direction
        let tangentAngle = endAngle + .pi / 2
        arrowHead.orientation = simd_quatf(angle: tangentAngle + .pi / 4, axis: SIMD3<Float>(0, 1, 0))

        handleEntity.addChild(arrowHead)

        // Add collision
        let collisionShape = ShapeResource.generateBox(
            size: [rotationArcRadius * 2, rotationArcThickness * 4, rotationArcRadius * 2]
        )
        handleEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        updateRotationRingTransform(handleEntity)
        handleEntity.isEnabled = isInteractive

        entity.addChild(handleEntity)
        rotationRingEntity = handleEntity
    }

    /// Create a smooth torus arc mesh
    private func createTorusArcMesh(
        majorRadius: Float,
        minorRadius: Float,
        startAngle: Float,
        arcAngle: Float
    ) -> MeshResource? {
        let majorSegments = 32  // Segments along the arc
        let minorSegments = 12  // Segments around the tube

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        // Generate vertices
        for i in 0...majorSegments {
            let majorAngle = startAngle + arcAngle * Float(i) / Float(majorSegments)
            let majorCos = cos(majorAngle)
            let majorSin = sin(majorAngle)

            // Center of tube at this point
            let centerX = majorCos * majorRadius
            let centerZ = majorSin * majorRadius

            for j in 0...minorSegments {
                let minorAngle = 2.0 * .pi * Float(j) / Float(minorSegments)
                let minorCos = cos(minorAngle)
                let minorSin = sin(minorAngle)

                // Position on tube surface
                let x = centerX + majorCos * minorRadius * minorCos
                let y = minorRadius * minorSin
                let z = centerZ + majorSin * minorRadius * minorCos

                positions.append(SIMD3<Float>(x, y, z))

                // Normal points outward from tube center
                let nx = majorCos * minorCos
                let ny = minorSin
                let nz = majorSin * minorCos
                normals.append(SIMD3<Float>(nx, ny, nz))

                // UV coordinates
                let u = Float(i) / Float(majorSegments)
                let v = Float(j) / Float(minorSegments)
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        // Generate indices
        let minorCount = minorSegments + 1
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let current = UInt32(i * minorCount + j)
                let next = UInt32((i + 1) * minorCount + j)

                // Two triangles per quad
                indices.append(current)
                indices.append(next)
                indices.append(current + 1)

                indices.append(current + 1)
                indices.append(next)
                indices.append(next + 1)
            }
        }

        // Create mesh descriptor
        var descriptor = MeshDescriptor(name: "torusArc")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [descriptor])
    }

    private func updateRotationRingPosition() {
        guard let ringEntity = rotationRingEntity else { return }
        updateRotationRingTransform(ringEntity)
    }

    private func updateRotationRingTransform(_ ringEntity: Entity) {
        // Position at bottom corner (outside the box)
        let bottomY = -boundingBox.extents.y
        let cornerOffset = max(boundingBox.extents.x, boundingBox.extents.z) + rotationArcRadius * 0.5
        let localPos = SIMD3<Float>(cornerOffset, bottomY, cornerOffset)
        ringEntity.position = boundingBox.localToWorld(localPos)

        // Align with box rotation
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

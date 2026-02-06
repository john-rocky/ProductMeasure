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

    // Single billboard label floating above the box (shows all dimensions)
    private var dimensionBillboardEntity: Entity?

    // Action icon row (below billboard)
    private var actionIconRow: Entity?

    /// Current action mode (normal or editing)
    enum ActionMode {
        case normal
        case editing
    }
    private var currentActionMode: ActionMode = .normal

    // Box identifier
    private var boxId: Int = 0

    // Stored dimensions for label updates
    private var storedHeight: Float = 0
    private var storedLength: Float = 0
    private var storedWidth: Float = 0
    private var storedUnit: MeasurementUnit = .centimeters

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

    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.5)  // Semi-transparent white
    private let lineRadius: Float = 0.0004  // Very thin (0.4mm)

    // Handle color (white, semi-transparent for Apple-style appearance)
    private let handleColor: UIColor = UIColor(white: 1.0, alpha: 0.85)

    // Handle dimensions (capsule shape)
    private let handleLength: Float = 0.018      // Length of capsule (18mm)
    private let handleRadius: Float = 0.004      // Radius of capsule (4mm)
    private let handleCollisionRadius: Float = 0.015  // Larger for easy touch

    // Dimension label styling
    private let billboardIdFontSize: CGFloat = 0.010      // Box ID header
    private let billboardBodyFontSize: CGFloat = 0.007    // Detail lines
    private let dimensionLabelTextColor: UIColor = UIColor(white: 1.0, alpha: 0.95)  // White text
    private let billboardSubTextColor: UIColor = UIColor(white: 1.0, alpha: 0.7)     // Dimmed white
    private let dimensionLabelBackgroundColor: UIColor = UIColor(white: 0.0, alpha: 0.75) // Dark glass
    private let billboardAccentColor: UIColor = UIColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0) // Cyan accent

    // Rotation handle (corner arc that looks like part of the box frame)
    private let rotationArcThickness: Float = 0.001  // Same thickness as edge lines
    private let rotationArcAngle: Float = .pi / 2    // 90 degree arc (quarter circle at corner)

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
        updateDimensionLabelPositions()
    }

    /// Set dimensions and create/update labels on the wireframe
    func setDimensions(height: Float, length: Float, width: Float, unit: MeasurementUnit, boxId: Int = 0) {
        self.boxId = boxId
        storedHeight = height
        storedLength = length
        storedWidth = width
        storedUnit = unit
        createDimensionLabels()
    }

    /// Update dimensions when box is edited (recreates labels with new values)
    func updateDimensions(height: Float, length: Float, width: Float) {
        storedHeight = height
        storedLength = length
        storedWidth = width
        createDimensionLabels()
    }

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
    /// - Parameters:
    ///   - visible: Whether the billboard should be visible
    ///   - forceShow: If true, always show regardless of prominence logic
    func setDimensionBillboardVisible(_ visible: Bool, forceShow: Bool = false) {
        dimensionBillboardEntity?.isEnabled = forceShow || visible
    }

    /// Update the action icon row to match the current mode
    func updateActionMode(_ mode: ActionMode) {
        currentActionMode = mode
        // Remove existing action row
        actionIconRow?.removeFromParent()
        actionIconRow = nil

        guard let billboard = dimensionBillboardEntity else { return }

        // Create new action row for the mode
        let actions: [ActionIconConfig]
        switch mode {
        case .normal:
            actions = ActionIconBuilder.activeNormalActions
        case .editing:
            actions = ActionIconBuilder.activeEditActions
        }

        let row = ActionIconBuilder.createActionRow(actions: actions)
        // Position below the billboard (5mm below bottom edge)
        row.position = SIMD3<Float>(0, -0.005, 0)
        billboard.addChild(row)
        actionIconRow = row
    }

    /// Check if this box is visible (for determining which box to show billboard on)
    func isVisibleFromCamera(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) -> Bool {
        let toBox = boundingBox.center - cameraPosition
        let distance = simd_length(toBox)
        let toBoxNormalized = toBox / distance

        // Check if box is in front of camera (dot product > 0)
        let dot = simd_dot(toBoxNormalized, cameraForward)
        return dot > 0.3  // Within ~70 degree cone in front
    }

    /// Get the apparent size of this box from the camera (larger = more prominent)
    func apparentSizeFromCamera(cameraPosition: SIMD3<Float>) -> Float {
        let distance = simd_length(boundingBox.center - cameraPosition)
        if distance < 0.01 { return 0 }

        // Approximate apparent size: box volume / distance^2
        let boxSize = boundingBox.extents.x * boundingBox.extents.y * boundingBox.extents.z
        return boxSize / (distance * distance)
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
        dimensionBillboardEntity = nil
        actionIconRow = nil
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
        var material = UnlitMaterial(color: lineColor)

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
        var material = UnlitMaterial(color: handleColor)

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

        // Use same semi-transparent white as edges for consistency
        var material = UnlitMaterial(color: UIColor(white: 1.0, alpha: 0.6))

        // Arc radius will be calculated based on box size in updateRotationRingTransform
        // Use a placeholder radius here, it will be updated
        let placeholderRadius: Float = 0.03

        // Create smooth torus arc mesh (quarter circle at corner)
        if let torusMesh = createTorusArcMesh(
            majorRadius: placeholderRadius,
            minorRadius: rotationArcThickness,
            startAngle: 0,
            arcAngle: rotationArcAngle
        ) {
            let torusEntity = ModelEntity(mesh: torusMesh, materials: [material])
            torusEntity.name = "rotation_arc"
            handleEntity.addChild(torusEntity)
        }

        // Add small arrow indicators at both ends to show rotation direction
        let arrowSize: Float = 0.004
        let arrowMesh = MeshResource.generateBox(
            size: [arrowSize, arrowSize * 0.5, arrowSize],
            cornerRadius: arrowSize * 0.2
        )

        // Arrow at the end of arc (pointing in rotation direction)
        let arrowHead = ModelEntity(mesh: arrowMesh, materials: [material])
        arrowHead.name = "rotation_arrow"
        arrowHead.position = SIMD3<Float>(0, 0, placeholderRadius)
        arrowHead.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        handleEntity.addChild(arrowHead)

        // Add collision for touch detection
        let collisionShape = ShapeResource.generateBox(
            size: [placeholderRadius * 2.5, 0.02, placeholderRadius * 2.5]
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
        // Calculate arc radius based on box size (proportional to smaller horizontal dimension)
        let arcRadius = min(boundingBox.extents.x, boundingBox.extents.z) * 0.4

        // Position at bottom corner of the box (+X, -Y, +Z corner)
        // The arc connects the X edge to the Z edge at this corner
        let bottomY = -boundingBox.extents.y
        let cornerX = boundingBox.extents.x
        let cornerZ = boundingBox.extents.z
        let localPos = SIMD3<Float>(cornerX, bottomY, cornerZ)
        ringEntity.position = boundingBox.localToWorld(localPos)

        // Align with box rotation - arc should extend outward from corner
        // No additional rotation needed since arc naturally goes from +X to +Z direction
        ringEntity.orientation = boundingBox.rotation

        // Update the arc mesh with correct radius
        if let arcEntity = ringEntity.children.first(where: { $0.name == "rotation_arc" }) as? ModelEntity {
            if let newMesh = createTorusArcMesh(
                majorRadius: arcRadius,
                minorRadius: rotationArcThickness,
                startAngle: 0,
                arcAngle: rotationArcAngle
            ) {
                arcEntity.model?.mesh = newMesh
            }
        }

        // Update arrow position
        if let arrowEntity = ringEntity.children.first(where: { $0.name == "rotation_arrow" }) as? ModelEntity {
            arrowEntity.position = SIMD3<Float>(0, 0, arcRadius)
        }

        // Update collision size
        let collisionShape = ShapeResource.generateBox(
            size: [arcRadius * 2.5, 0.02, arcRadius * 2.5]
        )
        ringEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
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
            var material = UnlitMaterial(color: UIColor(white: 0.8, alpha: 0.7))

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

        var textMaterial = UnlitMaterial(color: UIColor(white: 0.9, alpha: 0.9))

        let labelEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        labelEntity.position = labelPosition
        indicatorEntity.addChild(labelEntity)

        // Small floor marker
        let markerMesh = MeshResource.generateBox(size: [0.02, 0.001, 0.02])
        var markerMaterial = UnlitMaterial(color: UIColor(white: 0.7, alpha: 0.5))

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

    // MARK: - Dimension Billboard (floating above box)

    private func createDimensionLabels() {
        // Remove existing billboard and action row
        dimensionBillboardEntity?.removeFromParent()
        actionIconRow = nil

        // Create billboard above the box showing all dimensions
        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        dimensionBillboardEntity = createDimensionBillboard(at: billboardPos)
        entity.addChild(dimensionBillboardEntity!)

        // Add action icons below billboard
        updateActionMode(currentActionMode)

        // Active box billboard is always visible (forceShow)
        dimensionBillboardEntity?.isEnabled = true
    }

    private func updateDimensionLabelPositions() {
        guard storedHeight > 0 else { return }  // Labels not yet created

        // Update billboard position - above box top
        if let billboard = dimensionBillboardEntity {
            billboard.position = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        }
    }

    private func createDimensionBillboard(at position: SIMD3<Float>) -> Entity {
        let containerEntity = Entity()
        containerEntity.position = position

        let cubicMeters = storedHeight * storedLength * storedWidth
        let accentBarWidth: Float = 0.0015
        let padding: Float = 0.005
        let innerPadding: Float = 0.003  // Space between accent bar and text

        // -- Header: Box ID (larger, bold) --
        let idText = String(format: "#%03d", boxId)
        let idMesh = MeshResource.generateText(
            idText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardIdFontSize, weight: .bold),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        let idMaterial = UnlitMaterial(color: billboardAccentColor)
        let idEntity = ModelEntity(mesh: idMesh, materials: [idMaterial])
        let idWidth = idMesh.bounds.extents.x
        let idHeight = idMesh.bounds.extents.y

        // -- Body: detail lines (smaller) --
        let lVal = formatDimensionValue(storedLength)
        let wVal = formatDimensionValue(storedWidth)
        let hVal = formatDimensionValue(storedHeight)
        let dimLine = "L: \(lVal)  W: \(wVal)  H: \(hVal) \(storedUnit.rawValue)"

        let volText = formatVolumeValue(cubicMeters)
        let wgtText = storedUnit.formatVolumetricWeight(cubicMeters: cubicMeters)
        let volLine = "\(volText)  Wgt: \(wgtText)"

        let sizeClass = SizeClass.classify(volumeCubicMeters: cubicMeters)
        let classLine = "Class: \(sizeClass.displayName)"

        let bodyText = "\(dimLine)\n\(volLine)\n\(classLine)"
        let bodyMesh = MeshResource.generateText(
            bodyText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardBodyFontSize, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byWordWrapping
        )
        let bodyMaterial = UnlitMaterial(color: dimensionLabelTextColor)
        let bodyEntity = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
        let bodyWidth = bodyMesh.bounds.extents.x
        let bodyHeight = bodyMesh.bounds.extents.y

        // -- Layout calculation --
        let gap: Float = 0.003  // Gap between header and body
        let contentWidth = max(idWidth, bodyWidth)
        let contentHeight = idHeight + gap + bodyHeight
        let totalWidth = accentBarWidth + innerPadding + contentWidth + padding * 2
        let totalHeight = contentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.12

        // -- Background (dark glass) --
        let backgroundMesh = MeshResource.generateBox(
            size: [totalWidth, totalHeight, 0.001],
            cornerRadius: cornerRadius
        )
        var backgroundMaterial = UnlitMaterial(color: dimensionLabelBackgroundColor)
        backgroundMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.75))
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])

        // -- Accent bar (left edge stripe) --
        let accentHeight = contentHeight + padding
        let accentMesh = MeshResource.generateBox(
            size: [accentBarWidth, accentHeight, 0.0015],
            cornerRadius: accentBarWidth * 0.4
        )
        let accentMaterial = UnlitMaterial(color: billboardAccentColor)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [accentMaterial])

        // -- Position everything centered on container origin --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        backgroundEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)
        idEntity.position = SIMD3<Float>(textLeftX, padding + bodyHeight + gap, 0)
        bodyEntity.position = SIMD3<Float>(textLeftX, padding, 0)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(idEntity)
        containerEntity.addChild(bodyEntity)

        return containerEntity
    }

    /// Format dimension value without unit suffix (unit shown once at end of line)
    private func formatDimensionValue(_ meters: Float) -> String {
        let value = storedUnit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func formatVolumeValue(_ cubicMeters: Float) -> String {
        let value = storedUnit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
            return "Vol: \(formatted) \(storedUnit.volumeUnit())"
        } else if value >= 100 {
            return String(format: "Vol: %.1f %@", value, storedUnit.volumeUnit())
        } else {
            return String(format: "Vol: %.2f %@", value, storedUnit.volumeUnit())
        }
    }
}

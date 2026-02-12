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
    private var edgeEntities: [Entity] = []          // 12 dual-layer edge groups
    private var cornerMarkerEntities: [ModelEntity] = [] // 8 corner spheres
    private var faceHandleEntities: [Entity] = []    // 6 face handles
    private var rotationRingEntity: Entity?          // Rotation ring on top
    private var labelEntities: [Entity] = []
    private var floorDistanceEntity: Entity?         // Floor distance indicator
    private var floorDistanceLabel: Entity?

    // Size billboard (above box): dimensions, volume, weight, quality
    private var sizeBillboardEntity: Entity?
    // Label billboard (left of box): CTN ID, BARCODE, DEST, etc.
    private var labelBillboardEntity: Entity?

    // Action icon row (below size billboard)
    private var actionIconRow: Entity?

    /// Current action mode
    enum ActionMode {
        case normal
        case normalNoRefine
        case editing
        case refining
    }
    private var currentActionMode: ActionMode = .normal

    // Box identifier
    private var boxId: Int = 0

    // Stored dimensions for label updates
    private var storedHeight: Float = 0
    private var storedLength: Float = 0
    private var storedWidth: Float = 0
    private var storedUnit: MeasurementUnit = .centimeters

    // Stored console data for billboard
    private var storedQualityLabel: String = ""
    private var storedPointCount: Int = 0
    private var storedLabelData: LabelData?

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

    // Dual-layer edge: inner bright + outer glow
    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInner
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuter
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius

    // Corner markers
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadius
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarker

    // Handle color (white, semi-transparent for Apple-style appearance)
    private let handleColor: UIColor = UIColor(white: 1.0, alpha: 0.85)

    // Handle dimensions (capsule shape)
    private let handleLength: Float = 0.018
    private let handleRadius: Float = 0.004
    private let handleCollisionRadius: Float = 0.015

    // Billboard common styling
    private let dimensionLabelTextColor: UIColor = PMTheme.uiBillboardText
    private let dimensionLabelBackgroundColor: UIColor = PMTheme.uiBillboardBg
    private let billboardAccentColor: UIColor = PMTheme.uiBillboardAccent
    private let billboardTopBorderColor: UIColor = PMTheme.uiBillboardTopBorder

    // Size panel font sizes
    private let sizePanelIdFontSize: CGFloat = 0.014
    private let sizePanelDimensionFontSize: CGFloat = 0.018
    private let sizePanelSecondaryFontSize: CGFloat = 0.009
    private let sizePanelBadgeFontSize: CGFloat = 0.010

    // Label panel font sizes
    private let labelPanelTitleFontSize: CGFloat = 0.008
    private let labelPanelPrimaryValueFontSize: CGFloat = 0.014
    private let labelPanelPrimaryLabelFontSize: CGFloat = 0.008
    private let labelPanelSecondaryFontSize: CGFloat = 0.009

    // Rotation handle
    private let rotationArcThickness: Float = 0.001
    private let rotationArcAngle: Float = .pi / 2

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
        updateCornerMarkerPositions()
        updateFaceHandlePositions()
        updateRotationRingPosition()
        updateFloorDistanceIndicator()
        updateDimensionLabelPositions()
    }

    /// Set dimensions and create/update labels on the wireframe
    func setDimensions(height: Float, length: Float, width: Float, unit: MeasurementUnit, boxId: Int = 0,
                       qualityLabel: String = "", pointCount: Int = 0, labelData: LabelData? = nil) {
        self.boxId = boxId
        storedHeight = height
        storedLength = length
        storedWidth = width
        storedUnit = unit
        storedQualityLabel = qualityLabel
        storedPointCount = pointCount
        storedLabelData = labelData
        createDimensionLabels()
    }

    /// Update dimensions when box is edited (recreates labels with new values)
    func updateDimensions(height: Float, length: Float, width: Float) {
        storedHeight = height
        storedLength = length
        storedWidth = width
        createDimensionLabels()
    }

    /// Update billboard orientations to face the camera; reposition label panel to left side
    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        // Orient size billboard to face camera (Y-axis rotation only)
        if let sizePanel = sizeBillboardEntity {
            let pos = sizePanel.position(relativeTo: nil)
            let toCamera = cameraPosition - pos
            let horizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)
            if simd_length(horizontal) > 0.01 {
                let angle = atan2(horizontal.x, horizontal.z)
                sizePanel.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        }

        // Orient + reposition label billboard to stay on the left from camera's perspective
        if let labelPanel = labelBillboardEntity {
            let boxCenter = boundingBox.center
            let toCamera = cameraPosition - boxCenter
            let forward = SIMD3<Float>(toCamera.x, 0, toCamera.z)
            let forwardLen = simd_length(forward)
            if forwardLen > 0.01 {
                let fwd = forward / forwardLen
                // Perpendicular left direction
                let leftDir = SIMD3<Float>(-fwd.z, 0, fwd.x)
                let offset = max(boundingBox.extents.x, boundingBox.extents.z) + 0.04
                let labelY = boxCenter.y + boundingBox.extents.y * 0.3
                labelPanel.position = boxCenter + leftDir * offset + SIMD3<Float>(0, labelY - boxCenter.y, 0)

                // Face camera
                let angle = atan2(fwd.x, fwd.z)
                labelPanel.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        }
    }

    /// Show or hide the dimension billboards
    func setDimensionBillboardVisible(_ visible: Bool, forceShow: Bool = false) {
        sizeBillboardEntity?.isEnabled = forceShow || visible
        labelBillboardEntity?.isEnabled = forceShow || visible
    }

    /// Update the action icon row to match the current mode
    func updateActionMode(_ mode: ActionMode) {
        currentActionMode = mode
        actionIconRow?.removeFromParent()
        actionIconRow = nil

        guard let sizePanel = sizeBillboardEntity else { return }

        let actions: [ActionIconConfig]
        switch mode {
        case .normal:
            actions = ActionIconBuilder.activeNormalActions
        case .normalNoRefine:
            actions = ActionIconBuilder.activeNormalActionsNoRefine
        case .editing:
            actions = ActionIconBuilder.activeEditActions
        case .refining:
            actions = ActionIconBuilder.activeRefiningActions
        }

        let row = ActionIconBuilder.createActionRow(actions: actions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        sizePanel.addChild(row)
        actionIconRow = row
    }

    /// Check if this box is visible
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

    /// Highlight a handle
    func highlightHandle(_ handleType: HandleType) {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        guard let index = handleTypes.firstIndex(of: handleType),
              index < faceHandleEntities.count else { return }

        faceHandleEntities[index].scale = SIMD3<Float>(repeating: 1.3)
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
        createCornerMarkers()
        createFaceHandles()
        createRotationRing()
        createFloorDistanceIndicator()
        updateInteractiveState()
    }

    private func updateInteractiveState() {
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
        cornerMarkerEntities.removeAll()
        faceHandleEntities.removeAll()
        rotationRingEntity = nil
        floorDistanceEntity = nil
        floorDistanceLabel = nil
        labelEntities.removeAll()
        sizeBillboardEntity = nil
        labelBillboardEntity = nil
        actionIconRow = nil
    }

    // MARK: - Dual-Layer Edge Creation

    private func createEdges() {
        let edges = boundingBox.edges

        for (index, (start, end)) in edges.enumerated() {
            let edgeGroup = createDualEdgeEntity(from: start, to: end, index: index)
            entity.addChild(edgeGroup)
            edgeEntities.append(edgeGroup)
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
            updateDualEdgeEntity(edgeEntities[index], from: start, to: end)
        }
    }

    /// Create a dual-layer edge: inner bright line + outer glow
    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> Entity {
        let parent = Entity()
        parent.name = "edge_\(index)"

        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow layer
        let outerMesh = MeshResource.generateBox(size: [outerEdgeRadius * 2, outerEdgeRadius * 2, length])
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
        outerEntity.name = "edge_outer_\(index)"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation

        // Inner bright layer
        let innerMesh = MeshResource.generateBox(size: [innerEdgeRadius * 2, innerEdgeRadius * 2, length])
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
        innerEntity.name = "edge_inner_\(index)"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    private func updateDualEdgeEntity(_ edgeGroup: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        let children = edgeGroup.children.compactMap { $0 as? ModelEntity }
        for child in children {
            child.position = midpoint
            child.orientation = orientation
            if child.name.contains("outer") {
                child.model?.mesh = MeshResource.generateBox(size: [outerEdgeRadius * 2, outerEdgeRadius * 2, length])
            } else {
                child.model?.mesh = MeshResource.generateBox(size: [innerEdgeRadius * 2, innerEdgeRadius * 2, length])
            }
        }
    }

    // MARK: - Corner Markers

    private func createCornerMarkers() {
        let corners = boundingBox.corners
        for (index, corner) in corners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "corner_\(index)"
            sphere.position = corner
            entity.addChild(sphere)
            cornerMarkerEntities.append(sphere)
        }
    }

    private func updateCornerMarkerPositions() {
        let corners = boundingBox.corners
        guard cornerMarkerEntities.count == corners.count else {
            for m in cornerMarkerEntities { m.removeFromParent() }
            cornerMarkerEntities.removeAll()
            createCornerMarkers()
            return
        }
        for (index, corner) in corners.enumerated() {
            cornerMarkerEntities[index].position = corner
        }
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

        let material = UnlitMaterial(color: handleColor)
        let capsuleMesh = MeshResource.generateBox(
            size: [handleRadius * 2, handleRadius * 2, handleLength],
            cornerRadius: handleRadius
        )
        let capsuleEntity = ModelEntity(mesh: capsuleMesh, materials: [material])
        parentEntity.addChild(capsuleEntity)

        let collisionShape = ShapeResource.generateCapsule(height: handleLength, radius: handleCollisionRadius)
        parentEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

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
        case .faceNegX, .facePosX:
            targetDirection = axes.z
        case .faceNegZ, .facePosZ:
            targetDirection = axes.x
        case .faceNegY, .facePosY:
            targetDirection = axes.x
        default:
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return calculateOrientation(direction: targetDirection)
    }

    // MARK: - Rotation Handle Creation

    private func createRotationRing() {
        let handleEntity = Entity()
        handleEntity.name = "rotation_ring"

        let material = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.6))
        let placeholderRadius: Float = 0.03

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

        let arrowSize: Float = 0.004
        let arrowMesh = MeshResource.generateBox(
            size: [arrowSize, arrowSize * 0.5, arrowSize],
            cornerRadius: arrowSize * 0.2
        )
        let arrowHead = ModelEntity(mesh: arrowMesh, materials: [material])
        arrowHead.name = "rotation_arrow"
        arrowHead.position = SIMD3<Float>(0, 0, placeholderRadius)
        arrowHead.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        handleEntity.addChild(arrowHead)

        let collisionShape = ShapeResource.generateBox(
            size: [placeholderRadius * 2.5, 0.02, placeholderRadius * 2.5]
        )
        handleEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        updateRotationRingTransform(handleEntity)
        handleEntity.isEnabled = isInteractive

        entity.addChild(handleEntity)
        rotationRingEntity = handleEntity
    }

    private func createTorusArcMesh(
        majorRadius: Float,
        minorRadius: Float,
        startAngle: Float,
        arcAngle: Float
    ) -> MeshResource? {
        let majorSegments = 32
        let minorSegments = 12

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for i in 0...majorSegments {
            let majorAngle = startAngle + arcAngle * Float(i) / Float(majorSegments)
            let majorCos = cos(majorAngle)
            let majorSin = sin(majorAngle)
            let centerX = majorCos * majorRadius
            let centerZ = majorSin * majorRadius

            for j in 0...minorSegments {
                let minorAngle = 2.0 * .pi * Float(j) / Float(minorSegments)
                let minorCos = cos(minorAngle)
                let minorSin = sin(minorAngle)

                let x = centerX + majorCos * minorRadius * minorCos
                let y = minorRadius * minorSin
                let z = centerZ + majorSin * minorRadius * minorCos

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(SIMD3<Float>(majorCos * minorCos, minorSin, majorSin * minorCos))
                uvs.append(SIMD2<Float>(Float(i) / Float(majorSegments), Float(j) / Float(minorSegments)))
            }
        }

        let minorCount = minorSegments + 1
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let current = UInt32(i * minorCount + j)
                let next = UInt32((i + 1) * minorCount + j)
                indices.append(contentsOf: [current, next, current + 1, current + 1, next, next + 1])
            }
        }

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
        let arcRadius = min(boundingBox.extents.x, boundingBox.extents.z) * 0.4

        let bottomY = -boundingBox.extents.y
        let cornerX = boundingBox.extents.x
        let cornerZ = boundingBox.extents.z
        let localPos = SIMD3<Float>(cornerX, bottomY, cornerZ)
        ringEntity.position = boundingBox.localToWorld(localPos)
        ringEntity.orientation = boundingBox.rotation

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

        if let arrowEntity = ringEntity.children.first(where: { $0.name == "rotation_arrow" }) as? ModelEntity {
            arrowEntity.position = SIMD3<Float>(0, 0, arcRadius)
        }

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

        for child in indicatorEntity.children {
            child.removeFromParent()
        }

        let bottomLocalY = -boundingBox.extents.y
        let bottomCenter = boundingBox.localToWorld(SIMD3<Float>(0, bottomLocalY, 0))
        let distanceToFloor = bottomCenter.y - floorY

        guard distanceToFloor > 0.001 else {
            indicatorEntity.isEnabled = false
            return
        }
        indicatorEntity.isEnabled = true

        let floorPoint = SIMD3<Float>(bottomCenter.x, floorY, bottomCenter.z)

        // Dashed line
        let dashLength: Float = 0.01
        let gapLength: Float = 0.008
        let segmentLength = dashLength + gapLength
        let numSegments = Int(distanceToFloor / segmentLength)

        let dashColor = PMTheme.uiCyan.withAlphaComponent(0.5)

        for i in 0..<max(1, numSegments) {
            let segmentY = floorY + Float(i) * segmentLength + dashLength / 2
            if segmentY > bottomCenter.y { break }

            let dashMesh = MeshResource.generateBox(size: [0.001, dashLength, 0.001])
            let material = UnlitMaterial(color: dashColor)
            let dashEntity = ModelEntity(mesh: dashMesh, materials: [material])
            dashEntity.position = SIMD3<Float>(bottomCenter.x, segmentY, bottomCenter.z)
            indicatorEntity.addChild(dashEntity)
        }

        // Distance label
        let labelPosition = SIMD3<Float>(bottomCenter.x + 0.02, (bottomCenter.y + floorY) / 2, bottomCenter.z)
        let distanceCm = distanceToFloor * 100
        let labelText = String(format: "%.1f cm", distanceCm)

        let textMesh = MeshResource.generateText(
            labelText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: 0.012, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        let textMaterial = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.8))
        let labelEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        labelEntity.position = labelPosition
        indicatorEntity.addChild(labelEntity)

        // Floor marker
        let markerMesh = MeshResource.generateBox(size: [0.02, 0.001, 0.02])
        let markerMaterial = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.3))
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

    // MARK: - Dimension Billboards (size panel above box, label panel to the left)

    private func createDimensionLabels() {
        sizeBillboardEntity?.removeFromParent()
        labelBillboardEntity?.removeFromParent()
        actionIconRow = nil

        // Size panel above box
        let sizePos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        sizeBillboardEntity = createSizeBillboard(at: sizePos)
        entity.addChild(sizeBillboardEntity!)

        // Label panel (only if label data exists)
        if let ld = storedLabelData, !ld.displayFields.isEmpty {
            let labelPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y * 0.3, 0)
            labelBillboardEntity = createLabelBillboard(at: labelPos)
            entity.addChild(labelBillboardEntity!)
            labelBillboardEntity?.isEnabled = true
        }

        updateActionMode(currentActionMode)
        sizeBillboardEntity?.isEnabled = true
    }

    private func updateDimensionLabelPositions() {
        guard storedHeight > 0 else { return }
        sizeBillboardEntity?.position = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        // Label panel position is updated per-frame in updateLabelOrientations
    }

    // MARK: - Size Billboard (dimensions, volume, weight, quality)

    private func createSizeBillboard(at position: SIMD3<Float>) -> Entity {
        let containerEntity = Entity()
        containerEntity.position = position

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        let labelColor = billboardAccentColor.withAlphaComponent(0.55)
        let valueColor = dimensionLabelTextColor
        let sectionTextColor = billboardAccentColor.withAlphaComponent(0.70)
        let separatorColor = billboardAccentColor.withAlphaComponent(0.25)

        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        // ID header
        let idResult = textMesh(String(format: "#%03d", boxId), size: sizePanelIdFontSize, weight: .bold, color: billboardAccentColor)

        // Main dimension line (big)
        let wVal = formatDimensionValue(storedWidth)
        let hVal = formatDimensionValue(storedHeight)
        let lVal = formatDimensionValue(storedLength)
        let unit = storedUnit.rawValue
        let dimLine = textMesh("\(wVal) × \(hVal) × \(lVal) \(unit)", size: sizePanelDimensionFontSize, weight: .bold, color: valueColor)

        // Volume + weight line
        let volValue = storedUnit.convertVolume(cubicMeters: boundingBox.volume)
        let volStr: String
        if volValue >= 1000 { volStr = String(format: "%.0f %@", volValue, storedUnit.volumeUnit()) }
        else if volValue >= 100 { volStr = String(format: "%.1f %@", volValue, storedUnit.volumeUnit()) }
        else { volStr = String(format: "%.2f %@", volValue, storedUnit.volumeUnit()) }
        let volWtStr = storedUnit.formatVolumetricWeight(cubicMeters: boundingBox.volume)
        let volLine = textMesh("VOL \(volStr)   WT \(volWtStr)", size: sizePanelSecondaryFontSize, weight: .medium, color: valueColor)

        // Size class + quality line
        let sizeClass = SizeClass.classify(volumeCubicMeters: boundingBox.volume).rawValue
        var classQualStr = "■ \(sizeClass)"
        if !storedQualityLabel.isEmpty {
            classQualStr += "   QUALITY \(storedQualityLabel)"
        }
        let classLine = textMesh(classQualStr, size: sizePanelBadgeFontSize, weight: .semibold, color: sectionTextColor)

        // Points line
        let ptsLine = textMesh("PTS \(storedPointCount)", size: sizePanelSecondaryFontSize, weight: .medium, color: labelColor)

        // Calculate layout
        let allTexts = [idResult, dimLine, volLine, classLine, ptsLine]
        let maxContentWidth = allTexts.map { $0.size.x }.max() ?? 0

        let totalContentHeight: Float = idResult.size.y + sectionTopGap + separatorThick + separatorMargin
            + dimLine.size.y + lineGap + volLine.size.y + lineGap + classLine.size.y + lineGap + ptsLine.size.y

        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        // Structural elements (same cyberpunk style)
        addBillboardStructure(to: containerEntity, totalWidth: totalWidth, totalHeight: totalHeight,
                              cornerRadius: cornerRadius, accentX: accentX,
                              accentH: totalContentHeight + padding)

        // Position text top-to-bottom
        var cursor = padding + totalContentHeight

        // ID
        cursor -= idResult.size.y
        idResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(idResult.entity)

        // Separator
        cursor -= sectionTopGap
        let sepW = maxContentWidth
        let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
        var sepMat = UnlitMaterial(color: separatorColor)
        sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
        sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
        containerEntity.addChild(sepEntity)
        cursor -= separatorThick + separatorMargin

        // Main dimension line
        cursor -= dimLine.size.y
        dimLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(dimLine.entity)

        // Volume + weight
        cursor -= lineGap + volLine.size.y
        volLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(volLine.entity)

        // Size class + quality
        cursor -= lineGap + classLine.size.y
        classLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(classLine.entity)

        // Points
        cursor -= lineGap + ptsLine.size.y
        ptsLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(ptsLine.entity)

        return containerEntity
    }

    // MARK: - Label Billboard (CTN ID, BARCODE, DEST, etc.)

    private func createLabelBillboard(at position: SIMD3<Float>) -> Entity {
        let containerEntity = Entity()
        containerEntity.position = position

        guard let ld = storedLabelData else { return containerEntity }

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.003
        let sectionTopGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        let labelColor = billboardAccentColor.withAlphaComponent(0.55)
        let valueColor = dimensionLabelTextColor
        let sectionTextColor = billboardAccentColor.withAlphaComponent(0.70)
        let separatorColor = billboardAccentColor.withAlphaComponent(0.25)

        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        // Title
        let title = textMesh("LABEL DATA", size: labelPanelTitleFontSize, weight: .bold, color: sectionTextColor)

        // Build primary fields (CTN ID, BARCODE, DEST) with large values
        struct PrimaryField {
            let label: (entity: ModelEntity, size: SIMD3<Float>)
            let value: (entity: ModelEntity, size: SIMD3<Float>)
        }
        var primaryFields: [PrimaryField] = []
        for field in ld.primaryDisplayFields {
            let truncVal = field.value.count > 20 ? String(field.value.prefix(20)) : field.value
            let l = textMesh(field.label, size: labelPanelPrimaryLabelFontSize, weight: .semibold, color: labelColor)
            let v = textMesh(truncVal, size: labelPanelPrimaryValueFontSize, weight: .bold, color: valueColor)
            primaryFields.append(PrimaryField(label: l, value: v))
        }

        // Build secondary fields (compact key-value)
        struct SecondaryField {
            let label: (entity: ModelEntity, size: SIMD3<Float>)
            let value: (entity: ModelEntity, size: SIMD3<Float>)
        }
        var secondaryFields: [SecondaryField] = []
        var maxSecLabel: Float = 0
        for field in ld.secondaryDisplayFields {
            let truncVal = field.value.count > 20 ? String(field.value.prefix(20)) : field.value
            let l = textMesh(field.label, size: labelPanelSecondaryFontSize, weight: .semibold, color: labelColor)
            let v = textMesh(truncVal, size: labelPanelSecondaryFontSize, weight: .medium, color: valueColor)
            maxSecLabel = max(maxSecLabel, l.size.x)
            secondaryFields.append(SecondaryField(label: l, value: v))
        }

        // Calculate max content width
        var maxContentWidth: Float = title.size.x
        for pf in primaryFields {
            maxContentWidth = max(maxContentWidth, pf.label.size.x)
            maxContentWidth = max(maxContentWidth, pf.value.size.x)
        }
        let secLabelValueGap: Float = 0.005
        for sf in secondaryFields {
            maxContentWidth = max(maxContentWidth, maxSecLabel + secLabelValueGap + sf.value.size.x)
        }

        // Calculate total content height
        var totalContentHeight: Float = title.size.y
        for pf in primaryFields {
            totalContentHeight += sectionTopGap + separatorThick + separatorMargin
            totalContentHeight += pf.label.size.y + lineGap + pf.value.size.y
        }
        if !secondaryFields.isEmpty {
            totalContentHeight += sectionTopGap + separatorThick + separatorMargin
            for sf in secondaryFields {
                totalContentHeight += lineGap + max(sf.label.size.y, sf.value.size.y)
            }
        }

        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        // Structural elements
        addBillboardStructure(to: containerEntity, totalWidth: totalWidth, totalHeight: totalHeight,
                              cornerRadius: cornerRadius, accentX: accentX,
                              accentH: totalContentHeight + padding)

        // Position text
        var cursor = padding + totalContentHeight

        // Title
        cursor -= title.size.y
        title.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(title.entity)

        // Primary fields (each with separator, label, big value)
        for pf in primaryFields {
            cursor -= sectionTopGap
            let sepW = maxContentWidth
            let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
            var sepMat = UnlitMaterial(color: separatorColor)
            sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
            sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
            containerEntity.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            cursor -= pf.label.size.y
            pf.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(pf.label.entity)

            cursor -= lineGap + pf.value.size.y
            pf.value.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(pf.value.entity)
        }

        // Secondary fields (compact)
        if !secondaryFields.isEmpty {
            cursor -= sectionTopGap
            let sepW = maxContentWidth
            let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
            var sepMat = UnlitMaterial(color: separatorColor)
            sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
            sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
            containerEntity.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            let secValueX = textLeftX + maxSecLabel + secLabelValueGap
            for sf in secondaryFields {
                let h = max(sf.label.size.y, sf.value.size.y)
                cursor -= lineGap + h
                sf.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                sf.value.entity.position = SIMD3<Float>(secValueX, cursor, 0)
                containerEntity.addChild(sf.label.entity)
                containerEntity.addChild(sf.value.entity)
            }
        }

        return containerEntity
    }

    // MARK: - Billboard Shared Structure

    /// Adds glow, background, accent bar, and borders to a billboard container
    private func addBillboardStructure(to container: Entity, totalWidth: Float, totalHeight: Float,
                                       cornerRadius: Float, accentX: Float, accentH: Float) {
        let accentBarWidth: Float = 0.002

        // Outer glow
        let glowPad: Float = 0.003
        let glowMesh = MeshResource.generateBox(
            size: [totalWidth + glowPad * 2, totalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var glowMat = UnlitMaterial(color: billboardAccentColor.withAlphaComponent(0.06))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let glowEntity = ModelEntity(mesh: glowMesh, materials: [glowMat])
        glowEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.002)

        // Dark glass background
        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: dimensionLabelBackgroundColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMat])
        bgEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)

        // Accent bar + glow
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: billboardAccentColor)])
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)

        let accentGlowW: Float = 0.006
        let agMesh = MeshResource.generateBox(size: [accentGlowW, accentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var agMat = UnlitMaterial(color: billboardAccentColor.withAlphaComponent(0.10))
        agMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let accentGlowEntity = ModelEntity(mesh: agMesh, materials: [agMat])
        accentGlowEntity.position = SIMD3<Float>(accentX, totalHeight / 2, -0.0005)

        // Top + bottom borders
        let borderW = totalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [borderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: billboardTopBorderColor)
            mat.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return ModelEntity(mesh: mesh, materials: [mat])
        }
        let topBorder = makeBorder(opacity: 0.50)
        topBorder.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        let bottomBorder = makeBorder(opacity: 0.30)
        bottomBorder.position = SIMD3<Float>(0, 0.0003, 0.0005)

        container.addChild(glowEntity)
        container.addChild(bgEntity)
        container.addChild(accentEntity)
        container.addChild(accentGlowEntity)
        container.addChild(topBorder)
        container.addChild(bottomBorder)
    }

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

}

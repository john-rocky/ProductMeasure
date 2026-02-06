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
    private var billboardBackgroundEntity: ModelEntity?

    // Action icon row (for completed box actions)
    private var actionIconRow: Entity?

    private(set) var boundingBox: BoundingBox3D
    private(set) var boxId: Int
    private let height: Float
    private let length: Float
    private let width: Float
    private let unit: MeasurementUnit

    /// Public accessor for box ID
    var id: Int { boxId }

    // Stored data for re-edit
    private(set) var quality: MeasurementQuality
    private(set) var axisMapping: BoundingBox3D.AxisMapping
    private(set) var pointCloud: [SIMD3<Float>]?
    private(set) var floorY: Float?

    // MARK: - Constants

    // White wireframe (same as BoxVisualization)
    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.5)
    private let lineRadius: Float = 0.0004  // Thin (0.4mm)

    // Label styling
    private let billboardIdFontSize: CGFloat = 0.010
    private let billboardBodyFontSize: CGFloat = 0.007
    private let labelTextColor: UIColor = UIColor(white: 1.0, alpha: 0.95)
    private let labelBackgroundColor: UIColor = UIColor(white: 0.0, alpha: 0.75)
    private let billboardAccentColor: UIColor = UIColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)

    // MARK: - Initialization

    init(
        boundingBox: BoundingBox3D,
        height: Float,
        length: Float,
        width: Float,
        unit: MeasurementUnit,
        boxId: Int = 0,
        quality: MeasurementQuality,
        axisMapping: BoundingBox3D.AxisMapping,
        pointCloud: [SIMD3<Float>]? = nil,
        floorY: Float? = nil
    ) {
        self.boundingBox = boundingBox
        self.boxId = boxId
        self.height = height
        self.length = length
        self.width = width
        self.unit = unit
        self.quality = quality
        self.axisMapping = axisMapping
        self.pointCloud = pointCloud
        self.floorY = floorY
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
        // Hide action icons when billboard is hidden
        if !visible {
            hideActionIcons()
        }
    }

    /// Show action icons below the billboard
    func showActionIcons() {
        guard actionIconRow == nil, let billboard = dimensionBillboardEntity else { return }

        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.completedActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        billboard.addChild(row)
        actionIconRow = row
    }

    /// Hide action icons
    func hideActionIcons() {
        actionIconRow?.removeFromParent()
        actionIconRow = nil
    }

    /// Whether action icons are currently showing
    var isShowingActionIcons: Bool {
        actionIconRow != nil
    }

    /// Convert stored data back to a MeasurementResult for re-editing
    func toMeasurementResult() -> MeasurementCalculator.MeasurementResult {
        var result = MeasurementCalculator.MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: boundingBox.volume,
            quality: quality,
            heightAxisIndex: axisMapping.height,
            lengthAxisIndex: axisMapping.length,
            widthAxisIndex: axisMapping.width
        )
        result.pointCloud = pointCloud
        return result
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

        let cubicMeters = height * length * width
        let accentBarWidth: Float = 0.0015
        let padding: Float = 0.005
        let innerPadding: Float = 0.003

        // -- Header: Box ID (larger, bold, accent color) --
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
        let lVal = formatDimension(length)
        let wVal = formatDimension(width)
        let hVal = formatDimension(height)
        let dimLine = "L: \(lVal)  W: \(wVal)  H: \(hVal) \(unit.rawValue)"

        let volText = formatVolume()
        let wgtText = unit.formatVolumetricWeight(cubicMeters: cubicMeters)
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
        let bodyMaterial = UnlitMaterial(color: labelTextColor)
        let bodyEntity = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
        let bodyWidth = bodyMesh.bounds.extents.x
        let bodyHeight = bodyMesh.bounds.extents.y

        // -- Layout calculation --
        let gap: Float = 0.003
        let contentWidth = max(idWidth, bodyWidth)
        let contentHeight = idHeight + gap + bodyHeight
        let totalWidth = accentBarWidth + innerPadding + contentWidth + padding * 2
        let totalHeight = contentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.12

        // -- Background (dark glass) with collision for tap detection --
        let backgroundMesh = MeshResource.generateBox(
            size: [totalWidth, totalHeight, 0.001],
            cornerRadius: cornerRadius
        )
        var backgroundMaterial = UnlitMaterial(color: labelBackgroundColor)
        backgroundMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.75))
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])
        backgroundEntity.name = "completed_billboard_bg"

        // Add collision component for tap detection on billboard
        let collisionShape = ShapeResource.generateBox(
            size: [totalWidth * 1.2, totalHeight * 1.2, 0.005]
        )
        backgroundEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
        billboardBackgroundEntity = backgroundEntity

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

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        dimensionBillboardEntity = containerEntity
    }

    /// Format dimension value without unit suffix (unit shown once at end of line)
    private func formatDimension(_ meters: Float) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func formatVolume() -> String {
        let cubicMeters = height * length * width
        let value = unit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
            return "Vol: \(formatted) \(unit.volumeUnit())"
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

//
//  CompletedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Simplified visualization for saved/completed boxes
/// Shows dual-layer edges, corner markers, and dimension billboard (no handles or rotation ring)
class CompletedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [Entity] = []
    private var cornerMarkerEntities: [ModelEntity] = []
    // Size billboard (above box)
    private var sizeBillboardEntity: Entity?
    private var billboardBackgroundEntity: ModelEntity?
    // Label billboard (left of box)
    private var labelBillboardEntity: Entity?

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
    private(set) var labelData: LabelData?

    // MARK: - Constants

    // Dual-layer edges (dimmer than active box)
    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInnerDim
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuterDim
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius

    // Corner markers (smaller, dimmer)
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadiusSmall
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarkerDim

    // Billboard styling
    private let labelTextColor: UIColor = PMTheme.uiBillboardText
    private let labelBackgroundColor: UIColor = PMTheme.uiBillboardBg
    private let billboardAccentColor: UIColor = PMTheme.uiBillboardAccent
    private let billboardTopBorderColor: UIColor = PMTheme.uiBillboardTopBorder

    // Size panel font sizes
    private let sizePanelIdFontSize: CGFloat = 0.014
    private let sizePanelDimensionFontSize: CGFloat = 0.016
    private let sizePanelSecondaryFontSize: CGFloat = 0.009

    // Label panel font sizes
    private let labelPanelTitleFontSize: CGFloat = 0.007
    private let labelPanelPrimaryValueFontSize: CGFloat = 0.012
    private let labelPanelPrimaryLabelFontSize: CGFloat = 0.007
    private let labelPanelSecondaryFontSize: CGFloat = 0.008

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
        floorY: Float? = nil,
        labelData: LabelData? = nil
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
        self.labelData = labelData
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        // Orient size billboard to face camera
        if let sizePanel = sizeBillboardEntity {
            let pos = sizePanel.position(relativeTo: nil)
            let toCamera = cameraPosition - pos
            let horizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)
            if simd_length(horizontal) > 0.01 {
                let angle = atan2(horizontal.x, horizontal.z)
                sizePanel.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        }

        // Orient + reposition label billboard to stay on the left
        if let labelPanel = labelBillboardEntity {
            let boxCenter = boundingBox.center
            let toCamera = cameraPosition - boxCenter
            let forward = SIMD3<Float>(toCamera.x, 0, toCamera.z)
            let forwardLen = simd_length(forward)
            if forwardLen > 0.01 {
                let fwd = forward / forwardLen
                let leftDir = SIMD3<Float>(-fwd.z, 0, fwd.x)
                let offset = max(boundingBox.extents.x, boundingBox.extents.z) + 0.04
                let labelY = boxCenter.y + boundingBox.extents.y * 0.3
                labelPanel.position = boxCenter + leftDir * offset + SIMD3<Float>(0, labelY - boxCenter.y, 0)

                let angle = atan2(fwd.x, fwd.z)
                labelPanel.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        }
    }

    func setDimensionBillboardVisible(_ visible: Bool) {
        sizeBillboardEntity?.isEnabled = visible
        labelBillboardEntity?.isEnabled = visible
        if !visible {
            hideActionIcons()
        }
    }

    func showActionIcons() {
        guard actionIconRow == nil, let sizePanel = sizeBillboardEntity else { return }

        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.completedActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        sizePanel.addChild(row)
        actionIconRow = row
    }

    func hideActionIcons() {
        actionIconRow?.removeFromParent()
        actionIconRow = nil
    }

    var isShowingActionIcons: Bool {
        actionIconRow != nil
    }

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

    func isVisibleFromCamera(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) -> Bool {
        let toBox = boundingBox.center - cameraPosition
        let distance = simd_length(toBox)
        let toBoxNormalized = toBox / distance
        let dot = simd_dot(toBoxNormalized, cameraForward)
        return dot > 0.3
    }

    func apparentSizeFromCamera(cameraPosition: SIMD3<Float>) -> Float {
        let distance = simd_length(boundingBox.center - cameraPosition)
        if distance < 0.01 { return 0 }
        let boxSize = boundingBox.extents.x * boundingBox.extents.y * boundingBox.extents.z
        return boxSize / (distance * distance)
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createCornerMarkers()
        createDimensionBillboard()
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

    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> Entity {
        let parent = Entity()
        parent.name = "completed_edge_\(index)"

        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow layer (transparent like active box — glow is subtle so depth-sort issues are negligible)
        let outerMesh = MeshResource.generateBox(size: [outerEdgeRadius * 2, outerEdgeRadius * 2, length])
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
        outerEntity.name = "completed_edge_outer_\(index)"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation

        // Inner line
        let innerMesh = MeshResource.generateBox(size: [innerEdgeRadius * 2, innerEdgeRadius * 2, length])
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
        innerEntity.name = "completed_edge_inner_\(index)"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    // MARK: - Corner Markers

    private func createCornerMarkers() {
        let corners = boundingBox.corners
        for (index, corner) in corners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "completed_corner_\(index)"
            sphere.position = corner
            entity.addChild(sphere)
            cornerMarkerEntities.append(sphere)
        }
    }

    // MARK: - Dimension Billboards (size panel above box, label panel to the left)

    private func createDimensionBillboard() {
        // Size billboard (above box)
        createSizeBillboard()

        // Label billboard (left of box, only if label data exists)
        if let ld = labelData, !ld.displayFields.isEmpty {
            createLabelBillboard()
        }
    }

    private func createSizeBillboard() {
        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)

        let containerEntity = Entity()
        containerEntity.position = billboardPos

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.007
        let innerPadding: Float = 0.004
        let lineGap: Float = 0.003
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001
        let sectionTopGap: Float = 0.005

        let valueColor = labelTextColor
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

        // Main dimension line
        let wVal = formatDimension(width)
        let hVal = formatDimension(height)
        let lVal = formatDimension(length)
        let dimLine = textMesh("\(wVal) × \(hVal) × \(lVal) \(unit.rawValue)", size: sizePanelDimensionFontSize, weight: .bold, color: valueColor)

        // Volume line
        let volStr = formatVolume()
        let volLine = textMesh(volStr, size: sizePanelSecondaryFontSize, weight: .medium, color: valueColor)

        // Calculate layout
        let allTexts = [idResult, dimLine, volLine]
        let maxContentWidth = allTexts.map { $0.size.x }.max() ?? 0

        let totalContentHeight: Float = idResult.size.y + sectionTopGap + separatorThick + separatorMargin
            + dimLine.size.y + lineGap + volLine.size.y

        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.08

        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        // Background with collision for tap detection
        let backgroundMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: labelBackgroundColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [bgMat])
        backgroundEntity.name = "completed_billboard_bg"
        backgroundEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)

        let collisionShape = ShapeResource.generateBox(size: [totalWidth * 1.2, totalHeight * 1.2, 0.005])
        backgroundEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
        billboardBackgroundEntity = backgroundEntity

        // Accent bar
        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: billboardAccentColor)])
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)

        // Top border
        let topBorderW = totalWidth * 0.9
        let topBorderMesh = MeshResource.generateBox(size: [topBorderW, 0.0005, 0.0012])
        var topBorderMat = UnlitMaterial(color: billboardTopBorderColor)
        topBorderMat.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let topBorderEntity = ModelEntity(mesh: topBorderMesh, materials: [topBorderMat])
        topBorderEntity.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(topBorderEntity)

        // Position text top-to-bottom
        var cursor = padding + totalContentHeight

        cursor -= idResult.size.y
        idResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(idResult.entity)

        cursor -= sectionTopGap
        let sepW = maxContentWidth
        let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
        var sepMat = UnlitMaterial(color: separatorColor)
        sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
        sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
        containerEntity.addChild(sepEntity)
        cursor -= separatorThick + separatorMargin

        cursor -= dimLine.size.y
        dimLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(dimLine.entity)

        cursor -= lineGap + volLine.size.y
        volLine.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(volLine.entity)

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        sizeBillboardEntity = containerEntity
    }

    private func createLabelBillboard() {
        guard let ld = labelData else { return }

        let containerEntity = Entity()
        // Initial position (will be updated per-frame to stay on the left)
        containerEntity.position = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y * 0.3, 0)

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.007
        let innerPadding: Float = 0.004
        let lineGap: Float = 0.003
        let sectionTopGap: Float = 0.004
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        let labelColor = billboardAccentColor.withAlphaComponent(0.55)
        let valueColor = labelTextColor
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

        let title = textMesh("LABEL DATA", size: labelPanelTitleFontSize, weight: .bold, color: sectionTextColor)

        // Primary fields (big values)
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

        // Secondary fields (compact)
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
        let secLabelValueGap: Float = 0.004
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

        // Background
        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: labelBackgroundColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMat])
        bgEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)

        // Accent bar
        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: billboardAccentColor)])
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)

        // Top border
        let topBorderW = totalWidth * 0.9
        let topBorderMesh = MeshResource.generateBox(size: [topBorderW, 0.0005, 0.0012])
        var topBorderMat = UnlitMaterial(color: billboardTopBorderColor)
        topBorderMat.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let topBorderEntity = ModelEntity(mesh: topBorderMesh, materials: [topBorderMat])
        topBorderEntity.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)

        containerEntity.addChild(bgEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(topBorderEntity)

        // Position text
        var cursor = padding + totalContentHeight

        cursor -= title.size.y
        title.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(title.entity)

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

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        labelBillboardEntity = containerEntity
    }

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

//
//  ShippingBoxVisualization.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// Wireframe overlay showing the recommended shipping box around the measured object,
/// with an info billboard displaying recommendation details.
class ShippingBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [Entity] = []
    private var billboardEntity: Entity?

    // Shipping box wireframe colors (softer green, differentiated from measurement wireframe)
    private let innerEdgeColor = PMTheme.uiShippingBoxInner
    private let outerEdgeColor = PMTheme.uiShippingBoxOuter
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius

    // Billboard styling
    private let billboardAccentColor = PMTheme.uiShippingBoxInner
    private let billboardTextColor = PMTheme.uiBillboardText
    private let billboardBgColor = PMTheme.uiBillboardBg
    private let billboardTopBorderColor = PMTheme.uiBillboardTopBorder
    private let billboardIdFontSize: CGFloat = 0.008
    private let billboardBodyFontSize: CGFloat = 0.006

    // MARK: - Initialization

    /// Create a shipping box wireframe aligned to the measured object's bounding box.
    /// - Parameters:
    ///   - objectBoundingBox: The measured object's oriented bounding box
    ///   - shippingBoxDimensionsMeters: The shipping box dimensions (L, W, H) in meters
    ///   - recommendation: The shipping box recommendation (nil if no suitable box found)
    ///   - objectLength: Measured object length in meters
    ///   - objectWidth: Measured object width in meters
    ///   - objectHeight: Measured object height in meters
    ///   - unit: The user's display unit
    init(objectBoundingBox: BoundingBox3D,
         shippingBoxDimensionsMeters: SIMD3<Float>,
         recommendation: ShippingBoxRecommendation?,
         objectLength: Float, objectWidth: Float, objectHeight: Float,
         unit: MeasurementUnit) {
        self.entity = Entity()

        // Sort object dimensions per axis to map smallest-to-smallest
        let objDims = objectBoundingBox.dimensions
        let objAxisDims: [(Float, Int)] = [
            (objDims.x, 0),
            (objDims.y, 1),
            (objDims.z, 2)
        ].sorted { $0.0 < $1.0 }

        // Sort shipping dimensions ascending
        let shipDims = [shippingBoxDimensionsMeters.x, shippingBoxDimensionsMeters.y, shippingBoxDimensionsMeters.z].sorted()

        // Map: smallest shipping dim → axis with smallest object dim, etc.
        var newExtents = SIMD3<Float>(repeating: 0)
        for i in 0..<3 {
            let axisIndex = objAxisDims[i].1
            newExtents[axisIndex] = shipDims[i] / 2.0
        }

        // Build aligned bounding box with shipping extents, same center & rotation as object
        let shippingBBox = BoundingBox3D(
            center: objectBoundingBox.center,
            extents: newExtents,
            rotation: objectBoundingBox.rotation
        )

        createEdges(for: shippingBBox)
        createBillboard(
            for: shippingBBox,
            recommendation: recommendation,
            objectLength: objectLength,
            objectWidth: objectWidth,
            objectHeight: objectHeight,
            unit: unit
        )
    }

    // MARK: - Billboard Orientation

    func updateBillboardOrientation(cameraPosition: SIMD3<Float>) {
        guard let billboard = billboardEntity else { return }
        let pos = billboard.position(relativeTo: nil)
        let toCamera = cameraPosition - pos
        let horizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)
        if simd_length(horizontal) > 0.01 {
            let angle = atan2(horizontal.x, horizontal.z)
            billboard.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    // MARK: - Billboard Creation

    private func createBillboard(
        for box: BoundingBox3D,
        recommendation: ShippingBoxRecommendation?,
        objectLength: Float, objectWidth: Float, objectHeight: Float,
        unit: MeasurementUnit
    ) {
        let billboardPos = box.center + SIMD3<Float>(0, box.extents.y + 0.03, 0)

        let containerEntity = Entity()
        containerEntity.position = billboardPos

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.007
        let innerPadding: Float = 0.004

        // -- Header --
        let headerText: String
        if let rec = recommendation {
            headerText = rec.shippingBox.displayName
        } else {
            headerText = String(localized: "No suitable box")
        }
        let headerMesh = MeshResource.generateText(
            headerText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardIdFontSize, weight: .bold),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        let headerMaterial = UnlitMaterial(color: billboardAccentColor)
        let headerEntity = ModelEntity(mesh: headerMesh, materials: [headerMaterial])
        let headerWidth = headerMesh.bounds.extents.x
        let headerHeight = headerMesh.bounds.extents.y

        // -- Body lines --
        var bodyLines: [String] = []
        if let rec = recommendation {
            bodyLines.append("FILL: \(rec.fillingRatePercent)%")
            let b = rec.shippingBox
            bodyLines.append(String(format: "BOX: %.0f x %.0f x %.0f cm", b.lengthCm, b.widthCm, b.heightCm))
        }
        let lVal = formatDimension(objectLength, unit: unit)
        let wVal = formatDimension(objectWidth, unit: unit)
        let hVal = formatDimension(objectHeight, unit: unit)
        bodyLines.append("OBJ: \(lVal) x \(wVal) x \(hVal) \(unit.rawValue)")

        let bodyText = bodyLines.joined(separator: "\n")
        let bodyMesh = MeshResource.generateText(
            bodyText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardBodyFontSize, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byWordWrapping
        )
        let bodyMaterial = UnlitMaterial(color: billboardTextColor)
        let bodyEntity = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
        let bodyWidth = bodyMesh.bounds.extents.x
        let bodyHeight = bodyMesh.bounds.extents.y

        // -- Layout --
        let gap: Float = 0.004
        let contentWidth = max(headerWidth, bodyWidth)
        let contentHeight = headerHeight + gap + bodyHeight
        let totalWidth = accentBarWidth + innerPadding + contentWidth + padding * 2
        let totalHeight = contentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.12

        // -- Background --
        let backgroundMesh = MeshResource.generateBox(
            size: [totalWidth, totalHeight, 0.001],
            cornerRadius: cornerRadius
        )
        var backgroundMaterial = UnlitMaterial(color: billboardBgColor)
        backgroundMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])

        // -- Accent bar --
        let accentHeight = contentHeight + padding
        let accentMesh = MeshResource.generateBox(
            size: [accentBarWidth, accentHeight, 0.0015],
            cornerRadius: accentBarWidth * 0.4
        )
        let accentMaterial = UnlitMaterial(color: billboardAccentColor)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [accentMaterial])

        // -- Top border line --
        let topBorderMesh = MeshResource.generateBox(
            size: [totalWidth * 0.9, 0.0005, 0.0012]
        )
        var topBorderMaterial = UnlitMaterial(color: billboardTopBorderColor)
        topBorderMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let topBorderEntity = ModelEntity(mesh: topBorderMesh, materials: [topBorderMaterial])

        // -- Position everything --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        backgroundEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)
        topBorderEntity.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        headerEntity.position = SIMD3<Float>(textLeftX, padding + bodyHeight + gap, 0)
        bodyEntity.position = SIMD3<Float>(textLeftX, padding, 0)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(topBorderEntity)
        containerEntity.addChild(headerEntity)
        containerEntity.addChild(bodyEntity)

        entity.addChild(containerEntity)
        billboardEntity = containerEntity
    }

    // MARK: - Edge Creation

    private func createEdges(for box: BoundingBox3D) {
        let edges = box.edges

        for (index, (start, end)) in edges.enumerated() {
            let edgeGroup = createDualEdgeEntity(from: start, to: end, index: index)
            entity.addChild(edgeGroup)
            edgeEntities.append(edgeGroup)
        }
    }

    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> Entity {
        let parent = Entity()
        parent.name = "shipping_edge_\(index)"

        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow layer (thicker than measurement wireframe for visibility)
        let outerRadius: Float = outerEdgeRadius * 1.5
        let outerMesh = MeshResource.generateBox(size: [outerRadius * 2, outerRadius * 2, length])
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.30))
        let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
        outerEntity.name = "shipping_edge_outer_\(index)"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation

        // Inner line
        let innerRadius: Float = innerEdgeRadius * 1.3
        let innerMesh = MeshResource.generateBox(size: [innerRadius * 2, innerRadius * 2, length])
        var innerMaterial = UnlitMaterial(color: innerEdgeColor)
        innerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let innerEntity = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
        innerEntity.name = "shipping_edge_inner_\(index)"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    // MARK: - Helpers

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

    private func formatDimension(_ meters: Float, unit: MeasurementUnit) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

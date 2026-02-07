//
//  AnimatedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box with wireframe-rise animation.
/// After the second tap, the scanning line disappears and the wireframe rises from bottom to top.
class AnimatedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity

    // Edge entities (dual-layer: inner + outer per edge)
    private var bottomEdgeGroups: [Entity] = []    // 4 bottom dual-edge groups
    private var verticalEdgeGroups: [Entity] = []  // 4 vertical dual-edge groups
    private var topEdgeGroups: [Entity] = []       // 4 top dual-edge groups

    // Corner markers
    private var bottomCornerMarkers: [ModelEntity] = [] // 4 bottom corners
    private var topCornerMarkers: [ModelEntity] = []    // 4 top corners

    private(set) var boundingBox: BoundingBox3D

    // Target corners (at object position)
    private var targetBottomCorners: [SIMD3<Float>] = []
    private var targetTopCorners: [SIMD3<Float>] = []

    // Animation state
    private var animationTimer: Timer?
    private var animationStartTime: Date?

    // MARK: - Constants

    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInner
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuter
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadius
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarker

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        self.entity = Entity()
        computeTargetCorners()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// Setup visualization at the target 3D position.
    func setupAtTargetPosition() {
        createVisualization()
    }

    /// Wireframe rises from bottom to top with Y-based staggered alpha and upward offset.
    func animateWireframeRise(duration: TimeInterval, completion: @escaping () -> Void) {
        animationTimer?.invalidate()
        animationStartTime = Date()

        let bottomY = targetBottomCorners.map(\.y).min() ?? 0
        let topY = targetTopCorners.map(\.y).max() ?? 1
        let yRange = max(Float(0.001), topY - bottomY)
        let riseOffset = yRange * PMTheme.wireframeRiseOffset

        // Start offset down and invisible
        entity.position.y = -riseOffset
        setAllEdgeAlpha(0)
        for marker in bottomCornerMarkers + topCornerMarkers {
            marker.isEnabled = false
            marker.scale = SIMD3<Float>(repeating: 0.01)
        }

        let softEdge = yRange * 0.3

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))
            let easedT = self.cubicEaseOut(t)

            // Rise position: offset down → target
            self.entity.position.y = -riseOffset * (1 - easedT)

            // Y threshold sweeps from below bottom to above top
            let threshold = bottomY - riseOffset + (yRange + riseOffset * 2) * easedT

            // Bottom edges
            for (i, group) in self.bottomEdgeGroups.enumerated() {
                let edgeY = (self.targetBottomCorners[i].y + self.targetBottomCorners[(i + 1) % 4].y) / 2
                let alpha = self.riseAlpha(midY: edgeY, threshold: threshold, softEdge: softEdge)
                self.setDualEdgeAlpha(group, alpha: alpha)
            }

            // Vertical edges
            for (i, group) in self.verticalEdgeGroups.enumerated() {
                let edgeY = (self.targetBottomCorners[i].y + self.targetTopCorners[i].y) / 2
                let alpha = self.riseAlpha(midY: edgeY, threshold: threshold, softEdge: softEdge)
                self.setDualEdgeAlpha(group, alpha: alpha)
            }

            // Top edges
            for (i, group) in self.topEdgeGroups.enumerated() {
                let edgeY = (self.targetTopCorners[i].y + self.targetTopCorners[(i + 1) % 4].y) / 2
                let alpha = self.riseAlpha(midY: edgeY, threshold: threshold, softEdge: softEdge)
                self.setDualEdgeAlpha(group, alpha: alpha)
            }

            // Bottom corner markers
            for (i, marker) in self.bottomCornerMarkers.enumerated() {
                let markerY = self.targetBottomCorners[i].y
                let alpha = self.riseAlpha(midY: markerY, threshold: threshold, softEdge: softEdge)
                marker.isEnabled = alpha > 0.01
                marker.scale = SIMD3<Float>(repeating: alpha)
                self.setCornerMarkerAlpha(marker, alpha: alpha)
            }

            // Top corner markers
            for (i, marker) in self.topCornerMarkers.enumerated() {
                let markerY = self.targetTopCorners[i].y
                let alpha = self.riseAlpha(midY: markerY, threshold: threshold, softEdge: softEdge)
                marker.isEnabled = alpha > 0.01
                marker.scale = SIMD3<Float>(repeating: alpha)
                self.setCornerMarkerAlpha(marker, alpha: alpha)
            }

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Ensure fully visible at target position
                self.entity.position.y = 0
                self.setAllEdgeAlpha(1.0)
                for marker in self.bottomCornerMarkers + self.topCornerMarkers {
                    marker.isEnabled = true
                    marker.scale = SIMD3<Float>(repeating: 1.0)
                    self.setCornerMarkerAlpha(marker, alpha: 1.0)
                }

                completion()
            }
        }
    }

    // MARK: - Private Methods - Rise Alpha

    /// Smoothstep alpha based on Y threshold crossing.
    private func riseAlpha(midY: Float, threshold: Float, softEdge: Float) -> Float {
        let raw = (threshold - midY + softEdge) / max(0.001, softEdge * 2)
        let clamped = max(Float(0), min(Float(1), raw))
        return clamped * clamped * (3 - 2 * clamped)
    }

    // MARK: - Private Methods - Corner Computation

    private func computeTargetCorners() {
        let corners = boundingBox.corners
        let sortedByY = corners.enumerated().sorted { $0.element.y < $1.element.y }
        let bottomIndices = sortedByY.prefix(4).map { $0.offset }
        let topIndices = sortedByY.suffix(4).map { $0.offset }

        targetBottomCorners = sortCornersClockwise(bottomIndices.map { corners[$0] })
        targetTopCorners = sortCornersClockwise(topIndices.map { corners[$0] })
    }

    private func sortCornersClockwise(_ corners: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard corners.count == 4 else { return corners }
        let centroid = corners.reduce(SIMD3<Float>(0, 0, 0), +) / Float(corners.count)
        return corners.sorted { a, b in
            let angleA = atan2(a.z - centroid.z, a.x - centroid.x)
            let angleB = atan2(b.z - centroid.z, b.x - centroid.x)
            return angleA < angleB
        }
    }

    // MARK: - Private Methods - Creation

    private func createVisualization() {
        for child in entity.children {
            child.removeFromParent()
        }
        bottomEdgeGroups.removeAll()
        verticalEdgeGroups.removeAll()
        topEdgeGroups.removeAll()
        bottomCornerMarkers.removeAll()
        topCornerMarkers.removeAll()

        createEdges()
        createCornerMarkers()
    }

    private func createEdges() {
        // Bottom edges
        for i in 0..<4 {
            let start = targetBottomCorners[i]
            let end = targetBottomCorners[(i + 1) % 4]
            let group = createDualEdgeEntity(from: start, to: end, name: "anim_bottom_\(i)")
            setDualEdgeAlpha(group, alpha: 0)
            entity.addChild(group)
            bottomEdgeGroups.append(group)
        }

        // Vertical edges
        for i in 0..<4 {
            let group = createDualEdgeEntity(from: targetBottomCorners[i], to: targetTopCorners[i], name: "anim_vert_\(i)")
            setDualEdgeAlpha(group, alpha: 0)
            entity.addChild(group)
            verticalEdgeGroups.append(group)
        }

        // Top edges
        for i in 0..<4 {
            let start = targetTopCorners[i]
            let end = targetTopCorners[(i + 1) % 4]
            let group = createDualEdgeEntity(from: start, to: end, name: "anim_top_\(i)")
            setDualEdgeAlpha(group, alpha: 0)
            entity.addChild(group)
            topEdgeGroups.append(group)
        }
    }

    private func createCornerMarkers() {
        // Bottom
        for (i, corner) in targetBottomCorners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "anim_corner_bottom_\(i)"
            sphere.position = corner
            sphere.isEnabled = false
            sphere.scale = SIMD3<Float>(repeating: 0.01)
            entity.addChild(sphere)
            bottomCornerMarkers.append(sphere)
        }

        // Top
        for (i, corner) in targetTopCorners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "anim_corner_top_\(i)"
            sphere.position = corner
            sphere.isEnabled = false
            sphere.scale = SIMD3<Float>(repeating: 0.01)
            entity.addChild(sphere)
            topCornerMarkers.append(sphere)
        }
    }

    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, name: String) -> Entity {
        let parent = Entity()
        parent.name = name

        let direction = end - start
        let length = max(simd_length(direction), 0.001)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow
        let outerMesh = MeshResource.generateBox(size: [outerEdgeRadius * 2, outerEdgeRadius * 2, length])
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
        outerEntity.name = "\(name)_outer"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation

        // Inner bright
        let innerMesh = MeshResource.generateBox(size: [innerEdgeRadius * 2, innerEdgeRadius * 2, length])
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
        innerEntity.name = "\(name)_inner"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    // MARK: - Private Methods - Alpha Control

    /// Set alpha on a corner marker entity
    private func setCornerMarkerAlpha(_ marker: ModelEntity, alpha: Float) {
        let clampedAlpha = max(0, min(1, alpha))
        let color = cornerMarkerColor.withAlphaComponent(CGFloat(clampedAlpha))
        var material = UnlitMaterial(color: color)
        if clampedAlpha < 1.0 {
            material.blending = .transparent(opacity: .init(floatLiteral: clampedAlpha))
        }
        marker.model?.materials = [material]
    }

    private func setAllEdgeAlpha(_ alpha: Float) {
        let allGroups = bottomEdgeGroups + verticalEdgeGroups + topEdgeGroups
        for group in allGroups {
            setDualEdgeAlpha(group, alpha: alpha)
        }
    }

    private func setDualEdgeAlpha(_ group: Entity, alpha: Float) {
        for child in group.children {
            guard let modelEntity = child as? ModelEntity else { continue }
            if child.name.contains("inner") {
                let color = innerEdgeColor.withAlphaComponent(CGFloat(alpha))
                var material = UnlitMaterial(color: color)
                if alpha < 1.0 {
                    material.blending = .transparent(opacity: .init(floatLiteral: alpha))
                }
                modelEntity.model?.materials = [material]
            } else if child.name.contains("outer") {
                let outerAlpha = alpha * 0.15
                let color = outerEdgeColor.withAlphaComponent(CGFloat(outerAlpha))
                var material = UnlitMaterial(color: color)
                material.blending = .transparent(opacity: .init(floatLiteral: outerAlpha))
                modelEntity.model?.materials = [material]
            }
        }
    }

    // MARK: - Helper Methods

    private func calculateOrientation(direction: SIMD3<Float>) -> simd_quatf {
        let len = simd_length(direction)
        guard len > 0.001 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let defaultDirection = SIMD3<Float>(0, 0, 1)
        let normalizedDirection = direction / len
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

    private func cubicEaseOut(_ t: Float) -> Float {
        let p = t - 1.0
        return p * p * p + 1.0
    }
}

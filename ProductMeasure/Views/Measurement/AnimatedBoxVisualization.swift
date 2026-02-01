//
//  AnimatedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box with animation support
/// The box animates by growing vertically from the bottom plane upward (world Y direction)
class AnimatedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity

    // Edge entities
    private var bottomEdgeEntities: [ModelEntity] = []   // 4 edges on bottom (lowest world Y)
    private var verticalEdgeEntities: [ModelEntity] = [] // 4 vertical edges
    private var topEdgeEntities: [ModelEntity] = []      // 4 edges on top (highest world Y)

    private(set) var boundingBox: BoundingBox3D

    /// Current animation progress (0 = bottom only, 1 = full box)
    private(set) var verticalProgress: Float = 0

    // Bottom and top corners sorted by world Y
    private var bottomCorners: [SIMD3<Float>] = []
    private var topCorners: [SIMD3<Float>] = []

    // Animation timer
    private var animationTimer: Timer?
    private var animationStartTime: Date?
    private var animationDuration: TimeInterval = 0.35

    // MARK: - Constants

    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.9)
    private let lineRadius: Float = 0.002

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        self.entity = Entity()
        computeBottomAndTopCorners()
        createVisualization()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// Update the bounding box dimensions
    func update(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        computeBottomAndTopCorners()
        updateAllEdges()
    }

    /// Show only the bottom plane immediately
    func showBottomPlaneOnly() {
        verticalProgress = 0

        // Show bottom edges
        for edge in bottomEdgeEntities {
            edge.isEnabled = true
        }

        // Hide vertical and top edges
        for edge in verticalEdgeEntities {
            edge.isEnabled = false
        }
        for edge in topEdgeEntities {
            edge.isEnabled = false
        }

        updateBottomEdges()
    }

    /// Animate to show the full box - grows from bottom to top (world Y direction)
    func animateToFullBox(duration: TimeInterval = 0.35, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        animationDuration = duration
        animationStartTime = Date()
        verticalProgress = 0

        // Enable vertical edges
        for edge in verticalEdgeEntities {
            edge.isEnabled = true
        }

        // Start animation timer (60 FPS)
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = Float(min(elapsed / self.animationDuration, 1.0))

            // Ease out curve
            let easedProgress = 1.0 - pow(1.0 - progress, 3)

            self.verticalProgress = easedProgress
            self.updateVerticalEdges()

            // Show top edges when nearly complete
            if easedProgress > 0.85 {
                for edge in self.topEdgeEntities {
                    edge.isEnabled = true
                }
                self.updateTopEdges()
            }

            // Complete
            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.verticalProgress = 1.0
                self.updateVerticalEdges()
                self.updateTopEdges()
                completion?()
            }
        }
    }

    // MARK: - Private Methods - Corner Sorting

    /// Compute bottom and top corners based on world Y coordinate
    private func computeBottomAndTopCorners() {
        let corners = boundingBox.corners

        // Sort corners by world Y coordinate
        let sortedByY = corners.enumerated().sorted { $0.element.y < $1.element.y }

        // Bottom 4 corners (lowest Y)
        let bottomIndices = sortedByY.prefix(4).map { $0.offset }
        // Top 4 corners (highest Y)
        let topIndices = sortedByY.suffix(4).map { $0.offset }

        bottomCorners = bottomIndices.map { corners[$0] }
        topCorners = topIndices.map { corners[$0] }

        // Sort bottom and top corners to match them correctly
        // Sort by angle around the centroid for consistent ordering
        bottomCorners = sortCornersClockwise(bottomCorners)
        topCorners = sortCornersClockwise(topCorners)
    }

    /// Sort corners in clockwise order around their centroid (for consistent edge matching)
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
        createBottomEdges()
        createVerticalEdges()
        createTopEdges()
    }

    private func createBottomEdges() {
        // Create edges connecting the 4 bottom corners
        for i in 0..<4 {
            let start = bottomCorners[i]
            let end = bottomCorners[(i + 1) % 4]
            let edge = createEdgeEntity(from: start, to: end)
            entity.addChild(edge)
            bottomEdgeEntities.append(edge)
        }
    }

    private func createVerticalEdges() {
        // Create vertical edges from bottom to top corners
        for i in 0..<4 {
            let bottomCorner = bottomCorners[i]
            // Start with minimal height edge
            let edge = createEdgeEntity(from: bottomCorner, to: bottomCorner + SIMD3<Float>(0, 0.001, 0))
            edge.isEnabled = false
            entity.addChild(edge)
            verticalEdgeEntities.append(edge)
        }
    }

    private func createTopEdges() {
        // Create edges connecting the 4 top corners
        for i in 0..<4 {
            let start = topCorners[i]
            let end = topCorners[(i + 1) % 4]
            let edge = createEdgeEntity(from: start, to: end)
            edge.isEnabled = false
            entity.addChild(edge)
            topEdgeEntities.append(edge)
        }
    }

    private func createEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>) -> ModelEntity {
        let direction = end - start
        let length = max(simd_length(direction), 0.001)

        let mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])
        var material = SimpleMaterial()
        material.color = .init(tint: lineColor)

        let edgeEntity = ModelEntity(mesh: mesh, materials: [material])
        edgeEntity.position = (start + end) / 2
        edgeEntity.orientation = calculateOrientation(direction: direction)

        return edgeEntity
    }

    // MARK: - Private Methods - Updates

    private func updateAllEdges() {
        updateBottomEdges()
        updateVerticalEdges()
        updateTopEdges()
    }

    private func updateBottomEdges() {
        for i in 0..<4 {
            guard i < bottomEdgeEntities.count else { continue }
            let start = bottomCorners[i]
            let end = bottomCorners[(i + 1) % 4]
            updateEdgeEntity(bottomEdgeEntities[i], from: start, to: end)
        }
    }

    private func updateVerticalEdges() {
        for i in 0..<4 {
            guard i < verticalEdgeEntities.count else { continue }

            let bottomCorner = bottomCorners[i]
            let topCorner = topCorners[i]

            // Interpolate from bottom to top based on progress
            let currentTop = simd_mix(bottomCorner, topCorner, SIMD3<Float>(repeating: verticalProgress))

            updateEdgeEntity(verticalEdgeEntities[i], from: bottomCorner, to: currentTop)
        }
    }

    private func updateTopEdges() {
        for i in 0..<4 {
            guard i < topEdgeEntities.count else { continue }

            // Interpolate top edge positions based on progress
            let startBottom = bottomCorners[i]
            let startTop = topCorners[i]
            let endBottom = bottomCorners[(i + 1) % 4]
            let endTop = topCorners[(i + 1) % 4]

            let currentStart = simd_mix(startBottom, startTop, SIMD3<Float>(repeating: verticalProgress))
            let currentEnd = simd_mix(endBottom, endTop, SIMD3<Float>(repeating: verticalProgress))

            updateEdgeEntity(topEdgeEntities[i], from: currentStart, to: currentEnd)
        }
    }

    private func updateEdgeEntity(_ edge: ModelEntity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let direction = end - start
        let length = max(simd_length(direction), 0.001)

        edge.position = (start + end) / 2
        edge.model?.mesh = MeshResource.generateBox(size: [lineRadius * 2, lineRadius * 2, length])

        if length > 0.001 {
            edge.orientation = calculateOrientation(direction: direction)
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
}

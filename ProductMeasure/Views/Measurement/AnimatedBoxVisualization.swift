//
//  AnimatedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box with animation support
/// Animation flow:
/// 1. Bottom plane starts at camera position (matching 2D bracket appearance)
/// 2. Bottom plane flies to object's actual bottom position
/// 3. Box grows vertically from bottom to top
class AnimatedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity

    // Edge entities
    private var bottomEdgeEntities: [ModelEntity] = []   // 4 edges on bottom
    private var verticalEdgeEntities: [ModelEntity] = [] // 4 vertical edges
    private var topEdgeEntities: [ModelEntity] = []      // 4 edges on top

    private(set) var boundingBox: BoundingBox3D

    /// Current animation progress for vertical growth (0 = bottom only, 1 = full box)
    private(set) var verticalProgress: Float = 0

    /// Current animation progress for flying (0 = at camera, 1 = at target)
    private(set) var flyProgress: Float = 0

    // Target corners (at object position)
    private var targetBottomCorners: [SIMD3<Float>] = []
    private var targetTopCorners: [SIMD3<Float>] = []

    // Start corners (at camera position)
    private var startBottomCorners: [SIMD3<Float>] = []

    // Animation state
    private var animationTimer: Timer?
    private var animationStartTime: Date?
    private var currentAnimationDuration: TimeInterval = 0.4

    // MARK: - Constants

    private let lineColor: UIColor = UIColor(white: 1.0, alpha: 0.9)
    private let lineRadius: Float = 0.002

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

    /// Setup the bottom plane at camera position, ready to fly to target
    /// - Parameters:
    ///   - cameraTransform: The camera's world transform
    ///   - distanceFromCamera: How far in front of camera to place the initial rect
    ///   - rectSize: Size of the initial rect (matches 2D bracket size)
    func setupAtCameraPosition(cameraTransform: simd_float4x4, distanceFromCamera: Float = 0.5, rectSize: Float = 0.3) {
        // Get camera position and forward direction
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Camera's forward is -Z in camera space
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Center of the initial rect (in front of camera)
        let startCenter = cameraPosition + cameraForward * distanceFromCamera

        // Get target bottom corners' centroid
        let targetCentroid = targetBottomCorners.reduce(SIMD3<Float>(0, 0, 0), +) / Float(targetBottomCorners.count)

        // Calculate the scale factor to match the desired rectSize
        // Get the average "radius" of the target shape
        let targetRadius = targetBottomCorners.map { simd_length($0 - targetCentroid) }.reduce(0, +) / Float(targetBottomCorners.count)
        let desiredRadius = rectSize / 2 * sqrt(2)  // diagonal of square / 2
        let scale = targetRadius > 0.001 ? desiredRadius / targetRadius : 1.0

        // Create start corners with the SAME shape as target, just translated and scaled
        // This prevents rotation during interpolation
        startBottomCorners = targetBottomCorners.map { corner in
            let offset = corner - targetCentroid  // offset from target center
            let scaledOffset = offset * scale      // scale to desired size
            return startCenter + scaledOffset      // translate to start position
        }

        // Create the visualization at start position
        flyProgress = 0
        verticalProgress = 0
        createVisualization()

        // Show only bottom edges at start position
        for edge in bottomEdgeEntities {
            edge.isEnabled = true
        }
        for edge in verticalEdgeEntities {
            edge.isEnabled = false
        }
        for edge in topEdgeEntities {
            edge.isEnabled = false
        }

        updateBottomEdgesForFly()
    }

    /// Animate the bottom plane flying from camera position to object bottom
    func animateFlyToBottom(duration: TimeInterval = 0.4, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        currentAnimationDuration = duration
        animationStartTime = Date()
        flyProgress = 0

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
            let progress = Float(min(elapsed / self.currentAnimationDuration, 1.0))

            // Ease out curve
            let easedProgress = 1.0 - pow(1.0 - progress, 3)

            self.flyProgress = easedProgress
            self.updateBottomEdgesForFly()

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.flyProgress = 1.0
                self.updateBottomEdgesForFly()
                completion?()
            }
        }
    }

    /// Animate the box growing vertically from bottom to top
    func animateGrowVertical(duration: TimeInterval = 0.35, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        currentAnimationDuration = duration
        animationStartTime = Date()
        verticalProgress = 0

        // Enable vertical edges
        for edge in verticalEdgeEntities {
            edge.isEnabled = true
        }

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
            let progress = Float(min(elapsed / self.currentAnimationDuration, 1.0))

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

    // MARK: - Private Methods - Corner Computation

    private func computeTargetCorners() {
        let corners = boundingBox.corners

        // Sort corners by world Y coordinate
        let sortedByY = corners.enumerated().sorted { $0.element.y < $1.element.y }

        // Bottom 4 corners (lowest Y)
        let bottomIndices = sortedByY.prefix(4).map { $0.offset }
        // Top 4 corners (highest Y)
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
        // Clear existing
        for child in entity.children {
            child.removeFromParent()
        }
        bottomEdgeEntities.removeAll()
        verticalEdgeEntities.removeAll()
        topEdgeEntities.removeAll()

        createBottomEdges()
        createVerticalEdges()
        createTopEdges()
    }

    private func createBottomEdges() {
        // Create 4 edges for the bottom plane
        for i in 0..<4 {
            let start = currentBottomCorners()[i]
            let end = currentBottomCorners()[(i + 1) % 4]
            let edge = createEdgeEntity(from: start, to: end)
            entity.addChild(edge)
            bottomEdgeEntities.append(edge)
        }
    }

    private func createVerticalEdges() {
        // Create vertical edges (initially hidden, at minimal height)
        for i in 0..<4 {
            let bottomCorner = targetBottomCorners[i]
            let edge = createEdgeEntity(from: bottomCorner, to: bottomCorner + SIMD3<Float>(0, 0.001, 0))
            edge.isEnabled = false
            entity.addChild(edge)
            verticalEdgeEntities.append(edge)
        }
    }

    private func createTopEdges() {
        // Create top edges (initially hidden)
        for i in 0..<4 {
            let start = targetTopCorners[i]
            let end = targetTopCorners[(i + 1) % 4]
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

    /// Get current bottom corners based on fly progress
    private func currentBottomCorners() -> [SIMD3<Float>] {
        guard startBottomCorners.count == 4, targetBottomCorners.count == 4 else {
            return targetBottomCorners
        }

        return (0..<4).map { i in
            simd_mix(startBottomCorners[i], targetBottomCorners[i], SIMD3<Float>(repeating: flyProgress))
        }
    }

    private func updateBottomEdgesForFly() {
        let corners = currentBottomCorners()
        for i in 0..<4 {
            guard i < bottomEdgeEntities.count else { continue }
            let start = corners[i]
            let end = corners[(i + 1) % 4]
            updateEdgeEntity(bottomEdgeEntities[i], from: start, to: end)
        }
    }

    private func updateVerticalEdges() {
        for i in 0..<4 {
            guard i < verticalEdgeEntities.count else { continue }

            let bottomCorner = targetBottomCorners[i]
            let topCorner = targetTopCorners[i]

            let currentTop = simd_mix(bottomCorner, topCorner, SIMD3<Float>(repeating: verticalProgress))
            updateEdgeEntity(verticalEdgeEntities[i], from: bottomCorner, to: currentTop)
        }
    }

    private func updateTopEdges() {
        for i in 0..<4 {
            guard i < topEdgeEntities.count else { continue }

            let startBottom = targetBottomCorners[i]
            let startTop = targetTopCorners[i]
            let endBottom = targetBottomCorners[(i + 1) % 4]
            let endTop = targetTopCorners[(i + 1) % 4]

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

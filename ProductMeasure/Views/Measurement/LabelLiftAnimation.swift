//
//  LabelLiftAnimation.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// AR lift animation: A 3D plane textured with the captured label image
/// peels off the box surface, floats toward the camera, and rotates to face forward.
class LabelLiftAnimation {

    private(set) var entity: Entity

    private var planeEntity: ModelEntity?
    private var glowBorderEntities: [ModelEntity] = []
    private var animationTimer: Timer?

    // Animation parameters
    private var worldCorners: [SIMD3<Float>] = []
    private var surfaceNormal: SIMD3<Float> = SIMD3(0, 0, 1)
    private var labelCenter: SIMD3<Float> = .zero
    private var labelWidth: Float = 0.1
    private var labelHeight: Float = 0.1

    // Colors
    private let glowInnerColor = PMTheme.uiLabelBlue
    private let glowOuterColor = PMTheme.uiLabelBlueGlow

    init() {
        self.entity = Entity()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Setup

    /// Create the label plane entity at the detected world position
    func setup(
        labelImage: UIImage,
        worldCorners: [SIMD3<Float>]?,
        surfaceNormal: SIMD3<Float>?,
        fallbackPosition: SIMD3<Float>? = nil
    ) {
        guard let corners = worldCorners, corners.count == 4 else {
            // Fallback: place at a default position
            if let pos = fallbackPosition {
                setupFallback(labelImage: labelImage, position: pos)
            }
            return
        }

        self.worldCorners = corners
        self.surfaceNormal = surfaceNormal ?? SIMD3(0, 0, 1)

        // Calculate center and dimensions
        labelCenter = (corners[0] + corners[1] + corners[2] + corners[3]) / 4.0
        labelWidth = max(
            simd_length(corners[1] - corners[0]),
            simd_length(corners[2] - corners[3])
        )
        labelHeight = max(
            simd_length(corners[3] - corners[0]),
            simd_length(corners[2] - corners[1])
        )

        // Create textured plane
        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)

        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane

        // Position at label center with orientation matching the surface
        entity.position = labelCenter
        entity.addChild(plane)

        // Orient entity to face along the surface normal
        let up = SIMD3<Float>(0, 1, 0)
        let forward = simd_normalize(self.surfaceNormal)
        let right = simd_normalize(simd_cross(up, forward))
        let correctedUp = simd_cross(forward, right)

        let rotationMatrix = simd_float3x3(columns: (right, correctedUp, forward))
        entity.orientation = simd_quatf(rotationMatrix)

        // Add glow border edges
        addGlowBorder()
    }

    private func setupFallback(labelImage: UIImage, position: SIMD3<Float>) {
        labelCenter = position
        labelWidth = 0.12
        labelHeight = 0.08
        surfaceNormal = SIMD3(0, 0, 1)

        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)
        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane
        entity.position = position
        entity.addChild(plane)
        addGlowBorder()
    }

    private func addGlowBorder() {
        let borderWidth: Float = 0.001
        let hw = labelWidth / 2
        let hh = labelHeight / 2

        // Inner bright border (4 edges)
        let innerMaterial = UnlitMaterial(color: glowInnerColor)
        // Outer glow border
        let outerMaterial = UnlitMaterial(color: glowOuterColor)

        let edges: [(SIMD3<Float>, Float, Bool)] = [
            // position, length, isHorizontal
            (SIMD3(0, hh, 0.001), labelWidth, true),    // top
            (SIMD3(0, -hh, 0.001), labelWidth, true),   // bottom
            (SIMD3(-hw, 0, 0.001), labelHeight, false),  // left
            (SIMD3(hw, 0, 0.001), labelHeight, false),   // right
        ]

        for (pos, length, isHorizontal) in edges {
            // Inner edge
            let innerMesh: MeshResource
            if isHorizontal {
                innerMesh = MeshResource.generateBox(size: SIMD3(length, borderWidth, borderWidth))
            } else {
                innerMesh = MeshResource.generateBox(size: SIMD3(borderWidth, length, borderWidth))
            }
            let innerEdge = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
            innerEdge.position = pos
            entity.addChild(innerEdge)
            glowBorderEntities.append(innerEdge)

            // Outer glow edge
            let outerWidth = borderWidth * 4
            let outerMesh: MeshResource
            if isHorizontal {
                outerMesh = MeshResource.generateBox(size: SIMD3(length, outerWidth, outerWidth))
            } else {
                outerMesh = MeshResource.generateBox(size: SIMD3(outerWidth, length, outerWidth))
            }
            let outerEdge = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
            outerEdge.position = pos
            entity.addChild(outerEdge)
            glowBorderEntities.append(outerEdge)
        }
    }

    // MARK: - Animation

    /// Animate the label lift: peel → move+rotate → settle
    func animate(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Target: 0.5m in front of camera
        let targetPosition = cameraPosition + cameraForward * 0.5
        // Target orientation: face the camera
        let targetOrientation = simd_quatf(
            from: SIMD3<Float>(0, 0, 1),
            to: simd_normalize(cameraPosition - targetPosition)
        )

        let startPosition = entity.position
        let startOrientation = entity.orientation
        let startScale = entity.scale

        let duration = PMTheme.labelLiftDuration
        let startTime = Date()

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let rawT = Float(min(elapsed / duration, 1.0))

            if rawT >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.entity.position = targetPosition
                self.entity.orientation = targetOrientation
                self.entity.scale = startScale * 1.3
                completion()
                return
            }

            // Phase breakdown
            if rawT <= 0.30 {
                // Peel: lift 5cm along surface normal
                let peelT = Self.easeOut(rawT / 0.30)
                let peelOffset = self.surfaceNormal * 0.05 * peelT
                self.entity.position = startPosition + peelOffset

            } else if rawT <= 0.80 {
                // Move + Rotate: slide toward camera, slerp orientation, scale up
                let moveT = Self.easeOutCubic((rawT - 0.30) / 0.50)
                let peelEnd = startPosition + self.surfaceNormal * 0.05

                self.entity.position = simd_mix(peelEnd, targetPosition, SIMD3(repeating: moveT))
                self.entity.orientation = simd_slerp(startOrientation, targetOrientation, moveT)
                self.entity.scale = startScale * (1.0 + 0.3 * moveT)

            } else {
                // Settle: small bounce at final position
                let settleT = (rawT - 0.80) / 0.20
                let bounceT = Self.easeOutBounce(settleT)

                let overshoot = targetPosition + cameraForward * 0.01
                self.entity.position = simd_mix(targetPosition, overshoot, SIMD3(repeating: 1.0 - bounceT))
                self.entity.orientation = targetOrientation
                self.entity.scale = startScale * 1.3
            }
        }
    }

    /// Dismiss the label with fade out
    func dismiss(completion: @escaping () -> Void) {
        let duration = PMTheme.labelDismissDuration
        let startTime = Date()
        let startScale = entity.scale

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))

            self.entity.scale = startScale * (1.0 - t)

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.entity.removeFromParent()
                completion()
            }
        }
    }

    // MARK: - Easing Functions

    private static func easeOut(_ t: Float) -> Float {
        1.0 - (1.0 - t) * (1.0 - t)
    }

    private static func easeOutCubic(_ t: Float) -> Float {
        1.0 - pow(1.0 - t, 3)
    }

    private static func easeOutBounce(_ t: Float) -> Float {
        let dampened = sin(t * .pi * 0.5)
        return dampened
    }
}

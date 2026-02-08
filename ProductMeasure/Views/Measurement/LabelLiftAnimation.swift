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
        cameraPosition: SIMD3<Float>? = nil,
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

        // Orient entity using actual world corners so the 3D plane matches
        // the label's real-world orientation exactly.
        // generatePlane: width along local X, height along local Z, face normal along local +Y
        // corners: [0]=topLeft, [1]=topRight, [2]=bottomRight, [3]=bottomLeft
        var rightDir = simd_normalize(corners[1] - corners[0])
        let downDir = simd_normalize(corners[3] - corners[0])
        var orthoDown = simd_normalize(downDir - simd_dot(downDir, rightDir) * rightDir)
        // Right-handed basis: Y = cross(Z, X)
        var normal = simd_normalize(simd_cross(orthoDown, rightDir))

        // Ensure normal points toward camera (face visible from camera side)
        if let camPos = cameraPosition {
            let toCamera = camPos - labelCenter
            if simd_dot(normal, toCamera) < 0 {
                // Normal faces away from camera — flip normal and one tangent
                normal = -normal
                orthoDown = -orthoDown
                // Maintain right-handed: Y = cross(Z, X) = cross(-orthoDown, rightDir) = -cross(orthoDown, rightDir) = normal ✓
            }
        }

        entity.orientation = simd_quatf(simd_float3x3(columns: (rightDir, normal, orthoDown)))

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

    /// Animate the label lift: move straight toward camera → settle
    func animate(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Target position: 35cm from label toward camera, at least 25cm from camera
        let toCamera = simd_normalize(cameraPosition - labelCenter)
        var targetPosition = labelCenter + toCamera * 0.35
        let distToCamera = simd_length(cameraPosition - targetPosition)
        if distToCamera < 0.25 {
            targetPosition = cameraPosition - toCamera * 0.25
        }

        // Target orientation: face the camera while staying upright (no spin)
        let toCameraFromTarget = simd_normalize(cameraPosition - targetPosition)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(worldUp, toCameraFromTarget))
        let correctedUp = simd_cross(toCameraFromTarget, right)
        let targetOrientation = simd_quatf(simd_float3x3(columns: (right, correctedUp, toCameraFromTarget)))

        let startPosition = entity.position
        let startOrientation = entity.orientation
        let startScale = entity.scale
        let finalScale: Float = 1.8

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
                self.entity.scale = startScale * finalScale
                completion()
                return
            }

            // Phase: Move (0–85%) → Settle (85–100%)
            if rawT <= 0.85 {
                // Move straight from label to target position
                let moveT = Self.easeOutCubic(rawT / 0.85)
                self.entity.position = simd_mix(startPosition, targetPosition, SIMD3(repeating: moveT))
                self.entity.orientation = simd_slerp(startOrientation, targetOrientation, moveT)
                self.entity.scale = startScale * (1.0 + (finalScale - 1.0) * moveT)

            } else {
                // Settle: subtle Y oscillation at final position
                let settleT = (rawT - 0.85) / 0.15
                let bounce = sin(settleT * .pi) * 0.005
                self.entity.position = targetPosition + SIMD3<Float>(0, bounce, 0)
                self.entity.orientation = targetOrientation
                self.entity.scale = startScale * finalScale
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

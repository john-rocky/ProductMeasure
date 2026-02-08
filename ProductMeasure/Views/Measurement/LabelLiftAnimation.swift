//
//  LabelLiftAnimation.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// AR lift animation: A 3D plane textured with the captured label image
/// starts exactly on top of the real label, then lifts toward the camera.
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

    /// Create the label plane entity placed exactly on top of the real label
    func setup(
        labelImage: UIImage,
        worldCorners: [SIMD3<Float>]?,
        surfaceNormal: SIMD3<Float>?,
        cameraTransform: simd_float4x4? = nil,
        fallbackPosition: SIMD3<Float>? = nil
    ) {
        guard let corners = worldCorners, corners.count == 4 else {
            if let pos = fallbackPosition {
                setupFallback(labelImage: labelImage, position: pos)
            }
            return
        }

        self.worldCorners = corners
        self.surfaceNormal = surfaceNormal ?? SIMD3(0, 1, 0)

        // Calculate center and dimensions from world corners
        labelCenter = (corners[0] + corners[1] + corners[2] + corners[3]) / 4.0
        labelWidth = max(
            simd_length(corners[1] - corners[0]),
            simd_length(corners[2] - corners[3])
        )
        labelHeight = max(
            simd_length(corners[3] - corners[0]),
            simd_length(corners[2] - corners[1])
        )

        // Simple plane in XY (vertical by default), face normal +Z
        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)
        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane

        // Orient: face normal (+Z for generatePlane(width:height:)) toward camera
        var normal = simd_normalize(self.surfaceNormal)
        if let camTransform = cameraTransform {
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            if simd_dot(normal, camPos - labelCenter) < 0 {
                normal = -normal
            }
        }

        // Step 1: Align face normal (+Z) to surface normal
        let q1 = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)

        // Step 2: Roll correction using world corners
        // After q1, local +X (plane's width axis) is at:
        let currentRight = simd_act(q1, SIMD3<Float>(1, 0, 0))

        // Find the world corner edge direction closest to currentRight on the surface plane
        let edgeCandidates = [
            corners[1] - corners[0],
            corners[0] - corners[1],
            corners[3] - corners[0],
            corners[0] - corners[3],
        ]
        var bestDir = currentRight
        var bestDot: Float = -1
        for edge in edgeCandidates {
            var projected = edge - simd_dot(edge, normal) * normal
            let len = simd_length(projected)
            guard len > 0.001 else { continue }
            projected = projected / len
            let d = simd_dot(projected, currentRight)
            if d > bestDot {
                bestDot = d
                bestDir = projected
            }
        }

        // Compute roll around normal to align currentRight → bestDir
        let rollDot = max(-1, min(1, simd_dot(currentRight, bestDir)))
        let rollCross = simd_cross(currentRight, bestDir)
        let rollAngle = atan2(simd_dot(rollCross, normal), rollDot)
        let q2 = simd_quatf(angle: rollAngle, axis: normal)

        let orientation = q2 * q1

        entity.position = labelCenter
        entity.orientation = orientation
        entity.addChild(plane)

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

        let innerMaterial = UnlitMaterial(color: glowInnerColor)
        let outerMaterial = UnlitMaterial(color: glowOuterColor)

        // Edges in entity local space (XY rectangle, Z = face normal)
        let edges: [(SIMD3<Float>, Float, Bool)] = [
            (SIMD3(0,  hh, 0.001), labelWidth, true),   // top
            (SIMD3(0, -hh, 0.001), labelWidth, true),   // bottom
            (SIMD3(-hw, 0, 0.001), labelHeight, false),  // left
            (SIMD3( hw, 0, 0.001), labelHeight, false),  // right
        ]

        for (pos, length, isHorizontal) in edges {
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

        // Target orientation: rotate mesh face normal (+Y) to point toward camera.
        // simd_quatf(from:to:) gives shortest-arc rotation, preserving text orientation.
        let facingDir = simd_normalize(cameraPosition - targetPosition)
        let targetOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: facingDir)

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
                let moveT = Self.easeOutCubic(rawT / 0.85)
                self.entity.position = simd_mix(startPosition, targetPosition, SIMD3(repeating: moveT))
                self.entity.orientation = simd_slerp(startOrientation, targetOrientation, moveT)
                self.entity.scale = startScale * (1.0 + (finalScale - 1.0) * moveT)

            } else {
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

    private static func easeOutCubic(_ t: Float) -> Float {
        1.0 - pow(1.0 - t, 3)
    }
}

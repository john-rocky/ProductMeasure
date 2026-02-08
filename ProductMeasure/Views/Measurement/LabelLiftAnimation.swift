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

        // Simple plane with RealityKit's built-in UV mapping
        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)
        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane

        // Orient: face normal (+Y) toward camera
        var normal = simd_normalize(self.surfaceNormal)
        if let camTransform = cameraTransform {
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            if simd_dot(normal, camPos - labelCenter) < 0 {
                normal = -normal
            }
        }
        let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normal)

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

        // Edges in entity local space (XZ rectangle, Y = face normal)
        let edges: [(SIMD3<Float>, Float, Bool)] = [
            (SIMD3(0, 0.001, -hh), labelWidth, true),   // top
            (SIMD3(0, 0.001,  hh), labelWidth, true),   // bottom
            (SIMD3(-hw, 0.001, 0), labelHeight, false),  // left
            (SIMD3( hw, 0.001, 0), labelHeight, false),  // right
        ]

        for (pos, length, isHorizontal) in edges {
            let innerMesh: MeshResource
            if isHorizontal {
                innerMesh = MeshResource.generateBox(size: SIMD3(length, borderWidth, borderWidth))
            } else {
                innerMesh = MeshResource.generateBox(size: SIMD3(borderWidth, borderWidth, length))
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
                outerMesh = MeshResource.generateBox(size: SIMD3(outerWidth, outerWidth, length))
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

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
    private var scanEntities: [ModelEntity] = []
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
        // Black drop shadow behind the label (two layers for soft falloff)
        let layers: [(margin: Float, zOffset: Float, alpha: CGFloat)] = [
            (0.002, -0.0004, 0.15),  // tight shadow
            (0.005, -0.0008, 0.06),  // soft outer shadow
        ]

        for layer in layers {
            let mesh = MeshResource.generateBox(size: SIMD3(
                labelWidth + layer.margin * 2,
                labelHeight + layer.margin * 2,
                0.0002
            ))
            var material = UnlitMaterial()
            material.color = .init(tint: glowInnerColor.withAlphaComponent(layer.alpha))
            material.blending = .transparent(opacity: .init(floatLiteral: Float(layer.alpha)))
            let shadowEntity = ModelEntity(mesh: mesh, materials: [material])
            shadowEntity.position = SIMD3(0, 0, layer.zOffset)  // behind the label
            entity.addChild(shadowEntity)
            glowBorderEntities.append(shadowEntity)
        }
    }

    // MARK: - Animation

    /// Animate: scan overlay → reveal label → lift toward camera
    func animate(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        // Hide label and glow border during scan phase
        planeEntity?.scale = .zero
        for border in glowBorderEntities { border.scale = .zero }

        // Create scan overlay (faint green rectangle covering label area)
        var overlayMaterial = UnlitMaterial()
        overlayMaterial.color = .init(tint: glowInnerColor.withAlphaComponent(0.08))
        overlayMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.08))
        let overlayMesh = MeshResource.generateBox(size: SIMD3(labelWidth, labelHeight, 0.0001))
        let overlayEntity = ModelEntity(mesh: overlayMesh, materials: [overlayMaterial])
        overlayEntity.position = SIMD3(0, 0, 0.0005)
        entity.addChild(overlayEntity)
        scanEntities.append(overlayEntity)

        // Create scanline bar (bright green line sweeping top to bottom)
        var scanMaterial = UnlitMaterial()
        scanMaterial.color = .init(tint: glowInnerColor.withAlphaComponent(0.5))
        scanMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        let barHeight: Float = 0.002
        let scanMesh = MeshResource.generateBox(size: SIMD3(labelWidth * 1.05, barHeight, 0.0001))
        let scanLineEntity = ModelEntity(mesh: scanMesh, materials: [scanMaterial])
        let hh = labelHeight / 2
        scanLineEntity.position = SIMD3(0, hh, 0.001)
        entity.addChild(scanLineEntity)
        scanEntities.append(scanLineEntity)

        // Scan phase: sweep scanline top → bottom
        let scanDuration: Double = 0.5
        let scanStart = Date()

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(scanStart)
            let t = Float(min(elapsed / scanDuration, 1.0))

            // Move scanline from top to bottom
            scanLineEntity.position.y = hh - t * self.labelHeight

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Remove scan entities
                for e in self.scanEntities { e.removeFromParent() }
                self.scanEntities.removeAll()

                // Reveal label and glow border
                self.planeEntity?.scale = .one
                for border in self.glowBorderEntities { border.scale = .one }

                // Start lift animation
                self.startLiftAnimation(cameraTransform: cameraTransform, completion: completion)
            }
        }
    }

    /// Lift animation: rise → present → settle
    private func startLiftAnimation(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Midpoint: rise up 1cm from label surface
        let midPosition = SIMD3<Float>(labelCenter.x, labelCenter.y + 0.01, labelCenter.z)

        // Camera forward axis
        let camForward = -simd_normalize(SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        ))

        // Compute distance and scale so label fills ~85% of screen
        // iPhone portrait vertical FOV ≈ 60°, aspect ≈ width/height
        let vertFOV: Float = 60.0 * .pi / 180.0
        let screenAspect: Float = 9.0 / 19.5  // portrait iPhone
        let fillFraction: Float = 0.85
        let placeDist: Float = 0.30  // 30cm from camera

        let visibleH = 2.0 * placeDist * tan(vertFOV / 2.0)
        let visibleW = visibleH * screenAspect
        let scaleForH = fillFraction * visibleH / labelHeight
        let scaleForW = fillFraction * visibleW / labelWidth
        let finalScale = min(scaleForH, scaleForW)

        let finalPosition = cameraPosition + camForward * placeDist

        // Target orientation: face toward camera (face normal = +Z for this mesh)
        // with upright text (local +Y = screen up)
        let facingDir = simd_normalize(cameraPosition - finalPosition)

        // Step 1: rotate face normal +Z to facingDir
        let tq1 = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: facingDir)

        // Step 2: roll correction so text is upright on screen
        let currentUp = simd_act(tq1, SIMD3<Float>(0, 1, 0))
        let sensorRight = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let screenUp = -sensorRight
        var desiredUp = screenUp - simd_dot(screenUp, facingDir) * facingDir
        if simd_length(desiredUp) < 0.001 {
            desiredUp = simd_normalize(simd_cross(facingDir, sensorRight))
        } else {
            desiredUp = simd_normalize(desiredUp)
        }
        let rollDot = max(Float(-1), min(Float(1), simd_dot(currentUp, desiredUp)))
        let rollCross = simd_cross(currentUp, desiredUp)
        let rollAngle = atan2(simd_dot(rollCross, facingDir), rollDot)
        let tq2 = simd_quatf(angle: rollAngle, axis: facingDir)
        let targetOrientation = tq2 * tq1

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
                self.entity.position = finalPosition
                self.entity.orientation = targetOrientation
                self.entity.scale = startScale * finalScale
                completion()
                return
            }

            // Phase 1: Rise (0–40%) — lift up from label surface to midpoint
            // Phase 2: Present (40–85%) — move from midpoint to final position in front of camera
            // Phase 3: Settle (85–100%) — subtle bounce
            if rawT <= 0.40 {
                let riseT = Self.easeOutCubic(rawT / 0.40)
                self.entity.position = simd_mix(startPosition, midPosition, SIMD3(repeating: riseT))
                self.entity.scale = startScale * (1.0 + (finalScale - 1.0) * riseT * 0.3)

            } else if rawT <= 0.85 {
                let presentT = Self.easeOutCubic((rawT - 0.40) / 0.45)
                self.entity.position = simd_mix(midPosition, finalPosition, SIMD3(repeating: presentT))
                self.entity.orientation = simd_slerp(startOrientation, targetOrientation, presentT)
                self.entity.scale = startScale * (1.0 + (finalScale - 1.0) * (0.3 + 0.7 * presentT))

            } else {
                let settleT = (rawT - 0.85) / 0.15
                let bounce = sin(settleT * .pi) * 0.005
                self.entity.position = finalPosition + SIMD3<Float>(0, bounce, 0)
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

//
//  AnimatedBoxVisualization.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd
import ARKit

/// Creates RealityKit entities for visualizing a 3D bounding box with scan-reveal animation.
/// Animation flow:
/// 1. Scan reveal: scan line sweeps, face panels glow behind it
/// 2. Face pulse: panels pulse 2 times
/// 3. Converge to edges: center holes open, light gathers to wireframe edges
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

    // Face panel entities: 6 faces, each with center + 4 edge strips
    private var faceCenterPanels: [ModelEntity] = []         // 6 center quads
    private var faceEdgeStrips: [[ModelEntity]] = []         // 6 × 4 edge strips

    // Object screen bounding region (for unified scan-reveal)
    private var objectScreenMinX: CGFloat = 0
    private var objectScreenMaxX: CGFloat = 0

    // Stored screen size from setup (used in scan reveal)
    private var storedScreenSize: CGSize = .zero

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
    private let pulseColor: UIColor = PMTheme.uiPulseColor

    private let facePanelAlpha: Float = PMTheme.facePanelAlpha
    private let faceCenterAlpha: Float = PMTheme.faceCenterAlpha

    // Face panel color (same neon green family)
    private let facePanelColor: UIColor = UIColor(hex: 0x39FF14)

    // Thin box depth for double-sided face panels
    private let facePanelDepth: Float = 0.0005

    // MARK: - Face Definition

    /// 6 faces defined by 4 corner indices each (from BoundingBox3D.corners)
    /// Corner layout:
    ///   0: (-1,-1,-1), 1: (1,-1,-1), 2: (1,1,-1), 3: (-1,1,-1)
    ///   4: (-1,-1, 1), 5: (1,-1, 1), 6: (1,1, 1), 7: (-1,1, 1)
    private static let faceCornerIndices: [[Int]] = [
        [0, 1, 5, 4],  // Bottom (Y=-1)
        [3, 2, 6, 7],  // Top (Y=+1)
        [0, 1, 2, 3],  // Back (Z=-1)
        [4, 5, 6, 7],  // Front (Z=+1)
        [0, 3, 7, 4],  // Left (X=-1)
        [1, 2, 6, 5],  // Right (X=+1)
    ]

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
    /// Projects bounding box corners to screen space for unified scan-reveal.
    func setupAtTargetPosition(frame: ARFrame, screenSize: CGSize) {
        storedScreenSize = screenSize

        // Create all geometry (all initially invisible)
        createVisualization()

        // Project bounding box corners to compute object screen bounds
        computeObjectScreenBounds(frame: frame, screenSize: screenSize)
    }

    /// Phase 1: Scan line single-sweep, all faces glow together as line crosses the object region
    func animateScanReveal(duration: TimeInterval, progressCallback: @escaping (Float) -> Void, completion: @escaping () -> Void) {
        animationTimer?.invalidate()
        animationStartTime = Date()
        let screenWidth = storedScreenSize.width

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(Float(elapsed / duration), 1.0)

            // Report progress for ScanningLineView override
            progressCallback(progress)

            // Scan line position on screen
            let lineScreenX = CGFloat(progress) * screenWidth

            // Compute unified face alpha based on scan line position within object region
            let objectSpan = max(1.0, self.objectScreenMaxX - self.objectScreenMinX)
            let regionProgress = (lineScreenX - self.objectScreenMinX) / objectSpan
            let clampedRegionProgress = Float(max(0, min(1, regionProgress)))

            // Smoothstep for smooth appearance
            let easedAlpha = clampedRegionProgress * clampedRegionProgress * (3.0 - 2.0 * clampedRegionProgress)

            // Apply same alpha to ALL faces simultaneously
            for i in 0..<min(6, self.faceCenterPanels.count) {
                let faceAlpha = easedAlpha * self.facePanelAlpha
                let centerAlpha = easedAlpha * (self.facePanelAlpha + self.faceCenterAlpha)
                self.setFacePanelAlpha(faceIndex: i, alpha: faceAlpha, centerAlpha: centerAlpha)
            }

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Ensure all faces at target alpha
                for i in 0..<min(6, self.faceCenterPanels.count) {
                    self.setFacePanelAlpha(faceIndex: i, alpha: self.facePanelAlpha, centerAlpha: self.facePanelAlpha + self.faceCenterAlpha)
                }

                completion()
            }
        }
    }

    /// Phase 2: Face panels pulse 2 times
    func animateFacePulse(duration: TimeInterval, completion: @escaping () -> Void) {
        animationTimer?.invalidate()
        animationStartTime = Date()

        let pulseCount: Float = 2.0
        let baseAlpha = facePanelAlpha
        let baseCenterAlpha = facePanelAlpha + faceCenterAlpha
        let amplitude: Float = 0.12

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))
            let sineVal = sin(2.0 * Float.pi * pulseCount * t)

            let currentAlpha = baseAlpha + amplitude * sineVal
            let currentCenterAlpha = baseCenterAlpha + amplitude * sineVal

            for i in 0..<min(6, self.faceCenterPanels.count) {
                self.setFacePanelAlpha(faceIndex: i, alpha: currentAlpha, centerAlpha: currentCenterAlpha)
            }

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Reset to base alpha
                for i in 0..<min(6, self.faceCenterPanels.count) {
                    self.setFacePanelAlpha(faceIndex: i, alpha: baseAlpha, centerAlpha: baseCenterAlpha)
                }

                completion()
            }
        }
    }

    /// Phase 3: Center hole opens, edge strips shrink and fade, wireframe edges brighten
    func animateConvergeToEdges(duration: TimeInterval, completion: @escaping () -> Void) {
        animationTimer?.invalidate()
        animationStartTime = Date()

        // Store initial edge strip scales for shrinking
        let initialStripScales: [[SIMD3<Float>]] = faceEdgeStrips.map { strips in
            strips.map { $0.scale }
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))

            // Center quads fade: 0% - 40%
            let centerFade: Float
            if t < 0.40 {
                centerFade = 1.0 - (t / 0.40)
            } else {
                centerFade = 0.0
            }

            // Edge strips shrink: 10% - 60% (cross-axis dimension narrows)
            let stripShrink: Float
            if t < 0.10 {
                stripShrink = 1.0
            } else if t < 0.60 {
                let p = (t - 0.10) / 0.50
                stripShrink = 1.0 - self.cubicEaseOut(p)
            } else {
                stripShrink = 0.0
            }

            // Edge strips fade: 50% - 100%
            let stripFade: Float
            if t < 0.50 {
                stripFade = 1.0
            } else {
                stripFade = 1.0 - ((t - 0.50) / 0.50)
            }

            // Edge wireframes brighten: 15% - 100% (start earlier for smoother blend)
            let edgeBrightness: Float
            if t < 0.15 {
                edgeBrightness = 0.0
            } else {
                edgeBrightness = self.cubicEaseOut((t - 0.15) / 0.85)
            }

            // Corner markers appear: 50% - 100%
            let markerAppear: Float
            if t < 0.50 {
                markerAppear = 0.0
            } else {
                markerAppear = self.cubicEaseOut((t - 0.50) / 0.50)
            }

            // Apply center quad alpha
            for i in 0..<min(6, self.faceCenterPanels.count) {
                let alpha = centerFade * (self.facePanelAlpha + self.faceCenterAlpha)
                self.setFacePanelEntityAlpha(self.faceCenterPanels[i], alpha: alpha)
            }

            // Apply edge strip shrink + fade
            for (faceIdx, strips) in self.faceEdgeStrips.enumerated() {
                guard faceIdx < initialStripScales.count else { continue }
                for (stripIdx, strip) in strips.enumerated() {
                    guard stripIdx < initialStripScales[faceIdx].count else { continue }
                    let initial = initialStripScales[faceIdx][stripIdx]
                    // For generateBox: local X = width, local Y = height, local Z = thin depth
                    // strips [0,1] = top/bottom (full width, 20% height) → shrink Y (the narrow dimension)
                    // strips [2,3] = left/right (20% width, 60% height) → shrink X (the narrow dimension)
                    let shrunkScale = SIMD3<Float>(
                        initial.x * (stripIdx < 2 ? 1.0 : stripShrink),
                        initial.y * (stripIdx < 2 ? stripShrink : 1.0),
                        initial.z
                    )
                    strip.scale = shrunkScale

                    let stripAlpha = stripFade * self.facePanelAlpha
                    self.setFacePanelEntityAlpha(strip, alpha: stripAlpha)
                }
            }

            // Apply edge wireframe brightness
            self.setAllEdgeAlpha(edgeBrightness)

            // Apply corner marker appearance
            for marker in self.bottomCornerMarkers + self.topCornerMarkers {
                marker.isEnabled = markerAppear > 0.01
                marker.scale = SIMD3<Float>(repeating: markerAppear)
                self.setCornerMarkerAlpha(marker, alpha: markerAppear)
            }

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Remove all face panels
                for panel in self.faceCenterPanels {
                    panel.removeFromParent()
                }
                for strips in self.faceEdgeStrips {
                    for strip in strips {
                        strip.removeFromParent()
                    }
                }
                self.faceCenterPanels.removeAll()
                self.faceEdgeStrips.removeAll()

                // Ensure edges and markers at full visibility
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

    // MARK: - Private Methods - Object Screen Bounds

    /// Project all 8 bounding box corners to screen space and compute the object's horizontal screen extent.
    private func computeObjectScreenBounds(frame: ARFrame, screenSize: CGSize) {
        let corners = boundingBox.corners
        let camera = frame.camera
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projectionMatrix = camera.projectionMatrix(for: .portrait, viewportSize: screenSize, zNear: 0.01, zFar: 100)

        var screenXValues: [CGFloat] = []
        for corner in corners {
            let worldPos4 = SIMD4<Float>(corner.x, corner.y, corner.z, 1.0)
            let cameraPos = viewMatrix * worldPos4
            let clipPos = projectionMatrix * cameraPos
            if clipPos.w > 0 {
                let ndcX = clipPos.x / clipPos.w
                let screenX = (CGFloat(ndcX) + 1) / 2 * screenSize.width
                screenXValues.append(screenX)
            }
        }

        // Add margin so reveal starts slightly before the object and ends slightly after
        let margin: CGFloat = 20.0
        objectScreenMinX = (screenXValues.min() ?? 0) - margin
        objectScreenMaxX = (screenXValues.max() ?? screenSize.width) + margin
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
        faceCenterPanels.removeAll()
        faceEdgeStrips.removeAll()

        createEdges()
        createCornerMarkers()
        createFacePanels()
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

    private func createFacePanels() {
        let corners = boundingBox.corners
        let boxCenter = boundingBox.center

        for (faceIdx, faceIndices) in Self.faceCornerIndices.enumerated() {
            // Get 4 face corners in world space
            let c0 = corners[faceIndices[0]]
            let c1 = corners[faceIndices[1]]
            let c2 = corners[faceIndices[2]]
            let c3 = corners[faceIndices[3]]

            // Face center
            let faceCenter = (c0 + c1 + c2 + c3) / 4.0

            // Face edge vectors
            let edgeU = c1 - c0  // "width" edge direction
            let edgeV = c3 - c0  // "height" edge direction
            let faceWidth = simd_length(edgeU)
            let faceHeight = simd_length(edgeV)

            guard faceWidth > 0.001 && faceHeight > 0.001 else { continue }

            let uDir = simd_normalize(edgeU)
            let vDir = simd_normalize(edgeV)

            // Compute full 3-axis orientation using edge directions
            // generateBox local: X=width, Y=height, Z=depth(thin)
            // We map: local X → uDir, local Y → vDir, local Z → outward normal
            let orientation = computeFaceOrientation(uDir: uDir, vDir: vDir, faceCenter: faceCenter, boxCenter: boxCenter)

            // Center quad: 60% × 60% of face
            let centerW = faceWidth * 0.6
            let centerH = faceHeight * 0.6
            let centerPanel = createFacePanel(width: centerW, height: centerH, position: faceCenter, orientation: orientation, name: "face_center_\(faceIdx)")
            entity.addChild(centerPanel)
            faceCenterPanels.append(centerPanel)

            // 4 edge strips to tile the remaining border:
            // [0] Top strip:    full width × 20% height, at top of face
            // [1] Bottom strip: full width × 20% height, at bottom of face
            // [2] Left strip:   20% width × 60% height, at left of face
            // [3] Right strip:  20% width × 60% height, at right of face
            var strips: [ModelEntity] = []

            let borderFrac: Float = 0.20
            let centerFrac: Float = 0.60

            // Top strip
            let topStripW = faceWidth
            let topStripH = faceHeight * borderFrac
            let topStripPos = faceCenter + vDir * (faceHeight * (centerFrac / 2.0 + borderFrac / 2.0))
            let topStrip = createFacePanel(width: topStripW, height: topStripH, position: topStripPos, orientation: orientation, name: "face_strip_\(faceIdx)_top")
            entity.addChild(topStrip)
            strips.append(topStrip)

            // Bottom strip
            let bottomStripPos = faceCenter - vDir * (faceHeight * (centerFrac / 2.0 + borderFrac / 2.0))
            let bottomStrip = createFacePanel(width: topStripW, height: topStripH, position: bottomStripPos, orientation: orientation, name: "face_strip_\(faceIdx)_bottom")
            entity.addChild(bottomStrip)
            strips.append(bottomStrip)

            // Left strip
            let leftStripW = faceWidth * borderFrac
            let leftStripH = faceHeight * centerFrac
            let leftStripPos = faceCenter - uDir * (faceWidth * (centerFrac / 2.0 + borderFrac / 2.0))
            let leftStrip = createFacePanel(width: leftStripW, height: leftStripH, position: leftStripPos, orientation: orientation, name: "face_strip_\(faceIdx)_left")
            entity.addChild(leftStrip)
            strips.append(leftStrip)

            // Right strip
            let rightStripPos = faceCenter + uDir * (faceWidth * (centerFrac / 2.0 + borderFrac / 2.0))
            let rightStrip = createFacePanel(width: leftStripW, height: leftStripH, position: rightStripPos, orientation: orientation, name: "face_strip_\(faceIdx)_right")
            entity.addChild(rightStrip)
            strips.append(rightStrip)

            faceEdgeStrips.append(strips)
        }
    }

    /// Create a double-sided face panel using a thin box
    private func createFacePanel(width: Float, height: Float, position: SIMD3<Float>, orientation: simd_quatf, name: String) -> ModelEntity {
        // Use thin box instead of plane for double-sided rendering (no backface culling issues)
        let mesh = MeshResource.generateBox(size: [width, height, facePanelDepth])
        var material = UnlitMaterial(color: facePanelColor.withAlphaComponent(0))
        material.blending = .transparent(opacity: .init(floatLiteral: 0))
        let panelEntity = ModelEntity(mesh: mesh, materials: [material])
        panelEntity.name = name
        panelEntity.position = position
        panelEntity.orientation = orientation
        return panelEntity
    }

    /// Compute full 3-axis orientation for a face panel.
    /// Maps generateBox local axes: X→uDir (width), Y→vDir (height), Z→outward normal
    private func computeFaceOrientation(uDir: SIMD3<Float>, vDir: SIMD3<Float>, faceCenter: SIMD3<Float>, boxCenter: SIMD3<Float>) -> simd_quatf {
        let xAxis = uDir
        var zAxis = simd_normalize(simd_cross(uDir, vDir))

        // Ensure normal points outward (away from box center)
        let toFace = faceCenter - boxCenter
        if simd_dot(zAxis, toFace) < 0 {
            zAxis = -zAxis
        }

        // Recompute yAxis to ensure orthogonal right-handed system
        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))

        let rotMatrix = simd_float3x3(columns: (xAxis, yAxis, zAxis))
        return simd_quatf(rotMatrix)
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

    private func setFacePanelAlpha(faceIndex: Int, alpha: Float, centerAlpha: Float) {
        guard faceIndex < faceCenterPanels.count, faceIndex < faceEdgeStrips.count else { return }

        // Center panel (brighter)
        setFacePanelEntityAlpha(faceCenterPanels[faceIndex], alpha: centerAlpha)

        // Edge strips
        for strip in faceEdgeStrips[faceIndex] {
            setFacePanelEntityAlpha(strip, alpha: alpha)
        }
    }

    /// Set alpha on a face panel entity (uses facePanelColor)
    private func setFacePanelEntityAlpha(_ panelEntity: ModelEntity, alpha: Float) {
        let clampedAlpha = max(0, min(1, alpha))
        var material = UnlitMaterial(color: facePanelColor.withAlphaComponent(CGFloat(clampedAlpha)))
        material.blending = .transparent(opacity: .init(floatLiteral: clampedAlpha))
        panelEntity.model?.materials = [material]
    }

    /// Set alpha on a corner marker entity (uses cornerMarkerColor)
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

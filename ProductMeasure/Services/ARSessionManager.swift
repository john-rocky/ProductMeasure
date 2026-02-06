//
//  ARSessionManager.swift
//  ProductMeasure
//

import ARKit
import RealityKit
import Combine

/// Manages the AR session lifecycle and frame handling
@MainActor
class ARSessionManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var trackingState: ARCamera.TrackingState = .notAvailable
    @Published var trackingStateMessage: String = "Initializing..."
    @Published var isDepthAvailable: Bool = false
    @Published var currentFrame: ARFrame?

    // MARK: - AR Components

    private(set) var arView: ARView!
    private var session: ARSession { arView.session }

    // MARK: - Callbacks

    var onFrameUpdate: ((ARFrame) -> Void)?

    // MARK: - Initialization

    override init() {
        super.init()
        setupARView()
    }

    private func setupARView() {
        arView = ARView(frame: .zero)
        arView.session.delegate = self

        // Configure AR view
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField]
    }

    // MARK: - Session Control

    func startSession() {
        guard LiDARChecker.isARKitSupported else {
            trackingStateMessage = "ARKit is not supported on this device"
            return
        }

        let config = ARWorldTrackingConfiguration()

        // Enable depth if available
        if LiDARChecker.isSmoothedDepthAvailable {
            config.frameSemantics.insert(.smoothedSceneDepth)
            isDepthAvailable = true
        } else if LiDARChecker.isLiDARAvailable {
            config.frameSemantics.insert(.sceneDepth)
            isDepthAvailable = true
        }

        // Enable plane detection for better tracking
        config.planeDetection = [.horizontal, .vertical]

        // Enable auto-focus for better camera quality
        config.isAutoFocusEnabled = true

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseSession() {
        session.pause()
    }

    func resetSession() {
        let config = session.configuration as? ARWorldTrackingConfiguration
        if let config = config {
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    // MARK: - Depth Accumulation

    // nonisolated(unsafe) because DepthAccumulator is internally thread-safe (NSLock)
    // and needs to be accessed from the nonisolated ARSessionDelegate callback
    nonisolated(unsafe) let depthAccumulator = DepthAccumulator()

    // MARK: - Raycast

    func raycast(from point: CGPoint) -> ARRaycastResult? {
        let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
        return results.first
    }

    func raycastWorldPosition(from point: CGPoint) -> SIMD3<Float>? {
        raycast(from: point)?.worldTransform.columns.3.xyz
    }

    // MARK: - Plane Detection

    /// Get the Y coordinate of the largest detected horizontal floor plane
    /// Returns nil if no horizontal planes are detected
    func getFloorPlaneY() -> Float? {
        guard let anchors = session.currentFrame?.anchors else { return nil }

        var bestPlaneY: Float? = nil
        var bestArea: Float = 0

        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor,
                  plane.alignment == .horizontal else { continue }

            let area = plane.planeExtent.width * plane.planeExtent.height
            if area > bestArea {
                bestArea = area
                // The plane's Y in world coordinates
                bestPlaneY = anchor.transform.columns.3.y
            }
        }

        return bestPlaneY
    }

    /// Get the Y coordinate of the nearest horizontal plane below the given Y coordinate.
    /// Used to find the support surface (table/floor) beneath an object's point cloud.
    func getSupportPlaneY(belowY: Float) -> Float? {
        guard let anchors = session.currentFrame?.anchors else { return nil }

        var bestPlaneY: Float? = nil
        var bestDistance: Float = .greatestFiniteMagnitude

        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor,
                  plane.alignment == .horizontal else { continue }

            let planeY = anchor.transform.columns.3.y
            let distance = belowY - planeY
            // Only consider planes below (or at) the point cloud bottom
            guard distance >= 0 else { continue }

            if distance < bestDistance {
                bestDistance = distance
                bestPlaneY = planeY
            }
        }

        return bestPlaneY
    }

    /// Get nearby vertical plane anchors for direction snapping
    func getNearbyVerticalPlanes(near position: SIMD3<Float>, maxDistance: Float = 2.0) -> [ARPlaneAnchor] {
        guard let anchors = session.currentFrame?.anchors else { return [] }

        return anchors.compactMap { anchor -> ARPlaneAnchor? in
            guard let plane = anchor as? ARPlaneAnchor,
                  plane.alignment == .vertical else { return nil }

            let planePos = SIMD3<Float>(anchor.transform.columns.3.x,
                                         anchor.transform.columns.3.y,
                                         anchor.transform.columns.3.z)
            let distance = simd_distance(planePos, position)
            return distance <= maxDistance ? plane : nil
        }
    }

    // MARK: - Entity Management

    func addEntity(_ entity: Entity) {
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
    }

    /// Add an entity with a returned anchor for later selective removal
    @discardableResult
    func addEntityWithAnchor(_ entity: Entity) -> AnchorEntity {
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        return anchor
    }

    /// Remove a specific anchor from the scene
    func removeAnchor(_ anchor: AnchorEntity) {
        anchor.removeFromParent()
    }

    func removeAllEntities() {
        arView.scene.anchors.removeAll()
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Feed frame to depth accumulator (nonisolated-safe since accumulator handles its own thread safety)
        self.depthAccumulator.addFrame(frame)

        Task { @MainActor in
            self.currentFrame = frame
            self.updateTrackingState(frame.camera.trackingState)
            self.onFrameUpdate?(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.trackingStateMessage = "Session failed: \(error.localizedDescription)"
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.trackingStateMessage = "Session interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.resetSession()
        }
    }
}

// MARK: - Private Helpers

private extension ARSessionManager {
    func updateTrackingState(_ state: ARCamera.TrackingState) {
        trackingState = state

        switch state {
        case .notAvailable:
            trackingStateMessage = "Tracking not available"
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingStateMessage = "Initializing AR..."
            case .excessiveMotion:
                trackingStateMessage = "Move device slower"
            case .insufficientFeatures:
                trackingStateMessage = "Point at more textured surfaces"
            case .relocalizing:
                trackingStateMessage = "Relocalizing..."
            @unknown default:
                trackingStateMessage = "Limited tracking"
            }
        case .normal:
            trackingStateMessage = "Ready to measure"
        }
    }
}

// MARK: - SIMD Helpers

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}

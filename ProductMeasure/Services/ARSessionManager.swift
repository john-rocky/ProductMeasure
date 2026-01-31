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

    // MARK: - Raycast

    func raycast(from point: CGPoint) -> ARRaycastResult? {
        let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
        return results.first
    }

    func raycastWorldPosition(from point: CGPoint) -> SIMD3<Float>? {
        raycast(from: point)?.worldTransform.columns.3.xyz
    }

    // MARK: - Entity Management

    func addEntity(_ entity: Entity) {
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
    }

    func removeAllEntities() {
        arView.scene.anchors.removeAll()
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
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

//
//  ARMeasurementView.swift
//  ProductMeasure
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

struct ARMeasurementView: View {
    @StateObject private var viewModel = ARMeasurementViewModel()
    @AppStorage("measurementMode") private var measurementMode: MeasurementMode = .boxPriority
    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @AppStorage("selectionMode2") private var selectionMode: SelectionMode = .tap
    @State private var boxSelectionRect: CGRect? = nil
    @State private var boxSelectionComplete: Bool = false

    var body: some View {
        ZStack {
            // AR Camera View
            if LiDARChecker.isLiDARAvailable {
                ARMeasurementViewRepresentable(
                    viewModel: viewModel,
                    measurementMode: measurementMode,
                    selectionMode: selectionMode
                )
                    .ignoresSafeArea()

                // Corner brackets overlay - visible only in tap mode
                if selectionMode == .tap {
                    GeometryReader { geometry in
                        CornerBracketsView(
                            phase: viewModel.animationPhase,
                            screenSize: geometry.size
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                // Box selection overlay - visible in box mode (below UI controls)
                if selectionMode == .box && viewModel.currentMeasurement == nil && !viewModel.isProcessing {
                    BoxSelectionOverlay(
                        selectionRect: $boxSelectionRect,
                        isComplete: $boxSelectionComplete
                    )
                    .ignoresSafeArea()
                }

                // Overlay UI (on top)
                VStack {
                    // Top bar with status and selection mode toggle
                    HStack {
                        StatusBar(
                            trackingMessage: viewModel.trackingMessage,
                            isProcessing: viewModel.isProcessing
                        )

                        Spacer()

                        // Selection mode toggle (visible when not measuring)
                        if viewModel.currentMeasurement == nil && !viewModel.isProcessing {
                            SelectionModeToggle(selectionMode: $selectionMode)
                        }

                    }

                    Spacer()

                    // Editing mode indicator
                    if viewModel.isEditing {
                        EditingIndicator(isDragging: viewModel.isDragging)
                            .transition(.opacity)
                    }

                    // Measurement result card
                    if let result = viewModel.currentMeasurement {
                        MeasurementResultCard(
                            result: result,
                            unit: measurementUnit,
                            isEditing: viewModel.isEditing,
                            showVoxelVisualization: viewModel.showVoxelVisualization,
                            onSave: {
                                viewModel.stopEditing()
                                viewModel.saveMeasurement(mode: measurementMode)
                            },
                            onEdit: {
                                viewModel.startEditing()
                            },
                            onFit: {
                                viewModel.fitToPointCloud(mode: measurementMode)
                            },
                            onDone: {
                                viewModel.stopEditing()
                            },
                            onDiscard: {
                                viewModel.discardMeasurement()
                            },
                            onToggleVoxel: {
                                viewModel.toggleVoxelVisualization()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Instruction text when in targeting mode
                    if viewModel.currentMeasurement == nil && !viewModel.isProcessing {
                        if selectionMode == .tap && viewModel.animationPhase == .showingTargetBrackets {
                            InstructionCard(mode: .tap)
                        } else if selectionMode == .box {
                            InstructionCard(mode: .box)
                        }
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentMeasurement != nil)
                .onChange(of: boxSelectionComplete) { _, isComplete in
                    if isComplete, let rect = boxSelectionRect {
                        Task {
                            await viewModel.handleBoxSelection(
                                rect: rect,
                                viewSize: viewModel.sessionManager.arView.bounds.size,
                                mode: measurementMode
                            )
                        }
                        // Reset box selection state
                        boxSelectionRect = nil
                        boxSelectionComplete = false
                    }
                }
                .sheet(isPresented: $viewModel.showDebugMask) {
                    if let image = viewModel.debugMaskImage {
                        DebugImageView(image: image, title: "Segmentation Mask (Green) + Tap Point (Red)")
                    }
                }
                .sheet(isPresented: $viewModel.showDebugDepth) {
                    if let image = viewModel.debugDepthImage {
                        DebugImageView(image: image, title: "Depth Map (Bright=Close) + Masked Pixels (Green)")
                    }
                }
            } else {
                // LiDAR not available view
                LiDARNotAvailableView()
            }
        }
        .onAppear {
            viewModel.startSession()
        }
        .onDisappear {
            viewModel.pauseSession()
        }
    }
}

// MARK: - AR View Representable with Tap and Pan Handling

struct ARMeasurementViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: ARMeasurementViewModel
    let measurementMode: MeasurementMode
    let selectionMode: SelectionMode

    func makeUIView(context: Context) -> ARView {
        let arView = viewModel.sessionManager.arView!

        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        context.coordinator.tapGesture = tapGesture

        // Add pan gesture recognizer for handle dragging
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        context.coordinator.panGesture = panGesture

        // Store reference to arView in coordinator
        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.measurementMode = measurementMode
        context.coordinator.selectionMode = selectionMode

        // Disable gestures in box mode (unless editing)
        let isBoxMode = selectionMode == .box
        let isEditing = viewModel.isEditing
        let hasMeasurement = viewModel.currentMeasurement != nil

        // In box mode without measurement, disable tap/pan to allow BoxSelectionOverlay to work
        // But if editing, keep pan enabled for handle dragging
        context.coordinator.tapGesture?.isEnabled = !isBoxMode || hasMeasurement
        context.coordinator.panGesture?.isEnabled = !isBoxMode || hasMeasurement || isEditing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, measurementMode: measurementMode, selectionMode: selectionMode)
    }

    class Coordinator: NSObject {
        let viewModel: ARMeasurementViewModel
        var measurementMode: MeasurementMode
        var selectionMode: SelectionMode
        weak var arView: ARView?

        // Gesture references for enabling/disabling
        weak var tapGesture: UITapGestureRecognizer?
        weak var panGesture: UIPanGestureRecognizer?

        // Drag state
        private var activeDragType: DragType?
        private var lastPanLocation: CGPoint?

        enum DragType {
            case faceHandle(HandleType)
            case rotationRing
        }

        init(viewModel: ARMeasurementViewModel, measurementMode: MeasurementMode, selectionMode: SelectionMode) {
            self.viewModel = viewModel
            self.measurementMode = measurementMode
            self.selectionMode = selectionMode
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }

            // If editing, ignore taps
            if viewModel.isEditing { return }

            // Only handle taps in tap mode
            guard selectionMode == .tap else { return }

            let location = gesture.location(in: gesture.view)
            print("[Tap] Location: \(location)")

            Task {
                await viewModel.handleTap(at: location, mode: measurementMode)
            }
        }

        @MainActor @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard viewModel.isEditing, let arView = arView else { return }

            let location = gesture.location(in: arView)

            switch gesture.state {
            case .began:
                // Hit test to find handle or ring
                if let dragType = hitTest(at: location, in: arView) {
                    activeDragType = dragType
                    lastPanLocation = location
                    print("[Pan] Started dragging: \(dragType)")
                }

            case .changed:
                guard let dragType = activeDragType,
                      let lastLocation = lastPanLocation else { return }

                let delta = CGPoint(
                    x: location.x - lastLocation.x,
                    y: location.y - lastLocation.y
                )

                switch dragType {
                case .faceHandle(let handleType):
                    viewModel.handleFaceDrag(handleType: handleType, screenDelta: delta, mode: measurementMode)
                case .rotationRing:
                    viewModel.handleRotationDrag(screenDelta: delta, touchLocation: location)
                }

                lastPanLocation = location

            case .ended, .cancelled:
                if activeDragType != nil {
                    print("[Pan] Ended dragging")
                    viewModel.finishDrag()
                }
                activeDragType = nil
                lastPanLocation = nil

            default:
                break
            }
        }

        private func hitTest(at location: CGPoint, in arView: ARView) -> DragType? {
            let results = arView.hitTest(location, query: .nearest, mask: .all)

            for result in results {
                var entity: Entity? = result.entity
                while let current = entity {
                    let hitType = BoxVisualization.parseHit(entityName: current.name)
                    switch hitType {
                    case .faceHandle(let handleType):
                        return .faceHandle(handleType)
                    case .rotationRing:
                        return .rotationRing
                    case .none:
                        break
                    }
                    entity = current.parent
                }
            }

            return nil
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    let trackingMessage: String
    let isProcessing: Bool

    var body: some View {
        HStack {
            if isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
                Text("Processing...")
                    .foregroundColor(.white)
            } else {
                Image(systemName: trackingStatusIcon)
                    .foregroundColor(trackingStatusColor)
                Text(trackingMessage)
                    .foregroundColor(.white)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private var trackingStatusIcon: String {
        if trackingMessage == "Ready to measure" {
            return "checkmark.circle.fill"
        } else if trackingMessage.contains("not") || trackingMessage.contains("Not") {
            return "exclamationmark.triangle.fill"
        } else {
            return "arrow.triangle.2.circlepath"
        }
    }

    private var trackingStatusColor: Color {
        if trackingMessage == "Ready to measure" {
            return .green
        } else if trackingMessage.contains("not") || trackingMessage.contains("Not") {
            return .red
        } else {
            return .yellow
        }
    }
}

// MARK: - Instruction Card

struct InstructionCard: View {
    var mode: SelectionMode = .tap

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: mode == .tap ? "hand.tap.fill" : "rectangle.dashed")
                .font(.title)
            Text(mode == .tap ? "Tap on an object to measure" : "Draw a box to select")
                .font(.headline)
            Text(mode == .tap
                 ? "Point your device at an object and tap to measure its dimensions"
                 : "Drag to draw a rectangle around the object you want to measure")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Measurement Result Card

struct MeasurementResultCard: View {
    let result: MeasurementCalculator.MeasurementResult
    let unit: MeasurementUnit
    var isEditing: Bool = false
    var showVoxelVisualization: Bool = true
    let onSave: () -> Void
    let onEdit: () -> Void
    var onFit: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    let onDiscard: () -> Void
    var onToggleVoxel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Quality indicator or editing badge
            HStack {
                if isEditing {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.orange)
                        Text("Editing Mode")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } else {
                    QualityIndicator(quality: result.quality.overallQuality)
                }
                Spacer()
            }

            // Dimensions
            VStack(spacing: 8) {
                HStack {
                    DimensionLabel(label: "L", value: formatDimension(result.length))
                    DimensionLabel(label: "W", value: formatDimension(result.width))
                    DimensionLabel(label: "H", value: formatDimension(result.height))
                }

                // Volume display with refined volume
                VStack(spacing: 4) {
                    HStack {
                        Text("Box Volume:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(formatVolume(result.volume))
                            .font(.headline)
                    }

                    // Refined volume (if available or calculating)
                    if result.isCalculatingRefinedVolume {
                        HStack {
                            Text("Refined:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.6)
                            Text("Calculating...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if let refinedVolume = result.refinedVolume {
                        HStack {
                            Text("Refined:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatVolume(refinedVolume.volume))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)

                            if let diff = result.volumeDifferencePercent, abs(diff) > 1 {
                                Text(String(format: "(%.0f%% more precise)", abs(diff)))
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            // Voxel visualization toggle
                            Button(action: { onToggleVoxel?() }) {
                                Image(systemName: showVoxelVisualization ? "cube.fill" : "cube")
                                    .foregroundColor(showVoxelVisualization ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Toggle voxel visualization")
                        }
                    }
                }
            }

            // Action buttons - different based on editing mode
            if isEditing {
                // Editing mode buttons
                HStack(spacing: 12) {
                    Button(action: onDiscard) {
                        Label("Cancel", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: { onFit?() }) {
                        Label("Fit", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)

                    Button(action: { onDone?() }) {
                        Label("Done", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Normal mode buttons
                HStack(spacing: 12) {
                    Button(action: onDiscard) {
                        Label("Discard", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onSave) {
                        Label("Save", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    private func formatDimension(_ meters: Float) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f %@", value, unit.rawValue)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, unit.rawValue)
        } else {
            return String(format: "%.2f %@", value, unit.rawValue)
        }
    }

    private func formatVolume(_ cubicMeters: Float) -> String {
        let value = unit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            return String(format: "%.0f %@", value, unit.volumeUnit())
        } else if value >= 100 {
            return String(format: "%.1f %@", value, unit.volumeUnit())
        } else {
            return String(format: "%.2f %@", value, unit.volumeUnit())
        }
    }
}

// MARK: - Dimension Label

struct DimensionLabel: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Quality Indicator

struct QualityIndicator: View {
    let quality: QualityLevel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(qualityColor)
                .frame(width: 8, height: 8)
            Text(quality.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var qualityColor: Color {
        switch quality {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .red
        }
    }
}

// MARK: - Editing Indicator

struct EditingIndicator: View {
    var isDragging: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isDragging ? "hand.draw.fill" : "hand.point.up.left.fill")
                .font(.title2)
                .foregroundColor(.white)

            Text(isDragging ? "Dragging..." : "Drag handles to resize")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.9))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }
}

// MARK: - LiDAR Not Available View

struct LiDARNotAvailableView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("LiDAR Not Available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This app requires a device with a LiDAR sensor for accurate 3D measurements. Please use an iPhone Pro or iPad Pro with LiDAR.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - View Model

@MainActor
class ARMeasurementViewModel: ObservableObject {
    @Published var trackingMessage = "Initializing..."
    @Published var isProcessing = false
    @Published var currentMeasurement: MeasurementCalculator.MeasurementResult?
    @Published var isEditing = false
    @Published var isDragging = false

    // Debug visualization
    @Published var showDebugMask = false
    @Published var showDebugDepth = false
    @Published var debugMaskImage: UIImage?
    @Published var debugDepthImage: UIImage?

    // Animation state - start with target brackets visible
    @Published var animationPhase: BoundingBoxAnimationPhase = .showingTargetBrackets
    @Published var animationContext: BoundingBoxAnimationContext?
    let animationCoordinator = BoxAnimationCoordinator()

    let sessionManager = ARSessionManager()
    private let measurementCalculator = MeasurementCalculator()
    private let boxEditingService = BoxEditingService()
    private var boxVisualization: BoxVisualization?
    private var voxelVisualization: VoxelVisualization?
    private var pointCloudEntity: Entity?
    private var animatedBoxVisualization: AnimatedBoxVisualization?

    // Stored point cloud for Fit functionality
    private var storedPointCloud: [SIMD3<Float>]?

    /// Whether to show voxel visualization
    @Published var showVoxelVisualization: Bool = true

    init() {
        sessionManager.$trackingStateMessage
            .assign(to: &$trackingMessage)
    }

    func startSession() {
        sessionManager.startSession()
        // Configure animation coordinator with AR view
        if let arView = sessionManager.arView {
            animationCoordinator.configure(arView: arView)
        }
    }

    func pauseSession() {
        sessionManager.pauseSession()
    }

    func handleTap(at location: CGPoint, mode: MeasurementMode) async {
        print("[ViewModel] handleTap called at \(location)")
        print("[ViewModel] isProcessing: \(isProcessing), trackingState: \(sessionManager.trackingState)")

        guard !isProcessing else {
            print("[ViewModel] Already processing, ignoring tap")
            return
        }

        guard let frame = sessionManager.currentFrame else {
            print("[ViewModel] No current frame available")
            return
        }

        // Allow tapping even with limited tracking for testing
        guard sessionManager.trackingState == .normal ||
              (sessionManager.trackingState != .notAvailable) else {
            print("[ViewModel] Tracking state not ready: \(sessionManager.trackingState)")
            return
        }

        // Clean up previous measurement to free memory
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationContext = nil
        // Keep showing target brackets during processing

        isProcessing = true
        print("[ViewModel] Starting measurement...")

        // Get 3D world position from raycast - this is reliable for filtering
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)
        if let pos = raycastHitPosition {
            print("[ViewModel] Raycast hit position: \(pos)")
        } else {
            print("[ViewModel] Raycast did not hit any surface")
        }

        do {
            let viewSize = sessionManager.arView.bounds.size
            print("[ViewModel] View size: \(viewSize)")

            if let result = try await measurementCalculator.measure(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize,
                mode: mode,
                raycastHitPosition: raycastHitPosition
            ) {
                print("[ViewModel] Measurement successful!")
                print("[ViewModel] Dimensions: L=\(result.length*100)cm, W=\(result.width*100)cm, H=\(result.height*100)cm")

                // Store debug images (only if available)
                debugMaskImage = result.debugMaskImage
                debugDepthImage = result.debugDepthImage

                // Store the floor Y for later use
                let floorY = raycastHitPosition?.y

                // Start the animation sequence
                startBoxAnimation(
                    at: location,
                    boundingBox: result.boundingBox,
                    frame: frame,
                    viewSize: viewSize,
                    result: result,
                    floorY: floorY
                )
            } else {
                print("[ViewModel] Measurement returned nil")
                isProcessing = false
            }
        } catch {
            print("[ViewModel] Measurement failed with error: \(error)")
            isProcessing = false
        }
    }

    func handleBoxSelection(rect: CGRect, viewSize: CGSize, mode: MeasurementMode) async {
        print("[ViewModel] handleBoxSelection called with rect: \(rect)")
        print("[ViewModel] isProcessing: \(isProcessing), trackingState: \(sessionManager.trackingState)")

        guard !isProcessing else {
            print("[ViewModel] Already processing, ignoring box selection")
            return
        }

        guard let frame = sessionManager.currentFrame else {
            print("[ViewModel] No current frame available")
            return
        }

        guard sessionManager.trackingState == .normal ||
              (sessionManager.trackingState != .notAvailable) else {
            print("[ViewModel] Tracking state not ready: \(sessionManager.trackingState)")
            return
        }

        // Clean up previous measurement
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationContext = nil

        isProcessing = true
        print("[ViewModel] Starting box selection measurement...")

        // Raycast from box center
        let boxCenter = CGPoint(x: rect.midX, y: rect.midY)
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: boxCenter)
        if let pos = raycastHitPosition {
            print("[ViewModel] Raycast hit position from box center: \(pos)")
        } else {
            print("[ViewModel] Raycast did not hit any surface from box center")
        }

        do {
            if let result = try await measurementCalculator.measureWithROI(
                frame: frame,
                regionOfInterest: rect,
                viewSize: viewSize,
                mode: mode,
                raycastHitPosition: raycastHitPosition
            ) {
                print("[ViewModel] Box selection measurement successful!")
                print("[ViewModel] Dimensions: L=\(result.length*100)cm, W=\(result.width*100)cm, H=\(result.height*100)cm")

                debugMaskImage = result.debugMaskImage
                debugDepthImage = result.debugDepthImage

                let floorY = raycastHitPosition?.y

                startBoxAnimation(
                    at: boxCenter,
                    boundingBox: result.boundingBox,
                    frame: frame,
                    viewSize: viewSize,
                    result: result,
                    floorY: floorY
                )
            } else {
                print("[ViewModel] Box selection measurement returned nil")
                isProcessing = false
            }
        } catch {
            print("[ViewModel] Box selection measurement failed with error: \(error)")
            isProcessing = false
        }
    }

    /// Start the bounding box appearance animation
    private func startBoxAnimation(
        at tapPoint: CGPoint,
        boundingBox: BoundingBox3D,
        frame: ARFrame,
        viewSize: CGSize,
        result: MeasurementCalculator.MeasurementResult,
        floorY: Float?
    ) {
        // Get camera transform for starting position
        let cameraTransform = frame.camera.transform

        // Phase 1: Hide 2D brackets and create 3D rect at camera position
        animationPhase = .flyingToBottom

        // Create animated box visualization
        animatedBoxVisualization = AnimatedBoxVisualization(boundingBox: boundingBox)
        guard let animatedBox = animatedBoxVisualization else {
            isProcessing = false
            return
        }

        // Setup the 3D rect at camera position (facing camera, matching bracket size)
        animatedBox.setupAtCameraPosition(
            cameraTransform: cameraTransform,
            distanceFromCamera: 0.5,
            rectSize: 0.25
        )
        sessionManager.addEntity(animatedBox.entity)

        // Animate flying to bottom position
        animatedBox.animateFlyToBottom(duration: BoxAnimationTiming.flyToBottom) { [weak self] in
            guard let self = self else { return }

            // Phase 2: Grow vertical edges
            self.animationPhase = .growingVertical

            animatedBox.animateGrowVertical(duration: BoxAnimationTiming.growVertical) { [weak self] in
                guard let self = self else { return }

                // Phase 3: Complete - swap to regular BoxVisualization for editing
                self.animationPhase = .complete

                // Remove animated visualization
                animatedBox.entity.removeFromParent()
                self.animatedBoxVisualization = nil

                // Show regular editable box visualization
                // Apply bottom extension if within threshold of floor
                var adjustedBox = boundingBox
                if let floorY = floorY {
                    adjustedBox.extendBottomToFloor(floorY: floorY, threshold: 0.05)
                }

                // Recalculate measurement with adjusted box dimensions
                // Use the original axis mapping from the initial measurement
                var adjustedResult = self.measurementCalculator.recalculate(
                    boundingBox: adjustedBox,
                    quality: result.quality,
                    axisMapping: result.axisMapping
                )
                adjustedResult.pointCloud = result.pointCloud
                adjustedResult.debugMaskImage = result.debugMaskImage
                adjustedResult.debugDepthImage = result.debugDepthImage

                // Mark as calculating refined volume and set result
                adjustedResult.isCalculatingRefinedVolume = true
                self.currentMeasurement = adjustedResult
                self.showBoxVisualization(for: adjustedBox, pointCloud: result.pointCloud, floorY: floorY)

                self.isProcessing = false

                // Start refined volume calculation in background
                Task {
                    await self.calculateRefinedVolumeInBackground()
                }
            }
        }
    }

    func saveMeasurement(mode: MeasurementMode) {
        guard let result = currentMeasurement else { return }

        // Capture annotated image
        let imageData = captureAnnotatedImage()

        // Create and save measurement
        let measurement = ProductMeasurement(
            boundingBox: result.boundingBox,
            quality: result.quality,
            mode: mode,
            annotatedImageData: imageData
        )

        // Save to SwiftData (will be handled by the view's modelContext)
        NotificationCenter.default.post(
            name: .saveMeasurement,
            object: measurement
        )

        discardMeasurement()
    }

    func startEditing() {
        isEditing = true
        // Enable handle interactivity
        boxVisualization?.isInteractive = true
    }

    func stopEditing() {
        isEditing = false
        isDragging = false
        boxVisualization?.isInteractive = false
    }

    func handleFaceDrag(handleType: HandleType, screenDelta: CGPoint, mode: MeasurementMode) {
        guard let result = currentMeasurement else { return }

        isDragging = true

        // Highlight the touched handle
        boxVisualization?.highlightHandle(handleType)

        // Get face center position in world space (not handle position)
        // This gives us the correct direction for the face normal on screen
        guard let faceCenterLocalPos = handleType.faceCenterPosition(extents: result.boundingBox.extents) else {
            return
        }
        let faceCenterWorldPos = result.boundingBox.localToWorld(faceCenterLocalPos)

        // Project face center and box center to screen coordinates
        guard let faceCenterScreenPos = sessionManager.projectToScreen(worldPosition: faceCenterWorldPos),
              let boxCenterScreenPos = sessionManager.projectToScreen(worldPosition: result.boundingBox.center) else {
            return
        }

        // Apply face drag to bounding box
        let editResult = boxEditingService.applyFaceDrag(
            box: result.boundingBox,
            handleType: handleType,
            screenDelta: screenDelta,
            faceCenterScreenPos: faceCenterScreenPos,
            boxCenterScreenPos: boxCenterScreenPos
        )

        if editResult.didChange {
            // Update measurement result using the original axis mapping
            let newResult = measurementCalculator.recalculate(
                boundingBox: editResult.boundingBox,
                quality: result.quality,
                axisMapping: result.axisMapping
            )
            var updatedResult = newResult
            updatedResult.pointCloud = storedPointCloud
            updatedResult.debugMaskImage = result.debugMaskImage
            updatedResult.debugDepthImage = result.debugDepthImage
            currentMeasurement = updatedResult

            // Update visualization
            boxVisualization?.update(boundingBox: editResult.boundingBox)
        }
    }

    func handleRotationDrag(screenDelta: CGPoint, touchLocation: CGPoint) {
        guard let result = currentMeasurement else { return }

        isDragging = true

        // Highlight the rotation handle
        boxVisualization?.highlightRotationHandle()

        // Project box center to screen
        guard let boxCenterScreenPos = sessionManager.projectToScreen(worldPosition: result.boundingBox.center) else {
            return
        }

        // Calculate vector from box center to touch location
        let toTouch = SIMD2<Float>(
            Float(touchLocation.x - boxCenterScreenPos.x),
            Float(touchLocation.y - boxCenterScreenPos.y)
        )
        let touchDistance = simd_length(toTouch)

        // If touch is too close to center, can't determine rotation
        guard touchDistance > 10 else { return }

        // Calculate tangent direction (perpendicular to radial, clockwise)
        // For screen coordinates (Y down), clockwise tangent is (toTouch.y, -toTouch.x)
        let tangent = SIMD2<Float>(toTouch.y, -toTouch.x) / touchDistance

        // Project screen delta onto tangent direction
        // Positive = clockwise rotation on screen
        let screenDelta2D = SIMD2<Float>(Float(screenDelta.x), Float(screenDelta.y))
        let tangentialDelta = simd_dot(screenDelta2D, tangent)

        // Convert to world Y rotation
        // When looking from above (camera Y+), clockwise screen rotation = negative Y rotation
        // Scale by distance to get consistent angular speed
        let angularScale: Float = 1.0 / touchDistance
        let yawAngle = tangentialDelta * angularScale

        // Apply rotation
        var newBox = result.boundingBox
        newBox.rotateAroundY(by: yawAngle)

        // Update measurement result using the original axis mapping
        let newResult = measurementCalculator.recalculate(
            boundingBox: newBox,
            quality: result.quality,
            axisMapping: result.axisMapping
        )
        var updatedResult = newResult
        updatedResult.pointCloud = storedPointCloud
        updatedResult.debugMaskImage = result.debugMaskImage
        updatedResult.debugDepthImage = result.debugDepthImage
        currentMeasurement = updatedResult

        // Update visualization
        boxVisualization?.update(boundingBox: newBox)
    }

    func finishDrag() {
        isDragging = false
        // Remove handle highlight
        boxVisualization?.unhighlightAllHandles()
    }

    func fitToPointCloud(mode: MeasurementMode) {
        guard let result = currentMeasurement,
              let points = storedPointCloud,
              !points.isEmpty else {
            print("[ViewModel] No point cloud available for fit")
            return
        }

        print("[ViewModel] Fitting to point cloud with \(points.count) points")

        if var fittedBox = boxEditingService.fitToPoints(
            currentBox: result.boundingBox,
            allPoints: points,
            mode: mode
        ) {
            // Apply bottom extension if within threshold of floor
            if let floorY = boxVisualization?.floorY {
                fittedBox.extendBottomToFloor(floorY: floorY, threshold: 0.05)
            }

            // Update measurement result using the original axis mapping
            let newResult = measurementCalculator.recalculate(
                boundingBox: fittedBox,
                quality: result.quality,
                axisMapping: result.axisMapping
            )
            var updatedResult = newResult
            updatedResult.pointCloud = storedPointCloud
            updatedResult.debugMaskImage = result.debugMaskImage
            updatedResult.debugDepthImage = result.debugDepthImage
            currentMeasurement = updatedResult

            // Update visualization
            boxVisualization?.update(boundingBox: fittedBox)

            print("[ViewModel] Fit successful - new dimensions: L=\(fittedBox.length*100)cm, W=\(fittedBox.width*100)cm, H=\(fittedBox.height*100)cm")
        } else {
            print("[ViewModel] Fit failed - not enough points in current box")
        }
    }

    func discardMeasurement() {
        currentMeasurement = nil
        isEditing = false
        isDragging = false
        storedPointCloud = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationPhase = .showingTargetBrackets  // Return to targeting mode
        animationContext = nil
        animationCoordinator.cancelAnimation()
        animatedBoxVisualization?.entity.removeFromParent()
        animatedBoxVisualization = nil
        voxelVisualization?.entity.removeFromParent()
        voxelVisualization = nil
        removeAllVisualizations()
    }

    /// Calculate refined volume in background and update the current measurement
    private func calculateRefinedVolumeInBackground() async {
        guard let result = currentMeasurement else { return }

        print("[ViewModel] Starting refined volume calculation...")

        let updatedResult = await measurementCalculator.calculateRefinedVolume(for: result)

        // Only update if we still have the same measurement
        if currentMeasurement?.boundingBox.center == result.boundingBox.center {
            currentMeasurement = updatedResult

            if let refined = updatedResult.refinedVolume {
                print("[ViewModel] Refined volume calculated: \(refined.formattedVolume)")
                print("[ViewModel] Processing time: \(String(format: "%.0f", refined.processingTime * 1000)) ms")

                // Show voxel visualization
                if showVoxelVisualization {
                    showVoxelVisualizationEntity(with: refined)
                }
            }
        }
    }

    /// Show voxel visualization in AR scene
    private func showVoxelVisualizationEntity(with result: VoxelVolumeResult) {
        // Remove existing voxel visualization
        voxelVisualization?.entity.removeFromParent()

        // Create new visualization
        let visualization = VoxelVisualization()
        visualization.update(with: result)

        sessionManager.addEntity(visualization.entity)
        voxelVisualization = visualization

        // Animate appearance
        visualization.animateAppear(duration: 0.3)
    }

    /// Toggle voxel visualization visibility
    func toggleVoxelVisualization() {
        showVoxelVisualization.toggle()

        if showVoxelVisualization {
            // Show if we have refined volume data
            if let refined = currentMeasurement?.refinedVolume {
                showVoxelVisualizationEntity(with: refined)
            }
        } else {
            // Hide
            voxelVisualization?.entity.removeFromParent()
            voxelVisualization = nil
        }
    }

    func toggleDebugMask() {
        showDebugMask.toggle()
    }

    func toggleDebugDepth() {
        showDebugDepth.toggle()
    }

    private func showBoxVisualization(for box: BoundingBox3D, pointCloud: [SIMD3<Float>]? = nil, floorY: Float? = nil) {
        // Store point cloud for Fit functionality
        storedPointCloud = pointCloud

        boxVisualization = BoxVisualization(boundingBox: box, interactive: false)

        // Set floor height for distance indicator
        if let floorY = floorY {
            boxVisualization?.floorY = floorY
        }

        if let entity = boxVisualization?.entity {
            sessionManager.addEntity(entity)
        }
    }

    private func showPointCloudVisualization(points: [SIMD3<Float>]) {
        pointCloudEntity = DebugVisualization.createPointCloudEntity(
            points: points,
            color: .cyan,
            pointSize: 0.003
        )
        if let entity = pointCloudEntity {
            sessionManager.addEntity(entity)
        }
    }

    private func showCameraAxes(transform: simd_float4x4) {
        let axesEntity = DebugVisualization.createAxesEntity(at: transform, length: 0.05)
        sessionManager.addEntity(axesEntity)
    }

    private func removeAllVisualizations() {
        sessionManager.removeAllEntities()
        boxVisualization = nil
        pointCloudEntity = nil
    }

    private func captureAnnotatedImage() -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: sessionManager.arView.bounds)
        let image = renderer.image { _ in
            sessionManager.arView.drawHierarchy(in: sessionManager.arView.bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let saveMeasurement = Notification.Name("saveMeasurement")
}

#Preview {
    ARMeasurementView()
}

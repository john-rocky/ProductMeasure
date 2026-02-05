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
                GeometryReader { geometry in
                    ZStack {
                        VStack {
                            // Top bar with status, save button, and clear button
                            HStack {
                                StatusBar(
                                    trackingMessage: viewModel.trackingMessage,
                                    isProcessing: viewModel.isProcessing
                                )

                                Spacer()

                                // Save button (visible when measurement exists and not editing)
                                if viewModel.currentMeasurement != nil && !viewModel.isEditing {
                                    Button(action: {
                                        viewModel.stopEditing()
                                        viewModel.saveMeasurement(mode: measurementMode, unit: measurementUnit)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark")
                                            Text("Save")
                                        }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.green)
                                        .clipShape(Capsule())
                                    }
                                }

                                // Clear all button (visible when completed boxes exist)
                                if viewModel.completedBoxCount > 0 {
                                    Button(action: {
                                        viewModel.clearAllMeasurements()
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "trash")
                                            Text("\(viewModel.completedBoxCount)")
                                                .font(.caption)
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.8))
                                        .clipShape(Capsule())
                                    }
                                }

                                // Selection mode toggle (visible when not measuring)
                                if viewModel.currentMeasurement == nil && !viewModel.isProcessing {
                                    SelectionModeToggle(selectionMode: $selectionMode)
                                }

                            }

                            Spacer()

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

                        // Floating buttons near the box
                        if viewModel.currentMeasurement != nil {
                            FloatingBoxButtons(
                                isEditing: viewModel.isEditing,
                                isDragging: viewModel.isDragging,
                                boxCenterScreenPosition: viewModel.boxCenterScreenPosition,
                                screenSize: geometry.size,
                                onDiscard: {
                                    viewModel.discardMeasurement()
                                },
                                onEdit: {
                                    viewModel.startEditing()
                                },
                                onCancel: {
                                    viewModel.discardMeasurement()
                                },
                                onFit: {
                                    viewModel.fitToPointCloud(mode: measurementMode)
                                },
                                onDone: {
                                    viewModel.stopEditing()
                                }
                            )
                        }
                    }
                }
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
            viewModel.currentUnit = measurementUnit
        }
        .onDisappear {
            viewModel.pauseSession()
        }
        .onChange(of: measurementUnit) { _, newUnit in
            viewModel.currentUnit = newUnit
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
    let onSave: () -> Void
    let onEdit: () -> Void
    var onFit: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    let onDiscard: () -> Void

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

                Text("Volume: \(formatVolume(result.volume))")
                    .font(.headline)
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

// MARK: - Floating Box Buttons

struct FloatingBoxButtons: View {
    let isEditing: Bool
    let isDragging: Bool
    let boxCenterScreenPosition: CGPoint?
    let screenSize: CGSize
    let onDiscard: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onFit: () -> Void
    let onDone: () -> Void

    var body: some View {
        let buttonY = calculateButtonY()

        VStack(spacing: 0) {
            Spacer()
                .frame(height: buttonY)

            if isEditing {
                // Editing mode buttons
                HStack(spacing: 12) {
                    // Cancel button
                    Button(action: onCancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("Cancel")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.9))
                        .clipShape(Capsule())
                    }

                    // Fit button
                    Button(action: onFit) {
                        HStack(spacing: 4) {
                            Image(systemName: "crop")
                            Text("Fit")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.9))
                        .clipShape(Capsule())
                    }

                    // Done button
                    Button(action: onDone) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Done")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.9))
                        .clipShape(Capsule())
                    }
                }
                .transition(.opacity.combined(with: .scale))

                // Editing hint
                if !isDragging {
                    Text("Drag handles to resize")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 8)
                }
            } else {
                // Normal mode buttons
                HStack(spacing: 12) {
                    // Discard button
                    Button(action: onDiscard) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("Discard")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.9))
                        .clipShape(Capsule())
                    }

                    // Edit button
                    Button(action: onEdit) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.9))
                        .clipShape(Capsule())
                    }
                }
                .transition(.opacity.combined(with: .scale))
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    private func calculateButtonY() -> CGFloat {
        // Position buttons below the box center
        if let boxCenter = boxCenterScreenPosition {
            // Clamp to reasonable screen range
            let minY: CGFloat = screenSize.height * 0.4
            let maxY: CGFloat = screenSize.height * 0.75
            let targetY = boxCenter.y + 120  // 120pt below box center
            return min(max(targetY, minY), maxY)
        }
        // Default to lower third of screen
        return screenSize.height * 0.65
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

    // Box center screen position for floating buttons
    @Published var boxCenterScreenPosition: CGPoint?

    // Animation state - start with target brackets visible
    @Published var animationPhase: BoundingBoxAnimationPhase = .showingTargetBrackets
    @Published var animationContext: BoundingBoxAnimationContext?
    let animationCoordinator = BoxAnimationCoordinator()

    let sessionManager = ARSessionManager()
    private let measurementCalculator = MeasurementCalculator()
    private let boxEditingService = BoxEditingService()
    private var boxVisualization: BoxVisualization?
    private var boxVisualizationAnchor: AnchorEntity?
    private var pointCloudEntity: Entity?
    private var animatedBoxVisualization: AnimatedBoxVisualization?
    private var animatedBoxAnchor: AnchorEntity?

    // Stored point cloud for Fit functionality
    private var storedPointCloud: [SIMD3<Float>]?

    // Current measurement unit (passed from view)
    var currentUnit: MeasurementUnit = .centimeters

    // Completed (saved) box visualizations
    private var completedBoxVisualizations: [CompletedBoxVisualization] = []
    private var completedBoxAnchors: [AnchorEntity] = []
    private let maxCompletedBoxes = 10

    // Published count for UI
    @Published var completedBoxCount: Int = 0

    init() {
        sessionManager.$trackingStateMessage
            .assign(to: &$trackingMessage)

        // Setup frame update callback for billboard updates
        sessionManager.onFrameUpdate = { [weak self] frame in
            Task { @MainActor in
                self?.onFrameUpdate(frame: frame)
            }
        }
    }

    func startSession() {
        sessionManager.startSession()
        // Configure animation coordinator with AR view
        if let arView = sessionManager.arView {
            animationCoordinator.configure(arView: arView)
        }
    }

    /// Called on each AR frame update
    private func onFrameUpdate(frame: ARFrame) {
        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        // Update billboard orientations for active box
        boxVisualization?.updateLabelOrientations(cameraPosition: cameraPosition)

        // Update billboard orientations for completed boxes
        for visualization in completedBoxVisualizations {
            visualization.updateLabelOrientations(cameraPosition: cameraPosition)
        }

        // Update box center screen position for floating buttons
        if let result = currentMeasurement {
            boxCenterScreenPosition = sessionManager.projectToScreen(worldPosition: result.boundingBox.center)
        } else {
            boxCenterScreenPosition = nil
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

        // Auto-save current measurement as completed box before starting new one
        if let existingResult = currentMeasurement {
            print("[ViewModel] Auto-saving existing measurement before new tap")
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)
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

        // Auto-save current measurement as completed box before starting new one
        if let existingResult = currentMeasurement {
            print("[ViewModel] Auto-saving existing measurement before new box selection")
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)
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
        animatedBoxAnchor = sessionManager.addEntityWithAnchor(animatedBox.entity)

        // Animate flying to bottom position
        animatedBox.animateFlyToBottom(duration: BoxAnimationTiming.flyToBottom) { [weak self] in
            guard let self = self else { return }

            // Phase 2: Grow vertical edges
            self.animationPhase = .growingVertical

            animatedBox.animateGrowVertical(duration: BoxAnimationTiming.growVertical) { [weak self] in
                guard let self = self else { return }

                // Phase 3: Complete - swap to regular BoxVisualization for editing
                self.animationPhase = .complete

                // Remove animated visualization and its anchor
                if let anchor = self.animatedBoxAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.animatedBoxAnchor = nil
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
                self.currentMeasurement = adjustedResult
                self.showBoxVisualization(for: adjustedBox, pointCloud: result.pointCloud, floorY: floorY, unit: self.currentUnit)

                self.isProcessing = false
            }
        }
    }

    func saveMeasurement(mode: MeasurementMode, unit: MeasurementUnit = .centimeters) {
        print("🔴 [ViewModel] saveMeasurement START")
        guard let result = currentMeasurement else {
            print("🔴 [ViewModel] No current measurement to save!")
            return
        }
        print("🔴 [ViewModel] Has measurement, proceeding...")

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
        print("🔴 [ViewModel] Posted notification")

        // Convert current box to CompletedBoxVisualization (keep it displayed)
        print("🔴 [ViewModel] Calling convertActiveBoxToCompleted...")
        convertActiveBoxToCompleted(result: result, unit: unit)
        print("🔴 [ViewModel] convertActiveBoxToCompleted done. Count: \(completedBoxCount)")

        // Clear active box state (but don't call discardMeasurement which removes all)
        print("🔴 [ViewModel] Calling clearActiveBoxOnly...")
        clearActiveBoxOnly()
        print("🔴 [ViewModel] saveMeasurement END")
    }

    /// Convert the active box to a completed visualization and keep it displayed
    private func convertActiveBoxToCompleted(result: MeasurementCalculator.MeasurementResult, unit: MeasurementUnit) {
        print("[ViewModel] Converting active box to completed visualization")
        print("[ViewModel] Dimensions: H=\(result.height*100)cm, L=\(result.length*100)cm, W=\(result.width*100)cm")

        // Remove oldest if at max capacity
        if completedBoxVisualizations.count >= maxCompletedBoxes {
            if let oldAnchor = completedBoxAnchors.first {
                sessionManager.removeAnchor(oldAnchor)
            }
            completedBoxVisualizations.removeFirst()
            completedBoxAnchors.removeFirst()
        }

        // Create completed visualization with dimension labels
        let completedViz = CompletedBoxVisualization(
            boundingBox: result.boundingBox,
            height: result.height,
            length: result.length,
            width: result.width,
            unit: unit
        )

        // Add to scene with its own anchor
        let anchor = sessionManager.addEntityWithAnchor(completedViz.entity)
        print("[ViewModel] Added completed box anchor. Total completed boxes: \(completedBoxVisualizations.count + 1)")

        completedBoxVisualizations.append(completedViz)
        completedBoxAnchors.append(anchor)
        completedBoxCount = completedBoxVisualizations.count
    }

    /// Clear only the active box, keeping completed boxes
    private func clearActiveBoxOnly() {
        print("[ViewModel] clearActiveBoxOnly called")
        print("[ViewModel] boxVisualizationAnchor exists: \(boxVisualizationAnchor != nil)")
        print("[ViewModel] completedBoxAnchors count: \(completedBoxAnchors.count)")

        // Remove active box visualization
        if let anchor = boxVisualizationAnchor {
            sessionManager.removeAnchor(anchor)
            print("[ViewModel] Removed active box anchor")
        }
        boxVisualization = nil
        boxVisualizationAnchor = nil
        pointCloudEntity = nil

        // Remove animation anchor if exists
        if let anchor = animatedBoxAnchor {
            sessionManager.removeAnchor(anchor)
        }
        animatedBoxAnchor = nil
        animatedBoxVisualization = nil

        // Reset active measurement state
        currentMeasurement = nil
        isEditing = false
        isDragging = false
        storedPointCloud = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationPhase = .showingTargetBrackets
        animationContext = nil
        animationCoordinator.cancelAnimation()

        print("[ViewModel] clearActiveBoxOnly completed. Completed boxes preserved: \(completedBoxAnchors.count)")
    }

    /// Clear all completed boxes from the scene
    func clearAllMeasurements() {
        for anchor in completedBoxAnchors {
            sessionManager.removeAnchor(anchor)
        }
        completedBoxVisualizations.removeAll()
        completedBoxAnchors.removeAll()
        completedBoxCount = 0
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
            boxVisualization?.updateDimensions(
                height: updatedResult.height,
                length: updatedResult.length,
                width: updatedResult.width
            )
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
        boxVisualization?.updateDimensions(
            height: updatedResult.height,
            length: updatedResult.length,
            width: updatedResult.width
        )
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
            boxVisualization?.updateDimensions(
                height: updatedResult.height,
                length: updatedResult.length,
                width: updatedResult.width
            )

            print("[ViewModel] Fit successful - new dimensions: L=\(fittedBox.length*100)cm, W=\(fittedBox.width*100)cm, H=\(fittedBox.height*100)cm")
        } else {
            print("[ViewModel] Fit failed - not enough points in current box")
        }
    }

    func discardMeasurement() {
        // Only discard the active box, not completed boxes
        clearActiveBoxOnly()
    }

    func toggleDebugMask() {
        showDebugMask.toggle()
    }

    func toggleDebugDepth() {
        showDebugDepth.toggle()
    }

    private func showBoxVisualization(for box: BoundingBox3D, pointCloud: [SIMD3<Float>]? = nil, floorY: Float? = nil, unit: MeasurementUnit = .centimeters) {
        // Store point cloud for Fit functionality
        storedPointCloud = pointCloud

        boxVisualization = BoxVisualization(boundingBox: box, interactive: false)

        // Set floor height for distance indicator
        if let floorY = floorY {
            boxVisualization?.floorY = floorY
        }

        // Set dimensions for labels on the wireframe
        if let result = currentMeasurement {
            boxVisualization?.setDimensions(
                height: result.height,
                length: result.length,
                width: result.width,
                unit: unit
            )
        }

        if let entity = boxVisualization?.entity {
            boxVisualizationAnchor = sessionManager.addEntityWithAnchor(entity)
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

    /// Remove active visualizations but preserve completed boxes
    private func removeAllVisualizations() {
        print("[ViewModel] removeAllVisualizations called. Completed boxes: \(completedBoxAnchors.count)")

        // Remove active box anchor if exists
        if let anchor = boxVisualizationAnchor {
            sessionManager.removeAnchor(anchor)
            print("[ViewModel] Removed active box anchor")
        }
        boxVisualization = nil
        boxVisualizationAnchor = nil

        // Remove animation anchor if exists
        if let anchor = animatedBoxAnchor {
            sessionManager.removeAnchor(anchor)
            print("[ViewModel] Removed animation anchor")
        }
        animatedBoxAnchor = nil
        animatedBoxVisualization = nil

        pointCloudEntity = nil
        print("[ViewModel] Completed boxes preserved: \(completedBoxAnchors.count)")
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

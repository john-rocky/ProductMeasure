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

                // Overlay UI (on top)
                GeometryReader { geometry in
                    VStack {
                        // Top bar with status and clear button
                        HStack {
                            StatusBar(
                                trackingMessage: viewModel.trackingMessage,
                                isProcessing: viewModel.isProcessing
                            )

                            Spacer()

                            // Clear all button (visible when completed boxes exist)
                            if viewModel.completedBoxCount > 0 {
                                Button(action: {
                                    viewModel.clearAllMeasurements()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash")
                                        Text("\(viewModel.completedBoxCount)")
                                            .font(PMTheme.mono(11))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(PMTheme.red.opacity(0.8))
                                    .clipShape(Capsule())
                                }
                            }

                            // Selection mode toggle (always visible)
                            SelectionModeToggle(selectionMode: $selectionMode)

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
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentMeasurement != nil)
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
            viewModel.currentMeasurementMode = measurementMode
        }
        .onDisappear {
            viewModel.pauseSession()
        }
        .onChange(of: measurementUnit) { _, newUnit in
            viewModel.currentUnit = newUnit
        }
        .onChange(of: measurementMode) { _, newMode in
            viewModel.currentMeasurementMode = newMode
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

        // Add pan gesture recognizer for handle dragging and box selection
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        context.coordinator.panGesture = panGesture

        // Store reference to arView in coordinator
        context.coordinator.arView = arView

        // Add UIKit box selection rect overlay (never captures touches)
        let boxSelectionRectView = BoxSelectionRectView(frame: arView.bounds)
        boxSelectionRectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(boxSelectionRectView)
        context.coordinator.boxSelectionRectView = boxSelectionRectView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.measurementMode = measurementMode
        context.coordinator.selectionMode = selectionMode

        // Both gestures always enabled; handler logic determines behavior
        context.coordinator.tapGesture?.isEnabled = true
        context.coordinator.panGesture?.isEnabled = true
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

        // UIKit box selection overlay
        var boxSelectionRectView: BoxSelectionRectView?

        // Drag state
        private var activeDragType: DragType?
        private var lastPanLocation: CGPoint?

        enum DragType {
            case faceHandle(HandleType)
            case rotationRing
            case boxSelection(startPoint: CGPoint)
        }

        init(viewModel: ARMeasurementViewModel, measurementMode: MeasurementMode, selectionMode: SelectionMode) {
            self.viewModel = viewModel
            self.measurementMode = measurementMode
            self.selectionMode = selectionMode
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let arView = arView else { return }

            let location = gesture.location(in: arView)
            print("[Tap] Location: \(location)")

            // Hit test for 3D entities first
            let results = arView.hitTest(location, query: .nearest, mask: .all)

            for result in results {
                var entity: Entity? = result.entity
                while let current = entity {
                    // 1. Check for action icon tap
                    if ActionIconBuilder.isActionEntity(current.name),
                       let actionType = ActionIconBuilder.parseActionType(entityName: current.name) {
                        print("[Tap] Action icon tapped: \(actionType)")
                        viewModel.handleActionTap(actionType, mode: measurementMode)
                        return
                    }

                    // 2. Check for completed billboard background tap
                    if current.name == "completed_billboard_bg" {
                        // Find which completed box this belongs to
                        if let boxId = viewModel.findCompletedBoxId(for: current) {
                            print("[Tap] Completed billboard tapped, boxId: \(boxId)")
                            viewModel.showCompletedBoxActions(boxId: boxId)
                            return
                        }
                    }

                    entity = current.parent
                }
            }

            // 3. If a completed box has action icons showing, dismiss them on empty tap
            if viewModel.selectedCompletedBoxId != nil {
                viewModel.dismissCompletedBoxActions()
                return
            }

            // 4. If editing, ignore taps (handle dragging is via pan)
            if viewModel.isEditing { return }

            // 5. Only handle new measurement taps in tap mode
            guard selectionMode == .tap else { return }

            Task {
                await viewModel.handleTap(at: location, mode: measurementMode)
            }
        }

        @MainActor @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let arView = arView else { return }

            let location = gesture.location(in: arView)

            switch gesture.state {
            case .began:
                if viewModel.isEditing {
                    // Editing mode: hit test for handle or rotation ring
                    if let dragType = hitTest(at: location, in: arView) {
                        activeDragType = dragType
                        lastPanLocation = location
                        print("[Pan] Started editing drag: \(dragType)")
                    }
                } else if selectionMode == .box && !viewModel.isProcessing {
                    // Box selection mode: start drawing selection rectangle
                    activeDragType = .boxSelection(startPoint: location)
                    boxSelectionRectView?.clearSelection()
                    print("[Pan] Started box selection at: \(location)")
                }

            case .changed:
                guard let dragType = activeDragType else { return }

                switch dragType {
                case .faceHandle(let handleType):
                    guard let lastLocation = lastPanLocation else { return }
                    let delta = CGPoint(
                        x: location.x - lastLocation.x,
                        y: location.y - lastLocation.y
                    )
                    viewModel.handleFaceDrag(handleType: handleType, screenDelta: delta, mode: measurementMode)
                    lastPanLocation = location

                case .rotationRing:
                    guard let lastLocation = lastPanLocation else { return }
                    let delta = CGPoint(
                        x: location.x - lastLocation.x,
                        y: location.y - lastLocation.y
                    )
                    viewModel.handleRotationDrag(screenDelta: delta, touchLocation: location)
                    lastPanLocation = location

                case .boxSelection(let startPoint):
                    let rect = CGRect(
                        x: min(startPoint.x, location.x),
                        y: min(startPoint.y, location.y),
                        width: abs(location.x - startPoint.x),
                        height: abs(location.y - startPoint.y)
                    )
                    let isValid = rect.width >= BoxSelectionRectView.minimumSize
                        && rect.height >= BoxSelectionRectView.minimumSize
                    boxSelectionRectView?.isRectValid = isValid
                    boxSelectionRectView?.selectionRect = rect
                }

            case .ended, .cancelled:
                guard let dragType = activeDragType else { return }

                switch dragType {
                case .faceHandle, .rotationRing:
                    print("[Pan] Ended editing drag")
                    viewModel.finishDrag()

                case .boxSelection(let startPoint):
                    let rect = CGRect(
                        x: min(startPoint.x, location.x),
                        y: min(startPoint.y, location.y),
                        width: abs(location.x - startPoint.x),
                        height: abs(location.y - startPoint.y)
                    )
                    boxSelectionRectView?.clearSelection()

                    if gesture.state == .ended
                        && rect.width >= BoxSelectionRectView.minimumSize
                        && rect.height >= BoxSelectionRectView.minimumSize {
                        print("[Pan] Box selection completed: \(rect)")
                        Task {
                            await viewModel.handleBoxSelection(
                                rect: rect,
                                viewSize: arView.bounds.size,
                                mode: measurementMode
                            )
                        }
                    }
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
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
                Text("Processing...")
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            } else {
                Image(systemName: trackingStatusIcon)
                    .foregroundColor(trackingStatusColor)
                    .symbolEffect(.pulse, options: .repeating, value: trackingMessage == "Ready to measure")
                Text(trackingMessage)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(PMTheme.cyan.opacity(0.30), lineWidth: 0.5)
        )
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
            return PMTheme.green
        } else if trackingMessage.contains("not") || trackingMessage.contains("Not") {
            return PMTheme.red
        } else {
            return PMTheme.amber
        }
    }
}

// MARK: - Scanning Indicator

struct ScanningIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(PMTheme.cyan.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(PMTheme.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Instruction Card

struct InstructionCard: View {
    var mode: SelectionMode = .tap
    @State private var iconScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(PMTheme.cyan.opacity(0.12))
                    .frame(width: 52, height: 52)
                    .scaleEffect(iconScale)

                Image(systemName: mode == .tap ? "hand.tap.fill" : "rectangle.dashed")
                    .font(.title2)
                    .foregroundStyle(PMTheme.cyanGradient)
                    .scaleEffect(iconScale)
            }

            Text(mode == .tap ? "Tap on an object to measure" : "Draw a box to select")
                .font(PMTheme.mono(14, weight: .semibold))
                .foregroundColor(PMTheme.textPrimary)

            Text(mode == .tap
                 ? "Point your device at an object and tap"
                 : "Drag to draw a rectangle around the object")
                .font(PMTheme.mono(11))
                .multilineTextAlignment(.center)
                .foregroundColor(PMTheme.textDimmed)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(PMTheme.surfaceGlass)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                iconScale = 1.08
            }
        }
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

    // Selected completed box for action icons
    @Published var selectedCompletedBoxId: Int? = nil

    // Current measurement mode (synced from view)
    var currentMeasurementMode: MeasurementMode = .boxPriority

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

    // Box ID counter (increments with each save)
    private var nextBoxId: Int = 1

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
        let cameraForward = -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )

        // Active box billboard is always visible (excluded from prominence logic)
        if let boxViz = boxVisualization {
            boxViz.setDimensionBillboardVisible(true, forceShow: true)
            boxViz.updateLabelOrientations(cameraPosition: cameraPosition)
        }

        // Find the most prominent completed box for billboard visibility
        let visibilityThreshold: Float = 0.3  // ~70° cone
        var maxDotProduct: Float = visibilityThreshold
        var mostProminentCompletedIndex: Int? = nil

        for (index, visualization) in completedBoxVisualizations.enumerated() {
            let toBox = visualization.boundingBox.center - cameraPosition
            let distance = simd_length(toBox)
            if distance > 0.01 {
                let dot = simd_dot(toBox / distance, cameraForward)
                if dot > maxDotProduct {
                    maxDotProduct = dot
                    mostProminentCompletedIndex = index
                }
            }
        }

        // Update billboard visibility and orientation for completed boxes
        for (index, visualization) in completedBoxVisualizations.enumerated() {
            let isProminent = (mostProminentCompletedIndex == index)
            visualization.setDimensionBillboardVisible(isProminent)
            if isProminent {
                visualization.updateLabelOrientations(cameraPosition: cameraPosition)
            }
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

                // Use detected floor plane Y if available, fall back to raycast hit Y
                let floorY = result.detectedFloorY ?? raycastHitPosition?.y

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

                // Use detected floor plane Y if available, fall back to raycast hit Y
                let floorY = result.detectedFloorY ?? raycastHitPosition?.y

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

        // Phase 1: Edge trace - draw bottom edges sequentially
        animationPhase = .edgeTrace

        // Create animated box visualization
        animatedBoxVisualization = AnimatedBoxVisualization(boundingBox: boundingBox)
        guard let animatedBox = animatedBoxVisualization else {
            isProcessing = false
            return
        }

        // Setup the 3D rect at camera position
        animatedBox.setupAtCameraPosition(
            cameraTransform: cameraTransform,
            distanceFromCamera: 0.5,
            rectSize: 0.25
        )
        animatedBoxAnchor = sessionManager.addEntityWithAnchor(animatedBox.entity)

        // Phase 1: Edge trace animation
        animatedBox.animateEdgeTrace(duration: BoxAnimationTiming.edgeTrace) { [weak self] in
            guard let self = self else { return }

            // Phase 2: Fly to bottom position
            self.animationPhase = .flyingToBottom

            animatedBox.animateFlyToBottom(duration: BoxAnimationTiming.flyToBottom) { [weak self] in
                guard let self = self else { return }

                // Phase 3: Grow vertical edges
                self.animationPhase = .growingVertical

                animatedBox.animateGrowVertical(duration: BoxAnimationTiming.growVertical) { [weak self] in
                    guard let self = self else { return }

                    // Phase 4: Completion pulse
                    self.animationPhase = .completionPulse

                    animatedBox.animateCompletionPulse(duration: BoxAnimationTiming.completionPulse) { [weak self] in
                        guard let self = self else { return }

                        // Phase 5: Complete - swap to regular BoxVisualization
                        self.animationPhase = .complete

                        if let anchor = self.animatedBoxAnchor {
                            self.sessionManager.removeAnchor(anchor)
                        }
                        self.animatedBoxAnchor = nil
                        self.animatedBoxVisualization = nil

                        var adjustedBox = boundingBox
                        if let floorY = floorY {
                            adjustedBox.extendBottomToFloor(floorY: floorY, threshold: 0.05)
                        }

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

        // Create completed visualization with dimension labels and re-edit data
        let completedViz = CompletedBoxVisualization(
            boundingBox: result.boundingBox,
            height: result.height,
            length: result.length,
            width: result.width,
            unit: unit,
            boxId: nextBoxId,
            quality: result.quality,
            axisMapping: result.axisMapping,
            pointCloud: result.pointCloud,
            floorY: boxVisualization?.floorY
        )
        nextBoxId += 1

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
        nextBoxId = 1
    }

    func startEditing() {
        isEditing = true
        boxVisualization?.isInteractive = true
        boxVisualization?.updateActionMode(.editing)
    }

    func stopEditing() {
        isEditing = false
        isDragging = false
        boxVisualization?.isInteractive = false
        boxVisualization?.updateActionMode(.normal)
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

    // MARK: - Action Icon Handling

    /// Handle tap on a 3D action icon
    func handleActionTap(_ actionType: ActionType, mode: MeasurementMode) {
        switch actionType {
        case .save:
            stopEditing()
            saveMeasurement(mode: mode, unit: currentUnit)
        case .edit:
            startEditing()
        case .discard:
            discardMeasurement()
        case .done:
            stopEditing()
        case .fit:
            fitToPointCloud(mode: mode)
        case .cancel:
            discardMeasurement()
        case .reEdit:
            reEditCompletedBox()
        case .delete:
            deleteCompletedBox()
        }
    }

    /// Find the completed box ID that owns a given entity
    func findCompletedBoxId(for entity: Entity) -> Int? {
        for viz in completedBoxVisualizations {
            // Walk up from the entity to check if it belongs to this visualization
            var current: Entity? = entity
            while let node = current {
                if node === viz.entity {
                    return viz.id
                }
                current = node.parent
            }
        }
        return nil
    }

    /// Show action icons on a completed box
    func showCompletedBoxActions(boxId: Int) {
        // Dismiss any existing actions first
        dismissCompletedBoxActions()

        selectedCompletedBoxId = boxId
        if let viz = completedBoxVisualizations.first(where: { $0.id == boxId }) {
            viz.showActionIcons()
        }
    }

    /// Dismiss action icons on completed boxes
    func dismissCompletedBoxActions() {
        if let selectedId = selectedCompletedBoxId,
           let viz = completedBoxVisualizations.first(where: { $0.id == selectedId }) {
            viz.hideActionIcons()
        }
        selectedCompletedBoxId = nil
    }

    /// Re-edit a completed box (make it active again)
    private func reEditCompletedBox() {
        guard let selectedId = selectedCompletedBoxId,
              let index = completedBoxVisualizations.firstIndex(where: { $0.id == selectedId }) else {
            return
        }

        let completedViz = completedBoxVisualizations[index]

        // Auto-save current active box if exists
        if let existingResult = currentMeasurement {
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)
            clearActiveBoxOnly()
        }

        // Get data from completed box
        let result = completedViz.toMeasurementResult()
        let floorY = completedViz.floorY
        let pointCloud = completedViz.pointCloud

        // Remove the completed box from scene
        let anchor = completedBoxAnchors[index]
        sessionManager.removeAnchor(anchor)
        completedBoxVisualizations.remove(at: index)
        completedBoxAnchors.remove(at: index)
        completedBoxCount = completedBoxVisualizations.count
        selectedCompletedBoxId = nil

        // Set as current measurement and show editable box
        currentMeasurement = result
        showBoxVisualization(for: result.boundingBox, pointCloud: pointCloud, floorY: floorY, unit: currentUnit)
        animationPhase = .complete

        // Enter editing mode
        startEditing()
    }

    /// Delete a specific completed box
    private func deleteCompletedBox() {
        guard let selectedId = selectedCompletedBoxId,
              let index = completedBoxVisualizations.firstIndex(where: { $0.id == selectedId }) else {
            return
        }

        let anchor = completedBoxAnchors[index]
        sessionManager.removeAnchor(anchor)
        completedBoxVisualizations.remove(at: index)
        completedBoxAnchors.remove(at: index)
        completedBoxCount = completedBoxVisualizations.count
        selectedCompletedBoxId = nil
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
                unit: unit,
                boxId: nextBoxId
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

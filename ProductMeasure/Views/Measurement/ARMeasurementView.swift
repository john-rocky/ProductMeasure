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

    /// When workflow is active, derives selection mode from workflow step
    private var activeSelectionMode: SelectionMode {
        viewModel.isWorkflowActive ? viewModel.effectiveSelectionMode : selectionMode
    }

    var body: some View {
        ZStack {
            // AR Camera View
            if LiDARChecker.isLiDARAvailable {
                ARMeasurementViewRepresentable(
                    viewModel: viewModel,
                    measurementMode: measurementMode,
                    selectionMode: activeSelectionMode
                )
                    .ignoresSafeArea()

                // Corner brackets overlay
                if activeSelectionMode == .tap {
                    GeometryReader { geometry in
                        CornerBracketsView(
                            phase: viewModel.animationPhase,
                            screenSize: geometry.size
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                } else if activeSelectionMode == .label {
                    GeometryReader { geometry in
                        LabelScanBracketsView(
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
                        // Top bar: only clear button
                        HStack {
                            Spacer()

                            // Clear all button (visible when completed boxes exist)
                            if viewModel.completedBoxCount > 0 && !viewModel.isWorkflowActive {
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
                        }

                        Spacer()

                        // Save/Check button when workflow reaches showingResult
                        if viewModel.workflowStep == .showingResult {
                            let isCheck = viewModel.calloutBoxId == 2
                            Button(action: {
                                viewModel.showMeasurementConsole()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: isCheck ? "exclamationmark.magnifyingglass" : "checkmark.rectangle")
                                        .font(.system(size: 14))
                                    Text(isCheck ? "CHECK" : "SAVE")
                                        .font(PMTheme.mono(14, weight: .bold))
                                }
                                .foregroundColor(.black)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(isCheck ? PMTheme.amber : PMTheme.cyan)
                                .clipShape(Capsule())
                                .shadow(color: (isCheck ? PMTheme.amber : PMTheme.cyan).opacity(0.4), radius: 8, x: 0, y: 2)
                            }
                        }

                        // Instruction / status prompt (bottom)
                        if viewModel.isProcessing {
                            InstructionCard(mode: .processing)
                        } else if viewModel.isRefining {
                            InstructionCard(mode: .refine)
                        } else if viewModel.currentMeasurement == nil && !viewModel.isReadingLabel {
                            if viewModel.isWorkflowActive {
                                switch viewModel.workflowStep {
                                case .awaitingLabelScan:
                                    InstructionCard(mode: .label)
                                case .awaitingSecondTap:
                                    InstructionCard(mode: .secondTap)
                                default:
                                    InstructionCard(mode: .ready(viewModel.trackingMessage))
                                }
                            } else {
                                if selectionMode == .tap && (viewModel.animationPhase == .showingTargetBrackets || viewModel.hasPendingFirstTap) {
                                    InstructionCard(mode: .tap)
                                } else if selectionMode == .box {
                                    InstructionCard(mode: .box)
                                } else if selectionMode == .label {
                                    InstructionCard(mode: .label)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentMeasurement != nil)
                .animation(.easeInOut(duration: 0.3), value: viewModel.workflowStep)
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

                // Barcode scan effect overlay
                if viewModel.showBarcodeScanEffect, let labelData = viewModel.currentLabelData {
                    BarcodeScanEffectView(
                        labelData: labelData,
                        labelImageSize: viewModel.correctedLabelImageSize,
                        labelImage: viewModel.correctedLabelImage,
                        onComplete: { viewModel.barcodeScanEffectCompleted() }
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Floating reset button during scan animations
                if viewModel.isReadingLabel || viewModel.showBarcodeScanEffect {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                viewModel.resetLabelScan()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 60)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // Label result overlay
                if viewModel.showLabelResult, !viewModel.showLabelBillboard, let labelData = viewModel.currentLabelData {
                    ZStack {
                        // Dim background
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)

                        LabelResultView(
                            labelData: labelData,
                            lineRevealed: viewModel.labelLineRevealed,
                            isComplete: viewModel.labelReadingComplete,
                            onDismiss: {
                                viewModel.dismissLabelResult()
                                if !viewModel.isWorkflowActive {
                                    selectionMode = .tap
                                }
                            },
                            onRescan: {
                                viewModel.resetLabelScan()
                            },
                            dismissButtonLabel: viewModel.isWorkflowActive ? "CONTINUE" : "DONE"
                        )
                    }
                    .transition(.opacity)
                }

                // Dimension callout overlay
                if viewModel.showDimensionCallout {
                    GeometryReader { geometry in
                        DimensionCalloutView(
                            boxId: viewModel.calloutBoxId,
                            width: viewModel.calloutWidth,
                            height: viewModel.calloutHeight,
                            length: viewModel.calloutLength,
                            lineRevealed: viewModel.calloutLineRevealed,
                            transitionProgress: viewModel.calloutTransitionProgress,
                            targetPosition: viewModel.calloutTargetScreenPosition,
                            screenSize: geometry.size
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                // Status vignette flash (OK=green, NG=red)
                if viewModel.showStatusVignette {
                    StatusVignetteView(
                        isNG: viewModel.statusVignetteIsNG,
                        isVisible: $viewModel.showStatusVignette
                    )
                    .transition(.opacity)
                }

                // Measurement console overlay
                if viewModel.showConsole, let result = viewModel.currentMeasurement {
                    let unit = measurementUnit
                    MeasurementConsoleView(
                        width: formatValue(result.width, unit: unit),
                        height: formatValue(result.height, unit: unit),
                        length: formatValue(result.length, unit: unit),
                        volume: String(format: "%.2f %@", unit.convertVolume(cubicMeters: result.boundingBox.volume), unit.volumeUnit()),
                        volumetricWeight: unit.formatVolumetricWeight(cubicMeters: result.boundingBox.volume),
                        sizeClass: SizeClass.classify(volumeCubicMeters: result.boundingBox.volume).rawValue,
                        qualityLabel: result.quality.overallQuality.rawValue.capitalized,
                        pointCount: result.quality.pointCount,
                        labelData: viewModel.pendingLabelData,
                        cartonId: viewModel.pendingLabelData?.cartonId,
                        boxId: viewModel.calloutBoxId,
                        lineRevealed: viewModel.consoleLineRevealed,
                        isComplete: viewModel.consoleReadingComplete,
                        wmsLineStatus: viewModel.wmsLineStatus,
                        onExportCSV: { viewModel.showCSVExport() },
                        onClose: { viewModel.closeWorkflow() },
                        onReMeasure: { viewModel.closeWorkflow() }
                    )
                    .transition(.opacity)
                }

                // CSV display overlay
                if viewModel.showCSVDisplay {
                    CSVDisplayView(
                        csvString: viewModel.csvString,
                        onDone: { viewModel.closeWorkflow() }
                    )
                    .transition(.opacity)
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

    private func formatValue(_ meters: Float, unit: MeasurementUnit) -> String {
        let value = unit.convert(meters: meters)
        return String(format: "%.2f %@", value, unit.rawValue)
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

            // 4.5. If refining, route to refinement handler
            if viewModel.isRefining {
                Task { await viewModel.handleRefinementTap(at: location, mode: measurementMode) }
                return
            }

            // 5. Handle label mode taps
            // Read effective selection mode directly from viewModel to avoid stale
            // coordinator state (updateUIView may lag behind @Published changes)
            let effectiveMode = viewModel.isWorkflowActive ? viewModel.effectiveSelectionMode : selectionMode
            guard effectiveMode != .label else {
                Task { await viewModel.handleLabelTap(at: location) }
                return
            }

            // 6. Only handle new measurement taps in tap mode
            guard effectiveMode == .tap else { return }

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
    enum Mode: Equatable {
        case tap, box, refine, secondTap, label
        case processing
        case ready(String)  // tracking message
    }

    var mode: Mode = .tap

    private var isProcessing: Bool {
        if case .processing = mode { return true }
        return false
    }

    private var iconName: String {
        switch mode {
        case .tap: return "hand.tap.fill"
        case .box: return "rectangle.dashed"
        case .refine: return "arrow.triangle.2.circlepath"
        case .secondTap: return "arrow.triangle.2.circlepath"
        case .label: return "doc.text.viewfinder"
        case .processing: return "circle.dotted"
        case .ready(let msg):
            if msg == "Ready to measure" { return "checkmark.circle.fill" }
            else if msg.contains("not") || msg.contains("Not") { return "exclamationmark.triangle.fill" }
            else { return "arrow.triangle.2.circlepath" }
        }
    }

    private var title: String {
        switch mode {
        case .tap: return "Tap on an object to measure"
        case .box: return "Draw a box to select"
        case .refine: return "Refine from a different angle"
        case .secondTap: return "Tap again from a different angle"
        case .label: return "Point at a label and tap"
        case .processing: return "Processing..."
        case .ready(let msg): return msg
        }
    }

    private var isLabelMode: Bool { mode == .label }

    private var accentColor: Color {
        if isLabelMode { return PMTheme.labelBlue }
        if case .ready(let msg) = mode {
            if msg == "Ready to measure" { return PMTheme.green }
            else if msg.contains("not") || msg.contains("Not") { return PMTheme.red }
            else { return PMTheme.amber }
        }
        return PMTheme.cyan
    }

    var body: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                    .symbolEffect(.pulse, options: .repeating, value: isReadyPulse)
            }

            Text(title)
                .font(PMTheme.mono(13))
                .foregroundColor(PMTheme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(accentColor.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private var isReadyPulse: Bool {
        if case .ready(let msg) = mode { return msg == "Ready to measure" }
        return false
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

    // Refinement state
    @Published var isRefining = false
    private var refinementCount: Int = 0
    private var accumulatedPointClouds: [[SIMD3<Float>]] = []
    private var accumulatedQualities: [MeasurementQuality] = []
    private var originalAxisMapping: BoundingBox3D.AxisMapping?
    private var originalFloorY: Float?

    // Status vignette state
    @Published var showStatusVignette = false
    @Published var statusVignetteIsNG = false

    // Dimension callout state
    @Published var showDimensionCallout = false
    @Published var calloutLineRevealed: [Bool] = [false, false, false, false]
    @Published var calloutTransitionProgress: CGFloat = 0.0
    @Published var calloutTargetScreenPosition: CGPoint = .zero
    @Published var calloutBoxId: Int = 0
    @Published var calloutWidth: String = ""
    @Published var calloutHeight: String = ""
    @Published var calloutLength: String = ""

    // Two-tap flow: pending first-tap result (measured but not yet displayed)
    @Published var hasPendingFirstTap = false
    private var pendingFirstTapResult: MeasurementCalculator.MeasurementResult?
    private var pendingFirstTapFloorY: Float?

    // Label reader state
    @Published var isReadingLabel = false
    @Published var showLabelResult = false
    @Published var showBarcodeScanEffect = false
    @Published var currentLabelData: LabelData?
    @Published var correctedLabelImageSize: CGSize = .zero
    @Published var correctedLabelImage: UIImage?
    @Published var labelLineRevealed: [Bool] = []
    @Published var labelReadingComplete = false
    var pendingLabelData: LabelData?
    private let labelReaderService = LabelReaderService()
    private var labelLiftAnimation: LabelLiftAnimation?
    private var labelLiftAnchor: AnchorEntity?
    private var labelBillboard: LabelBillboard?
    private var labelBillboardAnchor: AnchorEntity?
    @Published var showLabelBillboard = false

    // Guided workflow state
    @Published var workflowStep: WorkflowStep = .idle
    @Published var showConsole = false
    @Published var showCSVDisplay = false
    @Published var consoleLineRevealed: [Bool] = []
    @Published var consoleReadingComplete = false
    @Published var wmsLineStatus: [WMSLineStatus] = []
    @Published var csvString: String = ""
    private let exportService = ExportService()

    /// Derives selection mode from workflow step when workflow is active
    var effectiveSelectionMode: SelectionMode {
        switch workflowStep {
        case .awaitingLabelScan, .showingLabelResult:
            return .label
        default:
            return .tap
        }
    }

    var isWorkflowActive: Bool {
        workflowStep != .idle
    }

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

    /// Last camera position/forward for delta check (skip updates when stationary)
    private var lastFrameCameraPosition: SIMD3<Float> = .zero
    private var lastFrameCameraForward: SIMD3<Float> = .init(0, 0, -1)

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

        // Skip billboard updates when camera is nearly stationary
        let posDelta = simd_distance(cameraPosition, lastFrameCameraPosition)
        let dirDelta = simd_distance(cameraForward, lastFrameCameraForward)
        guard posDelta > 0.005 || dirDelta > 0.01 else { return }
        lastFrameCameraPosition = cameraPosition
        lastFrameCameraForward = cameraForward

        // Active box billboard is always visible (excluded from prominence logic)
        // But hide during callout transition when 2D card is showing
        // Also hide permanently when unified label billboard is active
        if let boxViz = boxVisualization {
            let inCalloutPhase = animationPhase == .dimensionCallout || animationPhase == .calloutTransition
            let unifiedLabelActive = showLabelBillboard && (labelBillboard?.isUnified == true)
            if !inCalloutPhase && !unifiedLabelActive {
                boxViz.setDimensionBillboardVisible(true, forceShow: true)
            } else if unifiedLabelActive {
                boxViz.setDimensionBillboardVisible(false)
            }
            boxViz.updateLabelOrientations(cameraPosition: cameraPosition)
        }

        // Label billboard orientation tracking
        if showLabelBillboard {
            labelBillboard?.updateOrientation(cameraPosition: cameraPosition)
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

        // Safety: if workflow expects label scan, redirect (handles stale coordinator selectionMode)
        if workflowStep == .awaitingLabelScan || workflowStep == .showingLabelResult {
            print("[ViewModel] Redirecting to handleLabelTap (workflow expects label scan)")
            await handleLabelTap(at: location)
            return
        }

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

        // Two-tap flow: if we have a pending first-tap result, this is the second tap
        if let firstResult = pendingFirstTapResult {
            await handleSecondTap(at: location, mode: mode, firstResult: firstResult, frame: frame)
            return
        }

        // Auto-save current measurement as completed box before starting new one
        if let existingResult = currentMeasurement {
            print("[ViewModel] Auto-saving existing measurement before new tap")
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)

            // Transfer label billboard to the newly completed viz
            if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
               let lastViz = completedBoxVisualizations.last {
                lastViz.attachLabelBillboard(billboard, anchor: anchor)
                labelBillboard = nil
                labelBillboardAnchor = nil
                showLabelBillboard = false
            }
        }

        // Clean up previous measurement to free memory
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationContext = nil

        isProcessing = true
        print("[ViewModel] Starting first-tap measurement (silent)...")

        // Get 3D world position from raycast
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
                print("[ViewModel] First-tap measurement successful (silent)")
                print("[ViewModel] Dimensions: L=\(result.length*100)cm, W=\(result.width*100)cm, H=\(result.height*100)cm")

                // Store as pending first-tap result (no animation, no box display)
                pendingFirstTapResult = result
                pendingFirstTapFloorY = raycastHitPosition?.y
                hasPendingFirstTap = true

                // Start guided workflow: auto-transition to label scan step
                workflowStep = .awaitingLabelScan

                // Seed refinement accumulators for the merge on second tap
                if let pc = result.pointCloud {
                    accumulatedPointClouds = [pc]
                } else {
                    accumulatedPointClouds = []
                }
                accumulatedQualities = [result.quality]
                originalAxisMapping = result.axisMapping

                isProcessing = false
            } else {
                print("[ViewModel] First-tap measurement returned nil")
                isProcessing = false
            }
        } catch {
            print("[ViewModel] First-tap measurement failed with error: \(error)")
            isProcessing = false
        }
    }

    /// Second tap: refine with the pending first-tap result, then show animated box
    private func handleSecondTap(at location: CGPoint, mode: MeasurementMode, firstResult: MeasurementCalculator.MeasurementResult, frame: ARFrame) async {
        isProcessing = true
        print("[ViewModel] Starting second-tap refinement...")

        let viewSize = sessionManager.arView.bounds.size
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)

        do {
            if let refinement = try await measurementCalculator.measureForRefinement(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize,
                mode: mode,
                existingBox: firstResult.boundingBox,
                raycastHitPosition: raycastHitPosition
            ) {
                // Merge point clouds from both taps
                accumulatedPointClouds.append(refinement.points)
                accumulatedQualities.append(refinement.quality)
                refinementCount = 1

                let mergedPoints = accumulatedPointClouds.flatMap { $0 }
                let mergedQuality = MeasurementQuality.merged(accumulatedQualities)

                // Re-estimate bounding box from merged points
                let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                    guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                    return plane
                }

                guard let newBox = BoundingBoxEstimator().estimateBoundingBox(
                    points: mergedPoints, mode: mode, verticalPlaneAnchors: verticalPlanes
                ) else {
                    print("[ViewModel] Second-tap re-estimation failed, falling back to first-tap result")
                    // Fall back to showing the first-tap result directly
                    showFirstTapResultWithAnimation(at: location, firstResult: firstResult, frame: frame)
                    return
                }

                // Apply floor extension
                var adjustedBox = newBox
                let floorY = pendingFirstTapFloorY ?? raycastHitPosition?.y
                if let floorY = floorY {
                    adjustedBox.extendBottomToFloor(floorY: floorY, threshold: 0.05)
                }

                // Recalculate with original axis mapping
                let mapping = originalAxisMapping ?? firstResult.axisMapping
                var mergedResult = measurementCalculator.recalculate(
                    boundingBox: adjustedBox, quality: mergedQuality, axisMapping: mapping
                )
                mergedResult.pointCloud = mergedPoints
                mergedResult.debugMaskImage = firstResult.debugMaskImage
                mergedResult.debugDepthImage = firstResult.debugDepthImage

                // Store debug images
                debugMaskImage = firstResult.debugMaskImage
                debugDepthImage = firstResult.debugDepthImage

                // Clear pending state
                pendingFirstTapResult = nil
                pendingFirstTapFloorY = nil
                hasPendingFirstTap = false
                originalFloorY = floorY

                print("[ViewModel] Second-tap refinement successful! Dimensions: L=\(mergedResult.length*100)cm W=\(mergedResult.width*100)cm H=\(mergedResult.height*100)cm")

                // Now show the animation with the refined result
                startBoxAnimation(
                    at: location,
                    boundingBox: adjustedBox,
                    frame: frame,
                    viewSize: viewSize,
                    result: mergedResult,
                    floorY: floorY
                )
            } else {
                print("[ViewModel] Second-tap refinement: object not matched, falling back to first-tap result")
                showFirstTapResultWithAnimation(at: location, firstResult: firstResult, frame: frame)
            }
        } catch {
            print("[ViewModel] Second-tap refinement error: \(error), falling back to first-tap result")
            showFirstTapResultWithAnimation(at: location, firstResult: firstResult, frame: frame)
        }
    }

    /// Fallback: show first-tap result with animation when second tap refinement fails
    private func showFirstTapResultWithAnimation(at location: CGPoint, firstResult: MeasurementCalculator.MeasurementResult, frame: ARFrame) {
        let viewSize = sessionManager.arView.bounds.size
        let floorY = pendingFirstTapFloorY

        // Store debug images
        debugMaskImage = firstResult.debugMaskImage
        debugDepthImage = firstResult.debugDepthImage

        // Clear pending state
        pendingFirstTapResult = nil
        pendingFirstTapFloorY = nil
        hasPendingFirstTap = false
        originalFloorY = floorY

        // Show animation with first-tap result
        startBoxAnimation(
            at: location,
            boundingBox: firstResult.boundingBox,
            frame: frame,
            viewSize: viewSize,
            result: firstResult,
            floorY: floorY
        )
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

        // Clean up previous measurement and pending first-tap state
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        debugMaskImage = nil
        debugDepthImage = nil
        animationContext = nil
        clearPendingFirstTap()

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

                        // Phase 5: Dimension callout
                        self.animationPhase = .dimensionCallout

                        // Prepare adjusted box and result for callout display
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

                        // Populate callout data
                        self.calloutBoxId = self.nextBoxId
                        self.calloutWidth = self.formatCalloutValue(adjustedResult.width, unit: self.currentUnit)
                        self.calloutHeight = self.formatCalloutValue(adjustedResult.height, unit: self.currentUnit)
                        self.calloutLength = self.formatCalloutValue(adjustedResult.length, unit: self.currentUnit)
                        self.calloutLineRevealed = [false, false, false, false]
                        self.calloutTransitionProgress = 0.0
                        self.showDimensionCallout = true

                        // Stagger line reveals
                        Task { [weak self] in
                            guard let self = self else { return }
                            let stagger = PMTheme.calloutLineStagger

                            for i in 0..<4 {
                                try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                                guard self.showDimensionCallout else { return }
                                withAnimation(.easeOut(duration: 0.2)) {
                                    self.calloutLineRevealed[i] = true
                                }
                            }

                            // Hold briefly
                            try? await Task.sleep(nanoseconds: UInt64(PMTheme.calloutHoldDuration * 1_000_000_000))
                            guard self.showDimensionCallout else { return }

                            // Phase 6: Transition — swap animated box to real BoxVisualization
                            self.animationPhase = .calloutTransition

                            // Remove animated box, create real visualization
                            if let anchor = self.animatedBoxAnchor {
                                self.sessionManager.removeAnchor(anchor)
                            }
                            self.animatedBoxAnchor = nil
                            self.animatedBoxVisualization = nil

                            self.currentMeasurement = adjustedResult
                            self.showBoxVisualization(for: adjustedBox, pointCloud: result.pointCloud, floorY: floorY, unit: self.currentUnit)

                            // Hide 3D billboard initially
                            self.boxVisualization?.setDimensionBillboardVisible(false)

                            // Compute target screen position — use label billboard top if available
                            let billboardWorldPos: SIMD3<Float>
                            if self.showLabelBillboard, let lb = self.labelBillboard {
                                billboardWorldPos = lb.getTopWorldPosition()
                            } else {
                                billboardWorldPos = adjustedBox.center + SIMD3<Float>(0, adjustedBox.extents.y + 0.03, 0)
                            }
                            if let screenPos = self.sessionManager.projectToScreen(worldPosition: billboardWorldPos) {
                                self.calloutTargetScreenPosition = screenPos
                            } else {
                                // Fallback: screen center
                                let viewSize = self.sessionManager.arView.bounds.size
                                self.calloutTargetScreenPosition = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                            }

                            // Start label billboard expansion concurrently with callout transition
                            if self.showLabelBillboard, let lb = self.labelBillboard {
                                self.boxVisualization?.setDimensionBillboardVisible(false)

                                let qualityLabel = adjustedResult.quality.overallQuality.rawValue
                                let pointCount = adjustedResult.quality.pointCount
                                // Trigger status vignette flash at banner reveal
                                self.statusVignetteIsNG = self.nextBoxId == 2
                                self.showStatusVignette = true

                                lb.expandWithDimensions(
                                    height: adjustedResult.height,
                                    length: adjustedResult.length,
                                    width: adjustedResult.width,
                                    unit: self.currentUnit,
                                    boxId: self.nextBoxId,
                                    volume: adjustedBox.volume,
                                    qualityLabel: qualityLabel,
                                    pointCount: pointCount
                                ) { [weak self] in
                                    guard let self = self else { return }
                                    self.animationPhase = .complete
                                    self.isProcessing = false

                                    if self.workflowStep == .awaitingSecondTap {
                                        self.workflowStep = .showingResult
                                    }
                                }
                            }

                            // Animate 2D card toward billboard position
                            withAnimation(.easeInOut(duration: PMTheme.calloutTransitionDuration)) {
                                self.calloutTransitionProgress = 1.0
                            }

                            // Wait for transition to complete
                            try? await Task.sleep(nanoseconds: UInt64(PMTheme.calloutTransitionDuration * 1_000_000_000))

                            // Phase 7: Complete
                            self.showDimensionCallout = false

                            if !self.showLabelBillboard {
                                // Normal flow (no label): show box billboard
                                self.boxVisualization?.setDimensionBillboardVisible(true, forceShow: true)
                                self.animationPhase = .complete
                                self.isProcessing = false

                                if self.workflowStep == .awaitingSecondTap {
                                    self.workflowStep = .showingResult
                                }
                            }
                        }
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

        // Create and save measurement (attach pending label data if available)
        let measurement = ProductMeasurement(
            boundingBox: result.boundingBox,
            quality: result.quality,
            mode: mode,
            annotatedImageData: imageData,
            labelData: pendingLabelData
        )
        pendingLabelData = nil

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

        // Transfer label billboard ownership to the completed visualization
        if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
           let lastViz = completedBoxVisualizations.last {
            lastViz.attachLabelBillboard(billboard, anchor: anchor)
            // Nil out ViewModel references so clearActiveBoxOnly() won't remove them
            labelBillboard = nil
            labelBillboardAnchor = nil
            showLabelBillboard = false
            print("🔴 [ViewModel] Transferred label billboard to completed viz")
        }

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
            // Clean up oldest viz's attached label billboard if any
            completedBoxVisualizations.first?.removeAttachedLabelBillboard()
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

        // Reset refinement state
        isRefining = false
        refinementCount = 0
        accumulatedPointClouds = []
        accumulatedQualities = []
        originalAxisMapping = nil
        originalFloorY = nil

        // Reset pending first-tap state
        clearPendingFirstTap()

        // Reset callout state
        resetCalloutState()

        // Reset workflow state
        workflowStep = .idle
        showConsole = false
        showCSVDisplay = false
        consoleLineRevealed = []
        consoleReadingComplete = false
        csvString = ""

        // Clean up label billboard if present
        if showLabelBillboard {
            showLabelBillboard = false
            labelBillboard?.entity.isEnabled = false
            if let anchor = labelBillboardAnchor {
                sessionManager.removeAnchor(anchor)
            }
            labelBillboardAnchor = nil
            labelBillboard = nil
        }

        // Clean up lift animation if present (may survive if billboard path was used)
        if let anchor = labelLiftAnchor {
            sessionManager.removeAnchor(anchor)
        }
        labelLiftAnchor = nil
        labelLiftAnimation = nil

        // Reset label processing flags
        currentLabelData = nil
        pendingLabelData = nil
        isReadingLabel = false
        showBarcodeScanEffect = false
        correctedLabelImage = nil

        print("[ViewModel] clearActiveBoxOnly completed. Completed boxes preserved: \(completedBoxAnchors.count)")
    }

    /// Clear all completed boxes from the scene
    func clearAllMeasurements() {
        for viz in completedBoxVisualizations {
            viz.removeAttachedLabelBillboard()
        }
        for anchor in completedBoxAnchors {
            sessionManager.removeAnchor(anchor)
        }
        completedBoxVisualizations.removeAll()
        completedBoxAnchors.removeAll()
        completedBoxCount = 0
        nextBoxId = 1
        clearPendingFirstTap()
    }

    func startEditing() {
        isEditing = true
        boxVisualization?.isInteractive = true
        boxVisualization?.updateActionMode(.editing)
        if labelBillboard?.isUnified == true {
            labelBillboard?.updateActionIcons(ActionIconBuilder.activeEditActions)
        }
    }

    func stopEditing() {
        isEditing = false
        isDragging = false
        boxVisualization?.isInteractive = false
        boxVisualization?.updateActionMode(.normal)
        if labelBillboard?.isUnified == true {
            let actions = refinementCount >= AppConstants.maxRefinementRounds
                ? ActionIconBuilder.labelUnifiedNoRefineActions
                : ActionIconBuilder.labelUnifiedActions
            labelBillboard?.updateActionIcons(actions)
        }
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
            if isRefining { cancelRefinement() } else { discardMeasurement() }
        case .reEdit:
            reEditCompletedBox()
        case .delete:
            deleteCompletedBox()
        case .refine:
            startRefinementMode()
        case .labelDone:
            dismissLabelResult()
        case .labelRescan:
            resetLabelScan()
        }
    }

    // MARK: - Refinement

    private func startRefinementMode() {
        guard let result = currentMeasurement else { return }

        // Save original axis mapping and floor on first refinement
        if originalAxisMapping == nil {
            originalAxisMapping = result.axisMapping
        }
        if originalFloorY == nil {
            originalFloorY = boxVisualization?.floorY
        }

        // Seed accumulated point clouds with current data
        if accumulatedPointClouds.isEmpty, let pc = storedPointCloud {
            accumulatedPointClouds = [pc]
            accumulatedQualities = [result.quality]
        }

        isRefining = true
        boxVisualization?.updateActionMode(.refining)
        if labelBillboard?.isUnified == true {
            labelBillboard?.updateActionIcons(ActionIconBuilder.activeRefiningActions)
        }
        print("[Refine] Entered refinement mode (round \(refinementCount + 1))")
    }

    private func cancelRefinement() {
        isRefining = false
        let mode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
            ? .normalNoRefine : .normal
        boxVisualization?.updateActionMode(mode)
        if labelBillboard?.isUnified == true {
            let actions = refinementCount >= AppConstants.maxRefinementRounds
                ? ActionIconBuilder.labelUnifiedNoRefineActions
                : ActionIconBuilder.labelUnifiedActions
            labelBillboard?.updateActionIcons(actions)
        }
        print("[Refine] Cancelled refinement mode")
    }

    /// Clear pending first-tap state
    private func clearPendingFirstTap() {
        pendingFirstTapResult = nil
        pendingFirstTapFloorY = nil
        hasPendingFirstTap = false
    }

    func handleRefinementTap(at location: CGPoint, mode: MeasurementMode) async {
        guard let result = currentMeasurement,
              let frame = sessionManager.currentFrame else { return }
        guard !isProcessing else { return }

        isProcessing = true
        let viewSize = sessionManager.arView.bounds.size
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)

        do {
            if let refinement = try await measurementCalculator.measureForRefinement(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize,
                mode: mode,
                existingBox: result.boundingBox,
                raycastHitPosition: raycastHitPosition
            ) {
                // Success: merge point clouds and re-estimate
                accumulatedPointClouds.append(refinement.points)
                accumulatedQualities.append(refinement.quality)
                refinementCount += 1

                let mergedPoints = accumulatedPointClouds.flatMap { $0 }
                let mergedQuality = MeasurementQuality.merged(accumulatedQualities)

                // Re-estimate bounding box from merged points
                let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                    guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                    return plane
                }

                guard let newBox = BoundingBoxEstimator().estimateBoundingBox(
                    points: mergedPoints, mode: mode, verticalPlaneAnchors: verticalPlanes
                ) else {
                    print("[Refine] Re-estimation failed")
                    isProcessing = false
                    return
                }

                // Apply floor extension
                var adjustedBox = newBox
                if let floorY = originalFloorY {
                    adjustedBox.extendBottomToFloor(floorY: floorY, threshold: 0.05)
                }

                // Recalculate with original axis mapping
                let mapping = originalAxisMapping ?? result.axisMapping
                var newResult = measurementCalculator.recalculate(
                    boundingBox: adjustedBox, quality: mergedQuality, axisMapping: mapping
                )
                newResult.pointCloud = mergedPoints
                currentMeasurement = newResult
                storedPointCloud = mergedPoints

                // Update visualization
                boxVisualization?.update(boundingBox: adjustedBox)
                boxVisualization?.updateDimensions(
                    height: newResult.height, length: newResult.length, width: newResult.width
                )

                // Exit refinement mode
                isRefining = false
                let actionMode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                    ? .normalNoRefine : .normal
                boxVisualization?.updateActionMode(actionMode)

                print("[Refine] Refinement \(refinementCount) complete. Dimensions: L=\(newResult.length*100)cm W=\(newResult.width*100)cm H=\(newResult.height*100)cm")
            } else {
                print("[Refine] Object not matched – stay in refinement mode")
                // Could show a transient message here in the future
            }
        } catch {
            print("[Refine] Error: \(error)")
        }

        isProcessing = false
    }

    // MARK: - Label Reader

    func handleLabelTap(at location: CGPoint) async {
        guard !isProcessing, !isReadingLabel else {
            print("[LabelReader] Already processing, ignoring tap")
            return
        }

        guard let frame = sessionManager.currentFrame else {
            print("[LabelReader] No current frame")
            return
        }

        isReadingLabel = true
        isProcessing = true

        let viewSize = sessionManager.arView.bounds.size

        do {
            guard let result = try await labelReaderService.detectAndReadLabel(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize
            ) else {
                print("[LabelReader] No label detected near tap point")
                isProcessing = false
                isReadingLabel = false
                return
            }

            print("[LabelReader] Label detected, starting lift animation")

            // Refine world corners with raycast on main thread (more accurate than depth map)
            let refinedCorners: [SIMD3<Float>]? = {
                guard let quad = result.worldCorners, quad.count == 4 else { return result.worldCorners }
                let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
                let visionCorners = [
                    result.quadrilateral.topLeft,
                    result.quadrilateral.topRight,
                    result.quadrilateral.bottomRight,
                    result.quadrilateral.bottomLeft
                ]
                var corners: [SIMD3<Float>] = []
                for vc in visionCorners {
                    // Vision (.right) → normalized image coords → screen coords
                    let imageNorm = CGPoint(x: CGFloat(vc.y), y: 1.0 - CGFloat(vc.x))
                    let screenNorm = imageNorm.applying(displayTransform)
                    let screenPoint = CGPoint(x: screenNorm.x * viewSize.width, y: screenNorm.y * viewSize.height)
                    let hits = sessionManager.arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
                    if let hit = hits.first {
                        let pos = hit.worldTransform.columns.3
                        corners.append(SIMD3<Float>(pos.x, pos.y, pos.z))
                    } else {
                        print("[LabelReader] Raycast miss, using depth map corners")
                        return result.worldCorners
                    }
                }
                print("[LabelReader] World corners refined by raycast")
                return corners
            }()

            // Create lift animation
            let liftAnim = LabelLiftAnimation()
            let raycastPos = sessionManager.raycastWorldPosition(from: location)
            liftAnim.setup(
                labelImage: result.correctedImage,
                worldCorners: refinedCorners,
                surfaceNormal: result.surfaceNormal,
                cameraTransform: frame.camera.transform,
                fallbackPosition: raycastPos
            )

            labelLiftAnimation = liftAnim
            labelLiftAnchor = sessionManager.addEntityWithAnchor(liftAnim.entity)

            // Animate
            let cameraTransform = frame.camera.transform
            liftAnim.animate(cameraTransform: cameraTransform) { [weak self] in
                guard let self = self else { return }

                // Lift complete - hide 3D, show 2D image, start barcode scan effect
                self.currentLabelData = result.labelData
                self.correctedLabelImageSize = result.correctedImage.size
                self.correctedLabelImage = result.correctedImage
                self.labelLiftAnimation?.setVisible(false)
                self.isProcessing = false
                self.showBarcodeScanEffect = true
            }
        } catch {
            print("[LabelReader] Error: \(error)")
            isProcessing = false
            isReadingLabel = false
        }
    }

    func barcodeScanEffectCompleted() {
        showBarcodeScanEffect = false
        correctedLabelImage = nil
        isReadingLabel = false

        // Advance workflow to showingLabelResult
        if workflowStep == .awaitingLabelScan {
            workflowStep = .showingLabelResult
        }

        // Try to create AR billboard above the real label
        guard let labelData = currentLabelData,
              let liftAnim = labelLiftAnimation else {
            // Fallback to 2D overlay if we can't create billboard
            showLabelResult2D()
            return
        }

        // Show the lifted label again so it can transition back
        liftAnim.setVisible(true)

        // Create billboard at label's original position + offset above surface
        let billboardPosition = liftAnim.originalCenter + liftAnim.originalSurfaceNormal * 0.06
        let billboard = LabelBillboard(
            labelData: labelData,
            worldPosition: billboardPosition,
            surfaceNormal: liftAnim.originalSurfaceNormal
        )
        labelBillboard = billboard

        // Add billboard to AR scene (hidden initially, reveal starts after overlap)
        let anchor = sessionManager.addEntityWithAnchor(billboard.entity)
        labelBillboardAnchor = anchor
        billboard.setVisible(false)

        showLabelBillboard = true

        // Phase A: Label shrinks back toward original position (0–0.8s)
        liftAnim.transitionToOrigin { [weak self] in
            guard let self = self else { return }
            // Label transition complete — remove lift animation
            if let liftAnchor = self.labelLiftAnchor {
                self.sessionManager.removeAnchor(liftAnchor)
            }
            self.labelLiftAnchor = nil
            self.labelLiftAnimation = nil
        }

        // Phase B: Billboard appears at 0.3s overlap (while label still shrinking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.showLabelBillboard else { return }
            billboard.setVisible(true)
            billboard.startRevealAnimation { [weak self] in
                guard let self = self else { return }
                // Store label data and advance workflow — no Done button needed
                self.pendingLabelData = self.currentLabelData
                if self.workflowStep == .showingLabelResult {
                    self.workflowStep = .awaitingSecondTap
                }
            }
        }
    }

    /// Fallback: show 2D SwiftUI overlay if billboard creation fails
    private func showLabelResult2D() {
        labelLiftAnimation?.setVisible(true)

        let fields = currentLabelData?.displayFields ?? []
        labelLineRevealed = Array(repeating: false, count: max(fields.count, 1))
        showLabelResult = true
        labelReadingComplete = false

        Task { [weak self] in
            guard let self = self else { return }
            let count = max(fields.count, 1)
            let stagger = PMTheme.labelTypingStagger

            for i in 0..<count {
                try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                guard self.showLabelResult else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    if i < self.labelLineRevealed.count {
                        self.labelLineRevealed[i] = true
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                self.labelReadingComplete = true
            }
        }
    }

    func dismissLabelResult() {
        showLabelResult = false
        correctedLabelImage = nil

        // Store label data for next measurement
        pendingLabelData = currentLabelData

        // Dismiss AR billboard if showing
        if showLabelBillboard, let billboard = labelBillboard {
            showLabelBillboard = false
            billboard.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelBillboardAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelBillboardAnchor = nil
                self.labelBillboard = nil
            }
        }

        // Dismiss lift animation (may already be nil if billboard was used)
        if let liftAnim = labelLiftAnimation {
            liftAnim.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelLiftAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelLiftAnchor = nil
                self.labelLiftAnimation = nil
            }
        }

        // Reset label state
        currentLabelData = nil
        labelLineRevealed = []
        labelReadingComplete = false
        isReadingLabel = false

        // Advance workflow if active
        if isWorkflowActive {
            workflowStep = .awaitingSecondTap
        }
    }

    // MARK: - Workflow Methods

    func resetLabelScan() {
        // Cancel barcode scan effect
        showBarcodeScanEffect = false

        // Dismiss label result
        showLabelResult = false

        // Dismiss AR billboard
        if showLabelBillboard {
            showLabelBillboard = false
            labelBillboard?.entity.isEnabled = false
            if let anchor = labelBillboardAnchor {
                sessionManager.removeAnchor(anchor)
            }
            labelBillboardAnchor = nil
            labelBillboard = nil
        }

        // Dismiss lift animation immediately
        if let liftAnim = labelLiftAnimation {
            liftAnim.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelLiftAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelLiftAnchor = nil
                self.labelLiftAnimation = nil
            }
        }

        // Reset all label state
        currentLabelData = nil
        correctedLabelImage = nil
        correctedLabelImageSize = .zero
        labelLineRevealed = []
        labelReadingComplete = false
        isReadingLabel = false
        isProcessing = false

        // Stay in label mode (ready for next scan)
        if isWorkflowActive {
            workflowStep = .awaitingLabelScan
        }
    }

    func skipLabelScan() {
        workflowStep = .awaitingSecondTap
    }

    func showMeasurementConsole() {
        guard let result = currentMeasurement else { return }

        let unit = currentUnit
        let vol = unit.convertVolume(cubicMeters: result.boundingBox.volume)
        let volWeight = unit.formatVolumetricWeight(cubicMeters: result.boundingBox.volume)
        let sizeClass = SizeClass.classify(volumeCubicMeters: result.boundingBox.volume).rawValue

        // Build console line count (second scan has 3 failed-status WMS lines, first scan has 6)
        let wmsLineCount = calloutBoxId == 2 ? 3 : 6
        var lineCount = wmsLineCount + 6 // WMS lines + 6 dimensions lines
        if let label = pendingLabelData {
            lineCount += label.displayFields.count
        }
        lineCount += 2 // quality section

        consoleLineRevealed = Array(repeating: false, count: lineCount)
        wmsLineStatus = Array(repeating: .pending, count: wmsLineCount)
        consoleReadingComplete = false
        showConsole = true
        workflowStep = .showingConsole

        // Stagger line reveals with variable delays for WMS progression feel
        Task { [weak self] in
            guard let self = self else { return }
            let stagger = PMTheme.consoleTypingStagger

            let isSizeAlert = self.calloutBoxId == 2
            for i in 0..<lineCount {
                // Variable delay for WMS lines to simulate API call progression
                let delay: Double
                if i < wmsLineCount {
                    if isSizeAlert {
                        // Second scan: quick failed-status reveal (no POST simulation)
                        switch i {
                        case 0: delay = 0.3              // STATUS - brief pause
                        case 1: delay = 0.25             // REASON - quick follow-up
                        case 2: delay = 0.2              // ACTION - quick
                        default: delay = stagger
                        }
                    } else {
                        switch i {
                        case 0: delay = stagger          // CONNECT - normal
                        case 1: delay = 0.3              // REQUEST - brief pause after connect
                        case 2: delay = 0.15             // BODY - quick after request
                        case 3: delay = 0.8              // RESPONSE - simulated API wait
                        case 4: delay = 0.2              // RECEIPT - quick follow-up
                        case 5: delay = 0.5              // PRINT - longer for "Spooling..."
                        default: delay = stagger
                        }
                    }
                } else {
                    delay = stagger
                }

                // WMS status transitions: mark previous completed, current processing
                if i < wmsLineCount {
                    if i > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.wmsLineStatus[i - 1] = .completed
                        }
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.wmsLineStatus[i] = .processing
                    }
                } else if i == wmsLineCount {
                    // First non-WMS line: mark last WMS line as completed
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.wmsLineStatus[wmsLineCount - 1] = .completed
                    }
                }

                // Reveal the line
                guard self.showConsole else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    if i < self.consoleLineRevealed.count {
                        self.consoleLineRevealed[i] = true
                    }
                }

                // Wait after reveal so spinner is visible
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.showConsole else { return }
            }

            // Ensure all WMS lines are completed
            withAnimation(.easeOut(duration: 0.15)) {
                for i in 0..<wmsLineCount {
                    self.wmsLineStatus[i] = .completed
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                self.consoleReadingComplete = true
            }
        }
    }

    func showCSVExport() {
        guard let result = currentMeasurement else { return }

        csvString = exportService.generateSingleRowCSV(
            length: result.length,
            width: result.width,
            height: result.height,
            volumeCubicMeters: result.boundingBox.volume,
            quality: result.quality,
            mode: currentMeasurementMode,
            labelData: pendingLabelData,
            unit: currentUnit
        )

        showConsole = false
        showCSVDisplay = true
        workflowStep = .showingCSV
    }

    func closeWorkflow() {
        // Save measurement
        saveMeasurement(mode: currentMeasurementMode, unit: currentUnit)

        // Reset workflow
        showConsole = false
        showCSVDisplay = false
        consoleLineRevealed = []
        consoleReadingComplete = false
        wmsLineStatus = []
        csvString = ""
        workflowStep = .idle
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
                // Also check if it belongs to the attached label billboard
                if let labelBB = viz.attachedLabelBillboard, node === labelBB.entity {
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
            // Transfer current active billboard to newly completed viz
            if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
               let lastViz = completedBoxVisualizations.last {
                lastViz.attachLabelBillboard(billboard, anchor: anchor)
                labelBillboard = nil
                labelBillboardAnchor = nil
                showLabelBillboard = false
            }
            clearActiveBoxOnly()
        }

        // Transfer label billboard back to ViewModel if attached
        if let (billboard, bbAnchor) = completedViz.detachLabelBillboard() {
            labelBillboard = billboard
            labelBillboardAnchor = bbAnchor
            showLabelBillboard = true
            // Restore active unified action icons
            billboard.updateActionIcons(ActionIconBuilder.labelUnifiedActions)
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

        // Clean up attached label billboard if any
        completedBoxVisualizations[index].removeAttachedLabelBillboard()

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
                boxId: nextBoxId,
                qualityLabel: result.quality.overallQuality.rawValue.capitalized,
                pointCount: result.quality.pointCount,
                labelData: pendingLabelData
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

    private func formatCalloutValue(_ meters: Float, unit: MeasurementUnit) -> String {
        let value = unit.convert(meters: meters)
        let numStr: String
        if value >= 100 {
            numStr = String(format: "%.0f", value)
        } else if value >= 10 {
            numStr = String(format: "%.1f", value)
        } else {
            numStr = String(format: "%.2f", value)
        }
        return "\(numStr) \(unit.rawValue)"
    }

    /// Reset all callout-related state
    private func resetCalloutState() {
        showDimensionCallout = false
        calloutLineRevealed = [false, false, false, false]
        calloutTransitionProgress = 0.0
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

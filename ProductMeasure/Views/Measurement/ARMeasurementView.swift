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
    @AppStorage("appMode") private var appMode: AppMode = .warehouse
    @AppStorage("measurementMode") private var measurementMode: MeasurementMode = .boxPriority
    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @AppStorage("selectionMode2") private var selectionMode: SelectionMode = .tap
    @AppStorage("showScanningTips") private var showScanningTips = true
    #if DEBUG
    @AppStorage("showMaskPreview") private var showMaskPreview = false
    #endif
    @State private var showScanningTipsSheet = false

    /// When workflow is active or in label-only mode, derives selection mode from ViewModel
    private var activeSelectionMode: SelectionMode {
        if appMode == .labelOnly { return .label }
        return viewModel.isWorkflowActive ? viewModel.effectiveSelectionMode : selectionMode
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
                            screenSize: geometry.size,
                            stabilityLevel: viewModel.stabilityLevel
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
                        // Top bar
                        HStack {
                            if showScanningTips && !viewModel.isWorkflowActive {
                                Button(action: { showScanningTipsSheet = true }) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(PMTheme.cyan)
                                        .frame(width: 36, height: 36)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5))
                                }
                            }

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

                        // Action button when workflow reaches showingResult
                        if viewModel.workflowStep == .showingResult {
                            if appMode == .shipping || appMode == .measure {
                                Button(action: {
                                    viewModel.resetForNewMeasurement()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 14))
                                        Text("NEW")
                                            .font(PMTheme.mono(14, weight: .bold))
                                    }
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                                    .background(PMTheme.green)
                                    .clipShape(Capsule())
                                    .shadow(color: PMTheme.green.opacity(0.4), radius: 8, x: 0, y: 2)
                                }
                            } else if appMode == .labelOnly {
                                Button(action: {
                                    viewModel.resetForNewLabelScan()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 14))
                                        Text("NEW")
                                            .font(PMTheme.mono(14, weight: .bold))
                                    }
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                                    .background(PMTheme.green)
                                    .clipShape(Capsule())
                                    .shadow(color: PMTheme.green.opacity(0.4), radius: 8, x: 0, y: 2)
                                }
                            } else {
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
                                if activeSelectionMode == .tap && (viewModel.animationPhase == .showingTargetBrackets || viewModel.hasPendingFirstTap) {
                                    InstructionCard(mode: .tap)
                                } else if activeSelectionMode == .box {
                                    InstructionCard(mode: .box)
                                } else if activeSelectionMode == .label {
                                    InstructionCard(mode: .label)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentMeasurement != nil)
                .animation(.easeInOut(duration: 0.3), value: viewModel.workflowStep)
                #if DEBUG
                .sheet(isPresented: $viewModel.showDebugMask) {
                    if let image = viewModel.debugMaskImage {
                        DebugMaskCompareView(
                            image1: image,
                            image2: viewModel.debugMaskImage2
                        )
                    }
                }
                .sheet(isPresented: $viewModel.showDebugDepth) {
                    if let image = viewModel.debugDepthImage {
                        DebugImageView(image: image, title: "Depth Map (Bright=Close) + Masked Pixels (Green)")
                    }
                }
                #endif
                .sheet(isPresented: $showScanningTipsSheet) {
                    ScanningTipsView()
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
                                if !viewModel.isWorkflowActive && appMode != .labelOnly {
                                    selectionMode = .tap
                                }
                            },
                            onRescan: {
                                viewModel.resetLabelScan()
                            },
                            dismissButtonLabel: (viewModel.isWorkflowActive && appMode != .labelOnly) ? "CONTINUE" : "DONE"
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
                        width: unit.formatDimension(meters: result.width),
                        height: unit.formatDimension(meters: result.height),
                        length: unit.formatDimension(meters: result.length),
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
            viewModel.appMode = appMode
            #if DEBUG
            viewModel.showMaskPreviewSetting = showMaskPreview
            #endif
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
        .onChange(of: appMode) { _, newMode in
            viewModel.appMode = newMode
        }
        #if DEBUG
        .onChange(of: showMaskPreview) { _, newValue in
            viewModel.showMaskPreviewSetting = newValue
        }
        #endif
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
#if DEBUG
            print("[Tap] Location: \(location)")
#endif

            // Hit test for 3D entities first
            let results = arView.hitTest(location, query: .nearest, mask: .all)

            for result in results {
                var entity: Entity? = result.entity
                while let current = entity {
                    // 1. Check for action icon tap
                    if ActionIconBuilder.isActionEntity(current.name),
                       let actionType = ActionIconBuilder.parseActionType(entityName: current.name) {
#if DEBUG
                        print("[Tap] Action icon tapped: \(actionType)")
#endif
                        viewModel.handleActionTap(actionType, mode: measurementMode)
                        return
                    }

                    // 2. Check for completed billboard background tap
                    if current.name == "completed_billboard_bg" {
                        // Find which completed box this belongs to
                        if let boxId = viewModel.findCompletedBoxId(for: current) {
#if DEBUG
                            print("[Tap] Completed billboard tapped, boxId: \(boxId)")
#endif
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
            let effectiveMode = (viewModel.appMode == .labelOnly || viewModel.isWorkflowActive) ? viewModel.effectiveSelectionMode : selectionMode
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
#if DEBUG
                        print("[Pan] Started editing drag: \(dragType)")
#endif
                    }
                } else if selectionMode == .box && !viewModel.isProcessing {
                    // Box selection mode: start drawing selection rectangle
                    activeDragType = .boxSelection(startPoint: location)
                    boxSelectionRectView?.clearSelection()
#if DEBUG
                    print("[Pan] Started box selection at: \(location)")
#endif
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
#if DEBUG
                    print("[Pan] Ended editing drag")
#endif
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
#if DEBUG
                        print("[Pan] Box selection completed: \(rect)")
#endif
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

#Preview {
    ARMeasurementView()
}

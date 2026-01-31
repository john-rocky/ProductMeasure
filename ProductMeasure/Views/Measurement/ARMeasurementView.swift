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

    var body: some View {
        ZStack {
            // AR Camera View
            if LiDARChecker.isLiDARAvailable {
                ARMeasurementViewRepresentable(viewModel: viewModel, measurementMode: measurementMode)
                    .ignoresSafeArea()

                // Overlay UI
                VStack {
                    // Top status bar
                    HStack {
                        StatusBar(
                            trackingMessage: viewModel.trackingMessage,
                            isProcessing: viewModel.isProcessing
                        )

                        Spacer()

                        // Debug buttons
                        if viewModel.currentMeasurement != nil {
                            HStack(spacing: 8) {
                                Button("Mask") {
                                    viewModel.toggleDebugMask()
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)

                                Button("Depth") {
                                    viewModel.toggleDebugDepth()
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                            }
                            .font(.caption)
                        }
                    }

                    Spacer()

                    // Measurement result card
                    if let result = viewModel.currentMeasurement {
                        MeasurementResultCard(
                            result: result,
                            unit: measurementUnit,
                            onSave: {
                                viewModel.saveMeasurement(mode: measurementMode)
                            },
                            onEdit: {
                                viewModel.startEditing()
                            },
                            onDiscard: {
                                viewModel.discardMeasurement()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Instruction text when no measurement
                    if viewModel.currentMeasurement == nil && !viewModel.isProcessing {
                        InstructionCard()
                    }
                }
                .padding()
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
        }
        .onDisappear {
            viewModel.pauseSession()
        }
    }
}

// MARK: - AR View Representable with Tap Handling

struct ARMeasurementViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: ARMeasurementViewModel
    let measurementMode: MeasurementMode

    func makeUIView(context: Context) -> ARView {
        let arView = viewModel.sessionManager.arView!

        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.measurementMode = measurementMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, measurementMode: measurementMode)
    }

    class Coordinator: NSObject {
        let viewModel: ARMeasurementViewModel
        var measurementMode: MeasurementMode

        init(viewModel: ARMeasurementViewModel, measurementMode: MeasurementMode) {
            self.viewModel = viewModel
            self.measurementMode = measurementMode
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let location = gesture.location(in: gesture.view)
            print("[Tap] Location: \(location)")

            Task { @MainActor in
                await viewModel.handleTap(at: location, mode: measurementMode)
            }
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
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.title)
            Text("Tap on an object to measure")
                .font(.headline)
            Text("Point your device at an object and tap to measure its dimensions")
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
    let onSave: () -> Void
    let onEdit: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Quality indicator
            HStack {
                QualityIndicator(quality: result.quality.overallQuality)
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

            // Action buttons
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
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    // Debug visualization
    @Published var showDebugMask = false
    @Published var showDebugDepth = false
    @Published var debugMaskImage: UIImage?
    @Published var debugDepthImage: UIImage?

    let sessionManager = ARSessionManager()
    private let measurementCalculator = MeasurementCalculator()
    private var boxVisualization: BoxVisualization?
    private var pointCloudEntity: Entity?

    init() {
        sessionManager.$trackingStateMessage
            .assign(to: &$trackingMessage)
    }

    func startSession() {
        sessionManager.startSession()
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
        currentMeasurement = nil
        debugMaskImage = nil
        debugDepthImage = nil

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
                currentMeasurement = result

                // Store debug images (only if available)
                debugMaskImage = result.debugMaskImage
                debugDepthImage = result.debugDepthImage

                // Show bounding box visualization
                showBoxVisualization(for: result.boundingBox)
            } else {
                print("[ViewModel] Measurement returned nil")
            }
        } catch {
            print("[ViewModel] Measurement failed with error: \(error)")
        }

        isProcessing = false
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
        // Enable box editing handles
    }

    func discardMeasurement() {
        currentMeasurement = nil
        isEditing = false
        debugMaskImage = nil
        debugDepthImage = nil
        removeAllVisualizations()
    }

    func toggleDebugMask() {
        showDebugMask.toggle()
    }

    func toggleDebugDepth() {
        showDebugDepth.toggle()
    }

    private func showBoxVisualization(for box: BoundingBox3D) {
        boxVisualization = BoxVisualization(boundingBox: box)
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

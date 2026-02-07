//
//  ScanningLineView.swift
//  ProductMeasure
//

import SwiftUI
import ARKit
import RealityKit

/// A neon green vertical line that sweeps left→right across the screen.
/// Uses LiDAR depth data to deform the line along real surface contours,
/// producing a structured-light scanner effect.
struct ScanningLineView: View {
    weak var arView: ARView?
    var currentFrame: ARFrame?

    @State private var startDate = Date()
    @State private var previousDisplacements: [(CGFloat, CGFloat)] = []

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let progress = CGFloat(elapsed.truncatingRemainder(dividingBy: PMTheme.scanLineDuration) / PMTheme.scanLineDuration)

            Canvas { context, size in
                let lineX = progress * size.width

                // Draw translucent trail behind the line
                let trailGradient = Gradient(stops: [
                    .init(color: Color(hex: 0x39FF14).opacity(0.0), location: 0.0),
                    .init(color: Color(hex: 0x39FF14).opacity(0.06), location: 0.8),
                    .init(color: Color(hex: 0x39FF14).opacity(0.12), location: 1.0),
                ])
                let trailRect = CGRect(x: 0, y: 0, width: lineX, height: size.height)
                context.fill(
                    Path(trailRect),
                    with: .linearGradient(trailGradient, startPoint: .zero, endPoint: CGPoint(x: lineX, y: 0))
                )

                // Sample depth and compute contour displacements
                let displacements = computeContourDisplacements(lineX: lineX, screenSize: size)

                // Build contour path
                let linePath = buildContourPath(lineX: lineX, displacements: displacements, screenSize: size)

                // Outer glow layer
                context.stroke(
                    linePath,
                    with: .color(Color(hex: 0x39FF14).opacity(0.35)),
                    style: StrokeStyle(lineWidth: PMTheme.scanLineWidth + 6, lineCap: .round)
                )
                context.addFilter(.blur(radius: PMTheme.scanLineGlowRadius))

                // Bright inner line
                context.stroke(
                    linePath,
                    with: .color(Color(hex: 0x39FF14).opacity(0.9)),
                    style: StrokeStyle(lineWidth: PMTheme.scanLineWidth, lineCap: .round)
                )
            }
        }
    }

    // MARK: - Depth Sampling

    /// Sample depth values along a vertical screen column at the given lineX.
    private func sampleDepthColumn(lineX: CGFloat, screenSize: CGSize, frame: ARFrame) -> [(screenY: CGFloat, depth: Float)] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return []
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Portrait mode coordinate mapping:
        // depthY = (1 - screenX / screenWidth) * depthHeight  (fixed for this column)
        // depthX = (screenY / screenHeight) * depthWidth       (sweeps along column)
        let depthY = Int((1.0 - lineX / screenSize.width) * CGFloat(depthHeight))
        let clampedDepthY = max(0, min(depthHeight - 1, depthY))

        let sampleCount = PMTheme.scanLineDepthSampleCount
        var samples: [(screenY: CGFloat, depth: Float)] = []
        samples.reserveCapacity(sampleCount)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        for i in 0..<sampleCount {
            let screenY = CGFloat(i) / CGFloat(sampleCount - 1) * screenSize.height
            let depthX = Int((screenY / screenSize.height) * CGFloat(depthWidth))
            let clampedDepthX = max(0, min(depthWidth - 1, depthX))

            let rowPtr = baseAddress.advanced(by: clampedDepthY * bytesPerRow)
            let depthValue = rowPtr.assumingMemoryBound(to: Float32.self)[clampedDepthX]

            if depthValue.isFinite && depthValue > 0 && depthValue < PMTheme.scanLineMaxDepth {
                samples.append((screenY: screenY, depth: depthValue))
            }
        }

        return samples
    }

    // MARK: - Displacement Computation

    /// Convert depth samples to horizontal displacements.
    /// Closer surfaces push the line outward (positive dx), farther surfaces pull inward.
    private func computeDisplacements(samples: [(screenY: CGFloat, depth: Float)], screenSize: CGSize) -> [(screenY: CGFloat, dx: CGFloat)] {
        guard !samples.isEmpty else { return [] }

        // Compute median depth as reference
        let sortedDepths = samples.map(\.depth).sorted()
        let medianDepth = sortedDepths[sortedDepths.count / 2]

        let scale = PMTheme.scanLineDepthDisplacementScale
        let maxDisp = PMTheme.scanLineMaxDisplacement

        var displacements: [(screenY: CGFloat, dx: CGFloat)] = []
        displacements.reserveCapacity(samples.count)

        for sample in samples {
            var dx = CGFloat(medianDepth - sample.depth) * scale * screenSize.width
            dx = max(-maxDisp, min(maxDisp, dx))
            displacements.append((screenY: sample.screenY, dx: dx))
        }

        return displacements
    }

    /// Fill gaps from missing depth samples by linear interpolation to produce
    /// uniformly spaced displacement values across the full screen height.
    private func interpolateDisplacements(_ sparse: [(screenY: CGFloat, dx: CGFloat)], screenSize: CGSize) -> [(screenY: CGFloat, dx: CGFloat)] {
        let sampleCount = PMTheme.scanLineDepthSampleCount
        guard sparse.count >= 2 else {
            // Not enough data — return zero displacements
            return (0..<sampleCount).map { i in
                let y = CGFloat(i) / CGFloat(sampleCount - 1) * screenSize.height
                return (screenY: y, dx: 0)
            }
        }

        var result: [(screenY: CGFloat, dx: CGFloat)] = []
        result.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let y = CGFloat(i) / CGFloat(sampleCount - 1) * screenSize.height

            // Find surrounding sparse samples
            if let exactMatch = sparse.first(where: { abs($0.screenY - y) < 1.0 }) {
                result.append((screenY: y, dx: exactMatch.dx))
            } else if let lower = sparse.last(where: { $0.screenY <= y }),
                      let upper = sparse.first(where: { $0.screenY > y }) {
                let t = (y - lower.screenY) / max(1, upper.screenY - lower.screenY)
                let dx = lower.dx + (upper.dx - lower.dx) * t
                result.append((screenY: y, dx: dx))
            } else if let nearest = sparse.min(by: { abs($0.screenY - y) < abs($1.screenY - y) }) {
                result.append((screenY: y, dx: nearest.dx))
            } else {
                result.append((screenY: y, dx: 0))
            }
        }

        return result
    }

    // MARK: - Smoothing

    /// Apply spatial moving average to smooth out noise.
    private func applySpatialSmoothing(_ displacements: [(screenY: CGFloat, dx: CGFloat)]) -> [(screenY: CGFloat, dx: CGFloat)] {
        let window = PMTheme.scanLineSpatialSmoothWindow
        guard displacements.count > window else { return displacements }

        let halfWindow = window / 2
        return displacements.enumerated().map { i, item in
            let start = max(0, i - halfWindow)
            let end = min(displacements.count - 1, i + halfWindow)
            let sum = (start...end).reduce(CGFloat(0)) { $0 + displacements[$1].dx }
            let avg = sum / CGFloat(end - start + 1)
            return (screenY: item.screenY, dx: avg)
        }
    }

    /// Blend current displacements with previous frame for temporal stability.
    private func applyTemporalSmoothing(_ current: [(screenY: CGFloat, dx: CGFloat)]) -> [(screenY: CGFloat, dx: CGFloat)] {
        let blend = PMTheme.scanLineTemporalBlend
        guard !previousDisplacements.isEmpty, previousDisplacements.count == current.count else {
            return current
        }

        return current.enumerated().map { i, item in
            let prevDx = previousDisplacements[i].1
            let blendedDx = item.dx * (1 - blend) + prevDx * blend
            return (screenY: item.screenY, dx: blendedDx)
        }
    }

    // MARK: - Pipeline

    /// Full pipeline: sample depth → compute displacements → interpolate → smooth.
    private func computeContourDisplacements(lineX: CGFloat, screenSize: CGSize) -> [(screenY: CGFloat, dx: CGFloat)] {
        guard let frame = currentFrame else {
            // No depth data — return empty (straight line fallback)
            return []
        }

        let samples = sampleDepthColumn(lineX: lineX, screenSize: screenSize, frame: frame)
        guard !samples.isEmpty else { return [] }

        let rawDisplacements = computeDisplacements(samples: samples, screenSize: screenSize)
        let interpolated = interpolateDisplacements(rawDisplacements, screenSize: screenSize)
        let spatialSmoothed = applySpatialSmoothing(interpolated)
        let temporalSmoothed = applyTemporalSmoothing(spatialSmoothed)

        // Store for next frame's temporal blend
        DispatchQueue.main.async {
            previousDisplacements = temporalSmoothed.map { ($0.screenY, $0.dx) }
        }

        return temporalSmoothed
    }

    // MARK: - Path Building

    /// Build a smooth contour path from bottom to top using Catmull-Rom–style quad curves.
    private func buildContourPath(lineX: CGFloat, displacements: [(screenY: CGFloat, dx: CGFloat)], screenSize: CGSize) -> Path {
        var path = Path()

        if displacements.isEmpty {
            // Fallback: straight vertical line
            path.move(to: CGPoint(x: lineX, y: screenSize.height))
            path.addLine(to: CGPoint(x: lineX, y: 0))
            return path
        }

        // Build points from bottom to top
        let points = displacements.reversed().map { item in
            CGPoint(x: lineX + item.dx, y: item.screenY)
        }

        guard let first = points.first else {
            path.move(to: CGPoint(x: lineX, y: screenSize.height))
            path.addLine(to: CGPoint(x: lineX, y: 0))
            return path
        }

        // Extend to bottom edge
        path.move(to: CGPoint(x: lineX, y: screenSize.height))
        path.addLine(to: first)

        // Connect points with quad curves for smoothness
        if points.count >= 3 {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) / 2,
                    y: (points[i].y + points[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[i])
            }
            // Final segment to last point
            if let last = points.last {
                path.addLine(to: last)
            }
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        // Extend to top edge
        path.addLine(to: CGPoint(x: lineX, y: 0))

        return path
    }
}

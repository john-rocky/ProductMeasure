//
//  ScanningLineView.swift
//  ProductMeasure
//

import SwiftUI
import RealityKit

/// A neon green vertical line that sweeps left→right across the screen.
/// When it passes over the projected bounding box, the line rises up in a hump shape.
struct ScanningLineView: View {
    let boundingBox: BoundingBox3D?
    weak var arView: ARView?

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let progress = CGFloat(elapsed.truncatingRemainder(dividingBy: PMTheme.scanLineDuration) / PMTheme.scanLineDuration)

            Canvas { context, size in
                let lineX = progress * size.width

                // Project bounding box corners to get 2D rect
                let projectedRect = projectBoundingBox(screenSize: size)

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

                // Build the scan line path with optional hump over the object
                let linePath = buildScanLinePath(
                    lineX: lineX,
                    screenSize: size,
                    projectedRect: projectedRect
                )

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

    /// Project the bounding box's 8 corners to screen and return the enclosing 2D rect.
    private func projectBoundingBox(screenSize: CGSize) -> CGRect? {
        guard let box = boundingBox, let arView = arView else { return nil }

        let worldCorners = box.corners
        var screenPoints: [CGPoint] = []

        for corner in worldCorners {
            if let projected = arView.project(corner) {
                screenPoints.append(projected)
            }
        }

        guard screenPoints.count >= 4 else { return nil }

        let xs = screenPoints.map(\.x)
        let ys = screenPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Sanity check: rect should be within screen bounds (with some margin)
        guard rect.width > 10, rect.height > 10,
              rect.minX < screenSize.width + 100,
              rect.maxX > -100 else { return nil }

        return rect
    }

    /// Build the vertical scan line path. When lineX is within the projected rect,
    /// deform the top of the line upward using a sine hump.
    private func buildScanLinePath(lineX: CGFloat, screenSize: CGSize, projectedRect: CGRect?) -> Path {
        var path = Path()

        if let rect = projectedRect,
           lineX >= rect.minX, lineX <= rect.maxX {
            // Line is over the object — create a hump
            let localProgress = (lineX - rect.minX) / rect.width
            let humpHeight = rect.height * sin(.pi * localProgress)

            // Line goes from bottom of screen up to (rect.minY - humpHeight)
            let topY = max(0, rect.minY - humpHeight * 0.3)

            path.move(to: CGPoint(x: lineX, y: screenSize.height))
            path.addLine(to: CGPoint(x: lineX, y: topY))
        } else {
            // Normal straight vertical line
            path.move(to: CGPoint(x: lineX, y: screenSize.height))
            path.addLine(to: CGPoint(x: lineX, y: 0))
        }

        return path
    }
}

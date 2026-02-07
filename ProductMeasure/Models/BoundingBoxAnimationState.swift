//
//  BoundingBoxAnimationState.swift
//  ProductMeasure
//

import Foundation
import CoreGraphics
import simd

/// Animation phases for the bounding box appearance animation
enum BoundingBoxAnimationPhase: Equatable {
    /// Showing 2D target brackets - waiting for user tap
    case showingTargetBrackets

    /// Scanning — first tap captured, scan line animating, waiting for second tap
    case scanning

    /// Scan line sweeps once, face panels glow behind it
    case scanReveal

    /// Face panels pulse 2 times
    case facePulse

    /// Center hole opens, light converges to edge wireframes
    case convergeToEdges

    /// Animation complete - box is fully visible
    case complete
}

/// Context information for the bounding box animation after tap
struct BoundingBoxAnimationContext {
    /// Tap point in screen coordinates
    let tapPoint: CGPoint

    /// Target bounding box in 3D world space
    let targetBox: BoundingBox3D

    /// Bottom plane corners projected to screen coordinates
    let bottomCorners: [CGPoint]

    /// Screen size for calculations
    let screenSize: CGSize

    /// Target rectangle size (from projected bottom corners)
    var targetRectSize: CGSize {
        guard bottomCorners.count == 4 else { return CGSize(width: 100, height: 100) }

        let minX = bottomCorners.map { $0.x }.min() ?? 0
        let maxX = bottomCorners.map { $0.x }.max() ?? 100
        let minY = bottomCorners.map { $0.y }.min() ?? 0
        let maxY = bottomCorners.map { $0.y }.max() ?? 100

        return CGSize(width: maxX - minX, height: maxY - minY)
    }

    /// Center of the target rectangle in screen coordinates
    var targetRectCenter: CGPoint {
        guard bottomCorners.count == 4 else { return tapPoint }

        let avgX = bottomCorners.map { $0.x }.reduce(0, +) / 4
        let avgY = bottomCorners.map { $0.y }.reduce(0, +) / 4

        return CGPoint(x: avgX, y: avgY)
    }
}

/// Animation timing constants
struct BoxAnimationTiming {
    /// Duration for scan line single-sweep revealing face panels
    static let scanReveal: Double = PMTheme.scanRevealDuration

    /// Duration for face panel pulse (2 pulses)
    static let facePulse: Double = PMTheme.facePulseDuration

    /// Duration for center hole opening and light converging to edges
    static let convergeToEdges: Double = PMTheme.convergeToEdgesDuration

    /// Total animation duration
    static let total: Double = scanReveal + facePulse + convergeToEdges
}

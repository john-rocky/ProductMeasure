//
//  CornerBracketsView.swift
//  ProductMeasure
//

import SwiftUI
import simd

/// 2D corner brackets overlay - shown as targeting brackets before tap,
/// then animates to match the detected object
struct CornerBracketsView: View {
    let phase: BoundingBoxAnimationPhase
    let context: BoundingBoxAnimationContext?
    let screenSize: CGSize

    // Bracket styling constants
    private let bracketColor: Color = .white
    private let bracketLineWidth: CGFloat = 3
    private let bracketLength: CGFloat = 24

    // Target bracket positioning (inset from screen edges)
    private let targetInset: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let targetSize = CGSize(
                width: geometry.size.width - targetInset * 2,
                height: geometry.size.width - targetInset * 2  // Square target area
            )

            ZStack {
                switch phase {
                case .showingTargetBrackets:
                    // Initial state: brackets at screen edges as targeting guide
                    targetBracketsView(center: center, size: targetSize)
                        .transition(.opacity)

                case .shrinkingToTarget:
                    // Animating: brackets shrink to match detected object
                    if let ctx = context {
                        shrinkingBracketsView(
                            from: (center: center, size: targetSize),
                            to: (center: ctx.targetRectCenter, size: ctx.targetRectSize)
                        )
                    }

                case .transitioningTo3D:
                    // Show rectangle at target position, fading out
                    if let ctx = context {
                        targetRectangleView(center: ctx.targetRectCenter, size: ctx.targetRectSize)
                            .opacity(0.5)
                    }

                case .growingVertical, .complete:
                    // Hide 2D overlay during 3D animation
                    EmptyView()
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Target Brackets (Initial State)

    @ViewBuilder
    private func targetBracketsView(center: CGPoint, size: CGSize) -> some View {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2

        ZStack {
            // Top-left bracket
            BracketShape(corner: .topLeft, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y - halfHeight)

            // Top-right bracket
            BracketShape(corner: .topRight, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y - halfHeight)

            // Bottom-left bracket
            BracketShape(corner: .bottomLeft, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y + halfHeight)

            // Bottom-right bracket
            BracketShape(corner: .bottomRight, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y + halfHeight)
        }
    }

    // MARK: - Shrinking Brackets (Animation)

    @ViewBuilder
    private func shrinkingBracketsView(
        from start: (center: CGPoint, size: CGSize),
        to end: (center: CGPoint, size: CGSize)
    ) -> some View {
        // Clamp the end size to reasonable bounds
        let clampedEndSize = CGSize(
            width: min(max(end.size.width, 50), start.size.width),
            height: min(max(end.size.height, 50), start.size.height)
        )

        let halfWidth = clampedEndSize.width / 2
        let halfHeight = clampedEndSize.height / 2
        let targetCenter = end.center

        ZStack {
            // Top-left bracket
            BracketShape(corner: .topLeft, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: targetCenter.x - halfWidth, y: targetCenter.y - halfHeight)

            // Top-right bracket
            BracketShape(corner: .topRight, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: targetCenter.x + halfWidth, y: targetCenter.y - halfHeight)

            // Bottom-left bracket
            BracketShape(corner: .bottomLeft, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: targetCenter.x - halfWidth, y: targetCenter.y + halfHeight)

            // Bottom-right bracket
            BracketShape(corner: .bottomRight, length: bracketLength)
                .stroke(bracketColor, lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: targetCenter.x + halfWidth, y: targetCenter.y + halfHeight)
        }
        .animation(.easeInOut(duration: BoxAnimationTiming.shrinkToTarget), value: phase)
    }

    // MARK: - Target Rectangle

    @ViewBuilder
    private func targetRectangleView(center: CGPoint, size: CGSize) -> some View {
        let clampedSize = CGSize(
            width: min(max(size.width, 50), 400),
            height: min(max(size.height, 50), 400)
        )

        Rectangle()
            .stroke(bracketColor, lineWidth: bracketLineWidth)
            .frame(width: clampedSize.width, height: clampedSize.height)
            .position(center)
    }
}

// MARK: - Bracket Shape

enum BracketCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct BracketShape: Shape {
    let corner: BracketCorner
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch corner {
        case .topLeft:
            // Horizontal line from left
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))
            // Vertical line down
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: length))

        case .topRight:
            // Horizontal line from right
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width - length, y: 0))
            // Vertical line down
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: length))

        case .bottomLeft:
            // Horizontal line from left
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: length, y: rect.height))
            // Vertical line up
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height - length))

        case .bottomRight:
            // Horizontal line from right
            path.move(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width - length, y: rect.height))
            // Vertical line up
            path.move(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - length))
        }

        return path
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        CornerBracketsView(
            phase: .showingTargetBrackets,
            context: nil,
            screenSize: CGSize(width: 400, height: 800)
        )
    }
}

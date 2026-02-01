//
//  CornerBracketsView.swift
//  ProductMeasure
//

import SwiftUI

/// 2D corner brackets overlay - shown as targeting guide before tap
/// After tap, the 3D animation takes over
struct CornerBracketsView: View {
    let phase: BoundingBoxAnimationPhase
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
                if phase == .showingTargetBrackets {
                    // Show targeting brackets only before tap
                    targetBracketsView(center: center, size: targetSize)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: phase)
        .allowsHitTesting(false)
    }

    // MARK: - Target Brackets

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
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: length))

        case .topRight:
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width - length, y: 0))
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: length))

        case .bottomLeft:
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: length, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height - length))

        case .bottomRight:
            path.move(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width - length, y: rect.height))
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
            screenSize: CGSize(width: 400, height: 800)
        )
    }
}

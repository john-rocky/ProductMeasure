//
//  CornerBracketsView.swift
//  ProductMeasure
//

import SwiftUI

/// 2D corner brackets overlay - shown as targeting guide before tap
struct CornerBracketsView: View {
    let phase: BoundingBoxAnimationPhase
    let screenSize: CGSize

    // Bracket styling
    private let bracketColor: Color = PMTheme.cyan
    private let bracketLineWidth: CGFloat = 3
    private let bracketLength: CGFloat = 24
    private let targetInset: CGFloat = 60

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8
    @State private var diamondRotation: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let targetSize = CGSize(
                width: geometry.size.width - targetInset * 2,
                height: geometry.size.width - targetInset * 2
            )

            ZStack {
                if phase == .showingTargetBrackets {
                    // Scanning crosshair (center)
                    crosshairView(center: center)

                    // Outer dim brackets (offset)
                    targetBracketsView(center: center, size: targetSize, opacity: 0.3, offset: 4)

                    // Inner bright brackets (pulsing)
                    targetBracketsView(center: center, size: targetSize, opacity: pulseOpacity, offset: 0)
                        .scaleEffect(pulseScale, anchor: .center)

                    // Rotating center diamond
                    Diamond()
                        .stroke(PMTheme.cyan.opacity(0.30), lineWidth: 1)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(diamondRotation))
                        .position(x: center.x, y: center.y)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: phase)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.04
                pulseOpacity = 1.0
            }
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                diamondRotation = 360
            }
        }
    }

    // MARK: - Crosshair

    @ViewBuilder
    private func crosshairView(center: CGPoint) -> some View {
        let crossSize: CGFloat = 40
        let dotSize: CGFloat = 4

        ZStack {
            // Horizontal line
            Rectangle()
                .fill(PMTheme.cyan.opacity(0.40))
                .frame(width: crossSize, height: 1)
                .position(x: center.x, y: center.y)

            // Vertical line
            Rectangle()
                .fill(PMTheme.cyan.opacity(0.40))
                .frame(width: 1, height: crossSize)
                .position(x: center.x, y: center.y)

            // Center dot
            Circle()
                .fill(PMTheme.cyan.opacity(0.40))
                .frame(width: dotSize, height: dotSize)
                .position(x: center.x, y: center.y)
        }
    }

    // MARK: - Target Brackets

    @ViewBuilder
    private func targetBracketsView(center: CGPoint, size: CGSize, opacity: Double, offset: CGFloat) -> some View {
        let halfWidth = size.width / 2 + offset
        let halfHeight = size.height / 2 + offset

        ZStack {
            BracketShape(corner: .topLeft, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .topRight, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .bottomLeft, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y + halfHeight)

            BracketShape(corner: .bottomRight, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
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

// MARK: - Diamond Shape

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
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

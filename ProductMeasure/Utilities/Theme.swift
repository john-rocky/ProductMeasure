//
//  Theme.swift
//  ProductMeasure
//
//  Centralized design tokens for the Dark Tech / Holographic Scanner theme
//

import SwiftUI
import UIKit

// MARK: - PMTheme (Design Tokens)

enum PMTheme {

    // MARK: Primary & Accents

    static let cyan       = Color(hex: 0x39FF14)
    static let green      = Color(hex: 0x00E680)
    static let amber      = Color(hex: 0xFFBF00)
    static let red        = Color(hex: 0xFF404D)
    static let blue       = Color(hex: 0x3380FF)

    static let uiCyan     = UIColor(hex: 0x39FF14)
    static let uiGreen    = UIColor(hex: 0x00E680)
    static let uiAmber    = UIColor(hex: 0xFFBF00)
    static let uiRed      = UIColor(hex: 0xFF404D)
    static let uiBlue     = UIColor(hex: 0x3380FF)

    // MARK: Surfaces

    static let surfaceDark     = Color(hex: 0x0F1219)
    static let surfaceCard     = Color(hex: 0x1A1C26)
    static let surfaceElevated = Color(hex: 0x242633)
    static let surfaceGlass    = Color(red: 13/255, green: 18/255, blue: 31/255).opacity(0.85)

    static let uiSurfaceDark   = UIColor(hex: 0x0F1219)
    static let uiSurfaceGlass  = UIColor(red: 13/255, green: 18/255, blue: 31/255, alpha: 0.85)

    // MARK: Text

    static let textPrimary   = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textDimmed    = Color.white.opacity(0.40)

    static let uiTextPrimary   = UIColor(white: 1.0, alpha: 0.95)
    static let uiTextSecondary = UIColor(white: 1.0, alpha: 0.60)

    // MARK: 3D Edge Dimensions

    static let innerEdgeRadius: Float = 0.0005   // 1.0mm diameter -> 0.5mm radius
    static let outerEdgeRadius: Float = 0.0015   // 3.0mm diameter -> 1.5mm radius
    static let cornerMarkerRadius: Float = 0.003 // 6mm diameter sphere
    static let cornerMarkerRadiusSmall: Float = 0.0025 // 5mm for completed

    // MARK: 3D Edge Colors

    /// Active box inner edge: bright cyan, full alpha
    static let uiEdgeInner  = UIColor(hex: 0x39FF14).withAlphaComponent(1.0)
    /// Active box outer glow edge: cyan, low alpha
    static let uiEdgeOuter  = UIColor(hex: 0x39FF14).withAlphaComponent(0.15)
    /// Corner marker: cyan sphere
    static let uiCornerMarker = UIColor(hex: 0x39FF14).withAlphaComponent(0.9)

    /// Completed box inner edge: slightly dimmer
    static let uiEdgeInnerDim  = UIColor(hex: 0x39FF14).withAlphaComponent(0.7)
    static let uiEdgeOuterDim  = UIColor(hex: 0x39FF14).withAlphaComponent(0.10)
    static let uiCornerMarkerDim = UIColor(hex: 0x39FF14).withAlphaComponent(0.6)

    // MARK: Billboard

    static let uiBillboardBg     = UIColor(red: 13/255, green: 18/255, blue: 31/255, alpha: 0.85)
    static let uiBillboardAccent = UIColor(hex: 0x39FF14)
    static let uiBillboardText   = UIColor(white: 1.0, alpha: 0.95)
    static let uiBillboardTopBorder = UIColor(hex: 0x39FF14).withAlphaComponent(0.40)

    // MARK: Completion Pulse

    static let uiPulseColor = UIColor(hex: 0x80FF57)

    // MARK: Scanning Line

    static let scanLineDuration: Double = 2.0
    static let scanLineWidth: CGFloat = 2.0
    static let scanLineGlowRadius: CGFloat = 8.0

    // MARK: Scanning Line - Depth Contour

    static let scanLineDepthSampleCount: Int = 80
    static let scanLineDepthDisplacementScale: CGFloat = 0.4
    static let scanLineMaxDisplacement: CGFloat = 60.0
    static let scanLineTemporalBlend: CGFloat = 0.3
    static let scanLineSpatialSmoothWindow: Int = 5
    static let scanLineMaxDepth: Float = 5.0

    // MARK: Animation Timing

    static let edgeTraceDuration: Double = 0.5
    static let flyToBottomDuration: Double = 0.4
    static let growVerticalDuration: Double = 0.4
    static let completionPulseDuration: Double = 0.3
    static let totalAnimationDuration: Double = 1.6

    // MARK: Gradients

    static var cyanGradient: LinearGradient {
        LinearGradient(
            colors: [cyan, cyan.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var headerGradient: LinearGradient {
        LinearGradient(
            colors: [surfaceCard, surfaceDark],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Fonts

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Color Hex Initializer

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

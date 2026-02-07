//
//  Constants.swift
//  ProductMeasure
//

import Foundation

enum AppConstants {
    // MARK: - Point Cloud Processing
    static let maxPointCloudSize = 20000
    static let pointCloudGridSize: Float = 0.003 // 3mm grid for downsampling

    // MARK: - Depth Processing
    static let minDepthConfidence: Float = 0.4
    static let highDepthConfidence: Float = 0.7
    static let minDepthCoverage: Float = 0.5
    static let highDepthCoverage: Float = 0.8

    // MARK: - Outlier Removal
    static let outlierStdDevThreshold: Float = 2.0
    static let ransacIterations = 100
    static let ransacDistanceThreshold: Float = 0.02 // 2cm

    // MARK: - UI
    static let boxLineWidth: Float = 0.002
    static let handleRadius: Float = 0.01
    static let labelFontSize: CGFloat = 14

    // MARK: - Measurement
    static let defaultUnit: MeasurementUnit = .centimeters
    static let defaultRounding: RoundingPrecision = .millimeter1

    // MARK: - Refinement
    static let maxRefinementRounds = 3
    static let refinementProximityScale: Float = 2.0   // Scale factor for same-object validation
    static let refinementOverlapThreshold: Float = 0.30 // Minimum overlap ratio for new point cloud

    // MARK: - Scene Accumulation
    static let accumulatorVoxelSize: Float = 0.005       // 5mm voxel grid
    static let accumulatorMaxAge: TimeInterval = 5.0     // 5-second rolling window
    static let accumulatorSampleStride: Int = 8          // Sample every 8th pixel in depth map
    static let accumulatorMinConfidence: Int = 1         // ARConfidenceLevel.medium
    static let accumulatorQueryExpansion: Float = 1.5    // Expand query box by this factor
    static let accumulatorMinExtraPoints: Int = 50       // Min extra points needed for merge
}

enum MeasurementUnit: String, CaseIterable, Codable {
    case millimeters = "mm"
    case centimeters = "cm"
    case inches = "in"

    var displayName: String {
        switch self {
        case .millimeters: return "Millimeters (mm)"
        case .centimeters: return "Centimeters (cm)"
        case .inches: return "Inches (in)"
        }
    }

    func convert(meters: Float) -> Float {
        switch self {
        case .millimeters: return meters * 1000
        case .centimeters: return meters * 100
        case .inches: return meters * 39.3701
        }
    }

    func volumeUnit() -> String {
        switch self {
        case .millimeters: return "mm³"
        case .centimeters: return "cm³"
        case .inches: return "in³"
        }
    }

    func convertVolume(cubicMeters: Float) -> Float {
        switch self {
        case .millimeters: return cubicMeters * 1e9
        case .centimeters: return cubicMeters * 1e6
        case .inches: return cubicMeters * 61023.7
        }
    }

    /// Volumetric weight: (L_cm x W_cm x H_cm) / 5000 = kg
    /// Equivalent to cubicMeters * 1e6 / 5000 = cubicMeters * 200
    func formatVolumetricWeight(cubicMeters: Float) -> String {
        let kg = cubicMeters * 200.0
        return String(format: "%.2f kg", kg)
    }
}

enum RoundingPrecision: String, CaseIterable, Codable {
    case millimeter1 = "1mm"
    case millimeter5 = "5mm"
    case centimeter01 = "0.1cm"
    case centimeter1 = "1cm"

    var displayName: String {
        switch self {
        case .millimeter1: return "1 mm"
        case .millimeter5: return "5 mm"
        case .centimeter01: return "0.1 cm"
        case .centimeter1: return "1 cm"
        }
    }

    func round(meters: Float) -> Float {
        let precision: Float
        switch self {
        case .millimeter1: precision = 0.001
        case .millimeter5: precision = 0.005
        case .centimeter01: precision = 0.001
        case .centimeter1: precision = 0.01
        }
        return (meters / precision).rounded() * precision
    }
}

enum MeasurementMode: String, CaseIterable, Codable {
    case boxPriority = "box"
    case freeObject = "free"

    var displayName: String {
        switch self {
        case .boxPriority: return "Box Priority"
        case .freeObject: return "Free Object"
        }
    }

    var description: String {
        switch self {
        case .boxPriority: return "Optimized for box-shaped objects on surfaces. Locks vertical axis."
        case .freeObject: return "For irregularly shaped or tilted objects. Full 3D rotation."
        }
    }
}

enum SizeClass: String, CaseIterable {
    case xs = "XS"
    case small = "SMALL"
    case medium = "MEDIUM"
    case large = "LARGE"
    case xl = "XL"
    case xxl = "XXL"

    var displayName: String { rawValue }

    /// Classify based on volume in cubic meters (thresholds in cubic inches)
    static func classify(volumeCubicMeters: Float) -> SizeClass {
        let cubicInches = volumeCubicMeters * 61023.7
        switch cubicInches {
        case ...100: return .xs
        case 101...250: return .small
        case 251...650: return .medium
        case 651...1050: return .large
        case 1051...1728: return .xl
        default: return .xxl
        }
    }
}

enum SelectionMode: String, CaseIterable, Codable {
    case tap = "tap"
    case box = "box"

    var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .box: return "Box"
        }
    }

    var icon: String {
        switch self {
        case .tap: return "hand.tap"
        case .box: return "rectangle.dashed"
        }
    }
}

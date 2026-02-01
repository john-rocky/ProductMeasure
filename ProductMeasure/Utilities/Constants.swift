//
//  Constants.swift
//  ProductMeasure
//

import Foundation

enum AppConstants {
    // MARK: - Point Cloud Processing
    static let maxPointCloudSize = 5000
    static let pointCloudGridSize: Float = 0.005 // 5mm grid for downsampling

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

// MARK: - Scan Mode

/// Scan mode for measurement
enum ScanMode: String, CaseIterable, Codable {
    case single = "single"
    case multi = "multi"

    var displayName: String {
        switch self {
        case .single: return "Single Scan"
        case .multi: return "Multi-Scan"
        }
    }

    var description: String {
        switch self {
        case .single: return "Quick measurement from one angle"
        case .multi: return "Accurate volume from multiple angles (min. 3)"
        }
    }

    var icon: String {
        switch self {
        case .single: return "viewfinder"
        case .multi: return "camera.on.rectangle.fill"
        }
    }
}

// MARK: - Volume Calculation Method

/// Methods for calculating volume from point cloud
enum VolumeCalculationMethod: String, CaseIterable, Codable {
    case voxel = "voxel"
    case alphaShape = "alpha"
    case ballPivoting = "mesh"

    var displayName: String {
        switch self {
        case .voxel: return "Voxel"
        case .alphaShape: return "Alpha Shape"
        case .ballPivoting: return "Ball Pivoting"
        }
    }

    var description: String {
        switch self {
        case .voxel:
            return "Fast grid-based calculation (±10-20%)"
        case .alphaShape:
            return "Medium precision surface reconstruction (±2-5%)"
        case .ballPivoting:
            return "High precision mesh reconstruction (95%+)"
        }
    }

    var icon: String {
        switch self {
        case .voxel: return "cube.fill"
        case .alphaShape: return "pentagon.fill"
        case .ballPivoting: return "circle.hexagongrid.fill"
        }
    }

    /// Estimated accuracy percentage
    var estimatedAccuracy: String {
        switch self {
        case .voxel: return "80-90%"
        case .alphaShape: return "95-98%"
        case .ballPivoting: return "95%+"
        }
    }

    /// Relative processing speed
    var speedRating: Int {
        switch self {
        case .voxel: return 3      // Fast
        case .alphaShape: return 2  // Medium
        case .ballPivoting: return 1 // Slow
        }
    }
}

// MARK: - Multi-Scan Constants

extension AppConstants {
    // MARK: - Multi-Scan Settings

    /// Minimum number of scans required for multi-scan mode
    static let minimumScansRequired = 3

    /// Target point count for good coverage
    static let targetMultiScanPointCount = 15000

    /// Minimum angle difference between scans (degrees)
    static let minimumScanAngleDifference: Float = 30.0

    /// Default minimum point spacing for octree (3mm)
    static let defaultOctreePointSpacing: Float = 0.003

    // MARK: - Alpha Shape Settings

    /// Default alpha multiplier for automatic selection
    static let defaultAlphaMultiplier: Float = 2.5

    /// Minimum alpha value (5mm)
    static let minimumAlpha: Float = 0.005

    /// Maximum alpha value (50cm)
    static let maximumAlpha: Float = 0.5

    // MARK: - Ball Pivoting Settings

    /// Default ball radius multiplier
    static let defaultBallRadiusMultiplier: Float = 3.0

    /// Minimum ball radius (5mm)
    static let minimumBallRadius: Float = 0.005

    /// Maximum ball radius (20cm)
    static let maximumBallRadius: Float = 0.2

    /// Maximum triangles to generate (memory limit)
    static let maxMeshTriangles = 100000
}

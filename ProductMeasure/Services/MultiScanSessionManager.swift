//
//  MultiScanSessionManager.swift
//  ProductMeasure
//
//  Manages multi-angle scanning sessions for improved point cloud coverage
//  and accurate volume calculation.
//

import Foundation
import ARKit
import simd

/// Result of a multi-scan session
struct MultiScanResult {
    let points: [SIMD3<Float>]
    let scanCount: Int
    let totalPointsProcessed: Int
    let uniquePointCount: Int
    let estimatedCoverage: Float
    let boundingBox: BoundingBox3D?
    let processingTime: TimeInterval
}

/// Manages a multi-angle scanning session
@MainActor
class MultiScanSessionManager: ObservableObject {

    // MARK: - Session State

    enum SessionState: Equatable {
        case idle
        case scanning
        case processing
        case completed
    }

    // MARK: - Published Properties

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var scanCount: Int = 0
    @Published private(set) var accumulatedPointCount: Int = 0
    @Published private(set) var coverageProgress: Float = 0.0
    @Published private(set) var currentScanPointCount: Int = 0
    @Published private(set) var scanAngles: [Float] = []
    @Published private(set) var lastScanResult: MultiScanResult?

    // MARK: - Configuration

    /// Minimum number of scans required for accurate volume calculation
    static let minimumScansRequired = 3

    /// Target point count for good coverage
    static let targetPointCount = 15000

    /// Minimum angle difference between scans (degrees)
    static let minimumAngleDifference: Float = 30.0

    // MARK: - Private Properties

    private var pointCloudOctree: PointCloudOctree
    private var initialBoundingBox: BoundingBox3D?
    private var totalPointsProcessed: Int = 0
    private var cameraPositions: [SIMD3<Float>] = []
    private var sessionStartTime: Date?

    // MARK: - Coverage Estimation

    /// Subdivisions for coverage grid (8x8x8 = 512 cells)
    private let coverageGridSize = 8
    private var coverageGrid: Set<Int> = []

    // MARK: - Initialization

    init() {
        self.pointCloudOctree = PointCloudOctree(minPointSpacing: 0.003)
    }

    // MARK: - Session Management

    /// Starts a new multi-scan session
    /// - Parameter initialBox: The initial bounding box from the first measurement
    func startSession(initialBox: BoundingBox3D) {
        guard state == .idle else { return }

        reset()
        initialBoundingBox = initialBox
        state = .scanning
        sessionStartTime = Date()

        // Initialize octree with bounds from bounding box
        let corners = initialBox.corners
        let minBound = corners.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let maxBound = corners.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }

        // Expand bounds slightly for margin
        let margin: Float = 0.05
        let expandedMin = minBound - SIMD3<Float>(repeating: margin)
        let expandedMax = maxBound + SIMD3<Float>(repeating: margin)

        pointCloudOctree = PointCloudOctree(
            bounds: (expandedMin, expandedMax),
            minPointSpacing: 0.003
        )
    }

    /// Adds points from a new scan
    /// - Parameters:
    ///   - points: The point cloud from this scan
    ///   - cameraPosition: The camera position when scan was taken
    /// - Returns: Number of new unique points added
    @discardableResult
    func addScan(points: [SIMD3<Float>], cameraPosition: SIMD3<Float>) -> Int {
        guard state == .scanning else { return 0 }

        // Check angle difference from previous scans
        if !cameraPositions.isEmpty {
            let angle = calculateAngleFromPreviousScans(cameraPosition: cameraPosition)
            if angle < Self.minimumAngleDifference {
                print("MultiScan: Angle too similar (\(angle)°). Recommend moving to a different position.")
            }
            scanAngles.append(angle)
        }

        cameraPositions.append(cameraPosition)
        totalPointsProcessed += points.count
        currentScanPointCount = points.count

        // Insert points into octree (duplicates are automatically filtered)
        let insertedCount = pointCloudOctree.insert(points: points)
        accumulatedPointCount = pointCloudOctree.pointCount
        scanCount += 1

        // Update coverage estimation
        updateCoverageEstimation(newPoints: points)

        return insertedCount
    }

    /// Adds scan asynchronously with processing on background queue
    func addScanAsync(points: [SIMD3<Float>], cameraPosition: SIMD3<Float>) async -> Int {
        let result = await Task.detached(priority: .userInitiated) { [points] in
            // Pre-filter points on background thread
            return points
        }.value

        return addScan(points: result, cameraPosition: cameraPosition)
    }

    /// Finishes the scanning session and returns accumulated points
    func finishSession() -> MultiScanResult {
        guard state == .scanning else {
            return MultiScanResult(
                points: [],
                scanCount: 0,
                totalPointsProcessed: 0,
                uniquePointCount: 0,
                estimatedCoverage: 0,
                boundingBox: nil,
                processingTime: 0
            )
        }

        state = .processing

        let points = pointCloudOctree.getAllPoints()
        let processingTime = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0

        let result = MultiScanResult(
            points: points,
            scanCount: scanCount,
            totalPointsProcessed: totalPointsProcessed,
            uniquePointCount: points.count,
            estimatedCoverage: coverageProgress,
            boundingBox: initialBoundingBox,
            processingTime: processingTime
        )

        lastScanResult = result
        state = .completed

        return result
    }

    /// Resets the session to idle state
    func reset() {
        state = .idle
        scanCount = 0
        accumulatedPointCount = 0
        coverageProgress = 0.0
        currentScanPointCount = 0
        scanAngles = []
        lastScanResult = nil

        pointCloudOctree = PointCloudOctree(minPointSpacing: 0.003)
        initialBoundingBox = nil
        totalPointsProcessed = 0
        cameraPositions = []
        coverageGrid = []
        sessionStartTime = nil
    }

    /// Cancels the current session
    func cancelSession() {
        reset()
    }

    // MARK: - Session Queries

    /// Returns whether enough scans have been collected
    var hasEnoughScans: Bool {
        scanCount >= Self.minimumScansRequired
    }

    /// Returns the number of additional scans recommended
    var additionalScansNeeded: Int {
        max(0, Self.minimumScansRequired - scanCount)
    }

    /// Suggests the next camera position for optimal coverage
    func suggestNextCameraPosition() -> String? {
        guard !cameraPositions.isEmpty, let box = initialBoundingBox else {
            return nil
        }

        // Analyze which sides have been scanned
        let objectCenter = box.center
        var coveredAngles: [Float] = []

        for camPos in cameraPositions {
            let direction = simd_normalize(camPos - objectCenter)
            let angle = atan2(direction.x, direction.z) * 180 / .pi
            coveredAngles.append(angle)
        }

        // Find the largest gap in angles
        let sortedAngles = coveredAngles.sorted()
        var maxGap: Float = 0
        var gapCenterAngle: Float = 0

        for i in 0..<sortedAngles.count {
            let nextIndex = (i + 1) % sortedAngles.count
            var gap = sortedAngles[nextIndex] - sortedAngles[i]
            if gap < 0 { gap += 360 }

            if gap > maxGap {
                maxGap = gap
                gapCenterAngle = sortedAngles[i] + gap / 2
                if gapCenterAngle > 180 { gapCenterAngle -= 360 }
            }
        }

        // Convert angle to direction description
        let normalizedAngle = gapCenterAngle < 0 ? gapCenterAngle + 360 : gapCenterAngle

        switch normalizedAngle {
        case 0..<45, 315..<360:
            return "Move to front"
        case 45..<135:
            return "Move to right side"
        case 135..<225:
            return "Move to back"
        case 225..<315:
            return "Move to left side"
        default:
            return nil
        }
    }

    /// Returns the accumulated point cloud
    var accumulatedPoints: [SIMD3<Float>] {
        pointCloudOctree.getAllPoints()
    }

    /// Returns the average nearest neighbor distance of accumulated points
    var averagePointSpacing: Float {
        pointCloudOctree.averageNearestNeighborDistance()
    }

    // MARK: - Private Methods

    private func calculateAngleFromPreviousScans(cameraPosition: SIMD3<Float>) -> Float {
        guard let box = initialBoundingBox else { return 90 }

        let objectCenter = box.center

        // Calculate direction from object to new camera
        let newDirection = simd_normalize(cameraPosition - objectCenter)

        // Find minimum angle to any previous scan
        var minAngle: Float = 180

        for prevCamPos in cameraPositions {
            let prevDirection = simd_normalize(prevCamPos - objectCenter)
            let dot = simd_dot(newDirection, prevDirection)
            let angle = acos(simd_clamp(dot, -1, 1)) * 180 / .pi
            minAngle = min(minAngle, angle)
        }

        return minAngle
    }

    private func updateCoverageEstimation(newPoints: [SIMD3<Float>]) {
        guard let box = initialBoundingBox else { return }

        let corners = box.corners
        let minBound = corners.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let maxBound = corners.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let size = maxBound - minBound

        // Map points to grid cells
        for point in newPoints {
            let normalized = (point - minBound) / size
            let gridX = min(coverageGridSize - 1, max(0, Int(normalized.x * Float(coverageGridSize))))
            let gridY = min(coverageGridSize - 1, max(0, Int(normalized.y * Float(coverageGridSize))))
            let gridZ = min(coverageGridSize - 1, max(0, Int(normalized.z * Float(coverageGridSize))))

            let index = gridX + gridY * coverageGridSize + gridZ * coverageGridSize * coverageGridSize
            coverageGrid.insert(index)
        }

        let totalCells = coverageGridSize * coverageGridSize * coverageGridSize
        coverageProgress = Float(coverageGrid.count) / Float(totalCells)
    }
}

// MARK: - Scan Quality Metrics

extension MultiScanSessionManager {

    struct ScanQuality {
        let overallScore: Float // 0-1
        let coverageScore: Float
        let densityScore: Float
        let angleVarietyScore: Float
        let recommendation: String?
    }

    func evaluateScanQuality() -> ScanQuality {
        let coverageScore = coverageProgress

        // Density score based on point count vs target
        let densityScore = min(1.0, Float(accumulatedPointCount) / Float(Self.targetPointCount))

        // Angle variety score
        var angleVarietyScore: Float = 0
        if cameraPositions.count >= 2, let box = initialBoundingBox {
            let objectCenter = box.center
            var directions: [SIMD3<Float>] = []

            for camPos in cameraPositions {
                directions.append(simd_normalize(camPos - objectCenter))
            }

            // Calculate average pairwise angle
            var totalAngle: Float = 0
            var pairCount = 0

            for i in 0..<directions.count {
                for j in (i+1)..<directions.count {
                    let dot = simd_dot(directions[i], directions[j])
                    let angle = acos(simd_clamp(dot, -1, 1)) * 180 / .pi
                    totalAngle += angle
                    pairCount += 1
                }
            }

            if pairCount > 0 {
                let avgAngle = totalAngle / Float(pairCount)
                // 60 degrees average is considered good
                angleVarietyScore = min(1.0, avgAngle / 60.0)
            }
        }

        // Overall score weighted average
        let overallScore = coverageScore * 0.4 + densityScore * 0.3 + angleVarietyScore * 0.3

        // Generate recommendation
        var recommendation: String?
        if scanCount < Self.minimumScansRequired {
            recommendation = "\(additionalScansNeeded) more scan(s) required"
        } else if coverageScore < 0.6 {
            if let suggestion = suggestNextCameraPosition() {
                recommendation = suggestion + " for better coverage"
            }
        } else if densityScore < 0.5 {
            recommendation = "Move closer for higher point density"
        }

        return ScanQuality(
            overallScore: overallScore,
            coverageScore: coverageScore,
            densityScore: densityScore,
            angleVarietyScore: angleVarietyScore,
            recommendation: recommendation
        )
    }
}

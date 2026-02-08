//
//  BoundingBoxEstimator.swift
//  ProductMeasure
//

import simd
import Foundation
import ARKit

/// Estimates oriented bounding boxes from point clouds using MABR (Minimum Area Bounding Rectangle)
final class BoundingBoxEstimator: Sendable {
    // MARK: - Public Methods

    /// Estimate an oriented bounding box for a point cloud
    /// - Parameters:
    ///   - points: 3D points in world coordinates (used for extents/refinement)
    ///   - mode: Measurement mode (box priority or free object)
    ///   - verticalPlaneAnchors: Optional vertical plane anchors for orientation snapping
    ///   - angleEstimationPoints: Optional eroded point cloud for angle estimation only
    /// - Returns: Oriented bounding box
    func estimateBoundingBox(
        points: [SIMD3<Float>],
        mode: MeasurementMode,
        verticalPlaneAnchors: [ARPlaneAnchor] = [],
        angleEstimationPoints: [SIMD3<Float>]? = nil
    ) -> BoundingBox3D? {
        guard points.count >= 4 else { return nil }

        switch mode {
        case .boxPriority:
            return estimateBoxPriorityOBB(points: points, verticalPlaneAnchors: verticalPlaneAnchors, angleEstimationPoints: angleEstimationPoints)
        case .freeObject:
            return estimateFreeObjectOBB(points: points)
        }
    }

    // MARK: - Box Priority Mode

    /// Estimate OBB with vertical axis locked to world Y-axis
    /// Uses MABR (Minimum Area Bounding Rectangle) for horizontal orientation.
    /// Tries RANSAC plane-fit MABR first for tilted surfaces, falls back to XZ-projection MABR.
    /// - Parameter angleEstimationPoints: Optional eroded point cloud for angle estimation (reduces boundary noise)
    private func estimateBoxPriorityOBB(
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor],
        angleEstimationPoints: [SIMD3<Float>]? = nil
    ) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Use eroded points for angle estimation if available, full points for extents
        let anglePoints = angleEstimationPoints ?? points

        // Try RANSAC plane-fit MABR first (handles tilted surfaces)
        var mabrAngle: Float? = planeFitMABRAngle(points: anglePoints)

        // XZ-projection MABR using angle estimation points
        let horizontalPoints = anglePoints.map { SIMD2<Float>($0.x, $0.z) }
        let xAxis: SIMD3<Float>
        let zAxis: SIMD3<Float>

        if horizontalPoints.count >= 20 {
            let hull = convexHull2D(horizontalPoints)
            let simplifiedHull = simplifyConvexHull(hull)
            if simplifiedHull.count >= 3 {
                if mabrAngle == nil {
                    mabrAngle = minimumAreaBoundingRect(hull: simplifiedHull)
                }
                var angle = mabrAngle!

                // Percentile-based angular refinement using angle estimation points
                angle = refineAngleWithPercentiles(initialAngle: angle, points: horizontalPoints)

                // Face-distance refinement using full points (more discriminating than area for partial clouds)
                angle = refineAngleWithFaceDistance(initialAngle: angle, points3D: points)

                // Snap to vertical plane if one is nearby and aligned (final authority)
                angle = snapToVerticalPlane(
                    angle: angle,
                    boxCenter: centroid,
                    verticalPlaneAnchors: verticalPlaneAnchors
                )

                let cosA = cos(angle)
                let sinA = sin(angle)
                xAxis = SIMD3<Float>(cosA, 0, sinA).normalized
                zAxis = SIMD3<Float>(-sinA, 0, cosA).normalized
            } else {
                // Degenerate hull, fall back to PCA
                let (ax, az) = pcaHorizontalAxes(horizontalPoints)
                xAxis = ax
                zAxis = az
            }
        } else {
            // Too few points for reliable hull, fall back to PCA
            let (ax, az) = pcaHorizontalAxes(horizontalPoints)
            xAxis = ax
            zAxis = az
        }

        let yAxis = SIMD3<Float>(0, 1, 0)

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Compute extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        let initialBox = BoundingBox3D(center: center, extents: extents, rotation: rotation)

        // Iterative refinement
        return refineBoxIteratively(initialBox: initialBox, points: points, verticalPlaneAnchors: verticalPlaneAnchors)
    }

    // MARK: - Free Object Mode

    /// Estimate OBB using full 3D PCA
    /// Works for irregularly shaped or tilted objects
    private func estimateFreeObjectOBB(points: [SIMD3<Float>]) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Compute 3D covariance matrix
        let covariance = computeCovariance3D(points, centroid: centroid)

        // 3D PCA
        let (_, eigenvectors) = eigenDecomposition(covariance)

        // Ensure right-handed coordinate system
        var xAxis = SIMD3<Float>(eigenvectors.columns.0.x, eigenvectors.columns.0.y, eigenvectors.columns.0.z)
        var yAxis = SIMD3<Float>(eigenvectors.columns.1.x, eigenvectors.columns.1.y, eigenvectors.columns.1.z)
        var zAxis = xAxis.cross(yAxis)

        // Re-orthogonalize
        yAxis = zAxis.cross(xAxis).normalized
        xAxis = xAxis.normalized
        zAxis = zAxis.normalized

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Compute extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        return BoundingBox3D(center: center, extents: extents, rotation: rotation)
    }

    // MARK: - Convex Hull (Andrew's Monotone Chain)

    /// Compute the 2D convex hull of XZ-projected points
    /// Uses Andrew's monotone chain algorithm, O(n log n)
    private func convexHull2D(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2 && cross2D(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross2D(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        // Remove last point of each half because it's repeated
        lower.removeLast()
        upper.removeLast()

        return lower + upper
    }

    /// Simplify a convex hull by removing vertices whose adjacent edges are both short (noise).
    /// Retains only structurally significant vertices to reduce LiDAR boundary feathering effects.
    private func simplifyConvexHull(_ hull: [SIMD2<Float>], minEdgeFraction: Float = 0.03) -> [SIMD2<Float>] {
        guard hull.count > 3 else { return hull }

        // Compute total perimeter
        let n = hull.count
        var perimeter: Float = 0
        for i in 0..<n {
            perimeter += simd_distance(hull[i], hull[(i + 1) % n])
        }

        let minEdgeLength = perimeter * minEdgeFraction

        // Keep vertex if at least one adjacent edge is long enough
        var simplified: [SIMD2<Float>] = []
        for i in 0..<n {
            let prev = (i - 1 + n) % n
            let next = (i + 1) % n
            let edgePrev = simd_distance(hull[prev], hull[i])
            let edgeNext = simd_distance(hull[i], hull[next])
            if edgePrev >= minEdgeLength || edgeNext >= minEdgeLength {
                simplified.append(hull[i])
            }
        }

        // Ensure at least 3 vertices remain
        return simplified.count >= 3 ? simplified : hull
    }

    /// 2D cross product for convex hull: (b-a) x (c-a)
    private func cross2D(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    // MARK: - Minimum Area Bounding Rectangle (Rotating Calipers)

    /// Find the rotation angle (radians) of the minimum-area bounding rectangle
    /// for a convex hull on the XZ plane
    private func minimumAreaBoundingRect(hull: [SIMD2<Float>]) -> Float {
        guard hull.count >= 3 else { return 0 }

        var bestAngle: Float = 0
        var bestArea: Float = .infinity

        let n = hull.count
        for i in 0..<n {
            let j = (i + 1) % n
            let edge = hull[j] - hull[i]
            let angle = atan2(edge.y, edge.x)

            let cosA = cos(-angle)
            let sinA = sin(-angle)

            var minX: Float = .infinity, maxX: Float = -.infinity
            var minY: Float = .infinity, maxY: Float = -.infinity

            for p in hull {
                let rx = p.x * cosA - p.y * sinA
                let ry = p.x * sinA + p.y * cosA
                minX = min(minX, rx); maxX = max(maxX, rx)
                minY = min(minY, ry); maxY = max(maxY, ry)
            }

            let area = (maxX - minX) * (maxY - minY)
            if area < bestArea {
                bestArea = area
                bestAngle = angle
            }
        }

        return bestAngle
    }

    // MARK: - Percentile-Based Angular Refinement

    /// Refine MABR angle using percentile-based robust area minimization over all projected points.
    /// Two-phase search: coarse (1° steps over ±10°) then fine (0.2° steps over ±1°).
    /// Uses nth-element partial sort for O(n) percentile lookup instead of O(n log n) full sort.
    private func refineAngleWithPercentiles(
        initialAngle: Float,
        points: [SIMD2<Float>]
    ) -> Float {
        guard points.count >= 50 else { return initialAngle }

        let n = points.count
        let loIdx = max(0, Int(Float(n) * 0.02))
        let hiIdx = min(n - 1, Int(Float(n) * 0.98))
        guard loIdx < hiIdx else { return initialAngle }

        var xProj = [Float](repeating: 0, count: n)
        var yProj = [Float](repeating: 0, count: n)

        // Phase 1: coarse search ±10° in 1° steps (21 iterations)
        let coarseRange: Float = 10.0 * .pi / 180.0
        let coarseStep: Float = 1.0 * .pi / 180.0
        var bestAngle = initialAngle
        var bestArea: Float = .infinity

        var angle = initialAngle - coarseRange
        while angle <= initialAngle + coarseRange {
            let area = percentileArea(angle: angle, points: points, n: n, loIdx: loIdx, hiIdx: hiIdx, xProj: &xProj, yProj: &yProj)
            if area < bestArea {
                bestArea = area
                bestAngle = angle
            }
            angle += coarseStep
        }

        // Phase 2: fine search ±1° around best in 0.2° steps (11 iterations)
        let fineRange: Float = 1.0 * .pi / 180.0
        let fineStep: Float = 0.2 * .pi / 180.0
        let coarseBest = bestAngle

        angle = coarseBest - fineRange
        while angle <= coarseBest + fineRange {
            let area = percentileArea(angle: angle, points: points, n: n, loIdx: loIdx, hiIdx: hiIdx, xProj: &xProj, yProj: &yProj)
            if area < bestArea {
                bestArea = area
                bestAngle = angle
            }
            angle += fineStep
        }

        let delta = abs(bestAngle - initialAngle) * 180.0 / .pi
        if delta > 0.1 {
            print("[BBoxEstimator] Angular refinement: \(initialAngle * 180 / .pi)° -> \(bestAngle * 180 / .pi)° (Δ\(String(format: "%.1f", delta))°)")
        }

        return bestAngle
    }

    /// Compute percentile-based bounding area for a given rotation angle.
    /// Uses partial sort (partitioningIndex) for O(n) percentile extraction.
    private func percentileArea(
        angle: Float,
        points: [SIMD2<Float>],
        n: Int,
        loIdx: Int,
        hiIdx: Int,
        xProj: inout [Float],
        yProj: inout [Float]
    ) -> Float {
        let cosA = cos(-angle)
        let sinA = sin(-angle)

        for i in 0..<n {
            xProj[i] = points[i].x * cosA - points[i].y * sinA
            yProj[i] = points[i].x * sinA + points[i].y * cosA
        }

        let xLo = nthElement(&xProj, n: n, k: loIdx)
        let xHi = nthElement(&xProj, n: n, k: hiIdx)
        let yLo = nthElement(&yProj, n: n, k: loIdx)
        let yHi = nthElement(&yProj, n: n, k: hiIdx)

        return (xHi - xLo) * (yHi - yLo)
    }

    /// Find the k-th smallest element using partial sort (Introselect-like).
    /// Average O(n), avoids full O(n log n) sort.
    private func nthElement(_ arr: inout [Float], n: Int, k: Int) -> Float {
        var lo = 0, hi = n - 1
        while lo < hi {
            let pivotIdx = lo + (hi - lo) / 2
            let pivot = arr[pivotIdx]
            arr.swapAt(pivotIdx, hi)
            var store = lo
            for i in lo..<hi {
                if arr[i] < pivot {
                    arr.swapAt(i, store)
                    store += 1
                }
            }
            arr.swapAt(store, hi)
            if store == k { return arr[store] }
            else if store < k { lo = store + 1 }
            else { hi = store - 1 }
        }
        return arr[lo]
    }

    // MARK: - Face-Distance Angular Refinement

    /// Refine angle by minimizing the median distance from points to the nearest box face.
    /// More discriminating than area minimization for partial/one-sided point clouds.
    /// Two-phase: coarse ±5° in 0.5° steps, then fine ±0.5° in 0.1° steps.
    private func refineAngleWithFaceDistance(
        initialAngle: Float,
        points3D: [SIMD3<Float>]
    ) -> Float {
        guard points3D.count >= 50 else { return initialAngle }

        let initialScore = faceDistanceScore(angle: initialAngle, points3D: points3D)
        guard initialScore > 0 else { return initialAngle }

        // Phase 1: coarse sweep ±5° in 0.5° steps (21 candidates)
        let coarseRange: Float = 5.0 * .pi / 180.0
        let coarseStep: Float = 0.5 * .pi / 180.0
        var bestAngle = initialAngle
        var bestScore = initialScore

        var angle = initialAngle - coarseRange
        while angle <= initialAngle + coarseRange {
            let score = faceDistanceScore(angle: angle, points3D: points3D)
            if score < bestScore {
                bestScore = score
                bestAngle = angle
            }
            angle += coarseStep
        }

        // Phase 2: fine sweep ±0.5° around best in 0.1° steps (11 candidates)
        let fineRange: Float = 0.5 * .pi / 180.0
        let fineStep: Float = 0.1 * .pi / 180.0
        let coarseBest = bestAngle

        angle = coarseBest - fineRange
        while angle <= coarseBest + fineRange {
            let score = faceDistanceScore(angle: angle, points3D: points3D)
            if score < bestScore {
                bestScore = score
                bestAngle = angle
            }
            angle += fineStep
        }

        // Safety gate: only accept if >5% better than input
        let improvement = (initialScore - bestScore) / initialScore
        if improvement > 0.05 {
            let delta = abs(bestAngle - initialAngle) * 180.0 / .pi
            print("[BBoxEstimator] Face-distance refinement: \(initialAngle * 180 / .pi)° -> \(bestAngle * 180 / .pi)° (Δ\(String(format: "%.1f", delta))°, improvement \(String(format: "%.1f", improvement * 100))%)")
            return bestAngle
        }

        return initialAngle
    }

    /// Compute median distance from each point to its nearest OBB face for a given yaw angle.
    /// Lower score = better alignment.
    private func faceDistanceScore(
        angle: Float,
        points3D: [SIMD3<Float>]
    ) -> Float {
        let n = points3D.count
        guard n > 0 else { return .infinity }

        let cosA = cos(angle)
        let sinA = sin(angle)
        let xAxis = SIMD3<Float>(cosA, 0, sinA)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let zAxis = SIMD3<Float>(-sinA, 0, cosA)

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)
        let inverseRotation = rotation.inverse

        let centroid = points3D.reduce(.zero, +) / Float(n)

        // Transform all points to local coordinates
        let localPoints = points3D.map { inverseRotation.act($0 - centroid) }

        // Compute percentile extents (2%/98%)
        let loIdx = max(0, Int(Float(n) * 0.02))
        let hiIdx = min(n - 1, Int(Float(n) * 0.98))

        var xVals = localPoints.map { $0.x }
        var yVals = localPoints.map { $0.y }
        var zVals = localPoints.map { $0.z }

        let xLo = nthElement(&xVals, n: n, k: loIdx)
        let xHi = nthElement(&xVals, n: n, k: hiIdx)
        let yLo = nthElement(&yVals, n: n, k: loIdx)
        let yHi = nthElement(&yVals, n: n, k: hiIdx)
        let zLo = nthElement(&zVals, n: n, k: loIdx)
        let zHi = nthElement(&zVals, n: n, k: hiIdx)

        let halfExtents = SIMD3<Float>(
            (xHi - xLo) / 2,
            (yHi - yLo) / 2,
            (zHi - zLo) / 2
        )
        let boxCenter = SIMD3<Float>(
            (xHi + xLo) / 2,
            (yHi + yLo) / 2,
            (zHi + zLo) / 2
        )

        guard halfExtents.x > 0.001 && halfExtents.y > 0.001 && halfExtents.z > 0.001 else {
            return .infinity
        }

        // Compute each point's distance to nearest face
        var distances = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = localPoints[i] - boxCenter
            let dx = halfExtents.x - abs(p.x)
            let dy = halfExtents.y - abs(p.y)
            let dz = halfExtents.z - abs(p.z)
            distances[i] = max(0, min(dx, dy, dz))
        }

        // Return median distance
        let medianIdx = n / 2
        return nthElement(&distances, n: n, k: medianIdx)
    }

    // MARK: - RANSAC Plane-Fit MABR

    /// Try to extract the MABR angle from the dominant plane of the point cloud.
    /// Returns nil if quality gates fail (falls back to XZ-projection MABR).
    private func planeFitMABRAngle(points: [SIMD3<Float>]) -> Float? {
        guard points.count >= 30 else { return nil }

        // Fit dominant plane via RANSAC
        guard let planeResult = fitDominantPlane(points: points) else { return nil }

        let normal = planeResult.normal
        let planePoint = planeResult.point
        let inlierIndices = planeResult.inlierIndices

        // Quality gate: enough inliers
        let inlierRatio = Float(inlierIndices.count) / Float(points.count)
        guard inlierRatio >= 0.4, inlierIndices.count >= 30 else {
            print("[BBoxEstimator] Plane-fit rejected: inlier ratio \(String(format: "%.1f%%", inlierRatio * 100)), count \(inlierIndices.count)")
            return nil
        }

        // Quality gate: plane must be tilted from world Y by >10°
        let worldY = SIMD3<Float>(0, 1, 0)
        let tiltAngle = acos(min(1, abs(simd_dot(normal, worldY))))
        guard tiltAngle > 10.0 * .pi / 180.0 else {
            print("[BBoxEstimator] Plane-fit skipped: tilt \(String(format: "%.1f°", tiltAngle * 180 / .pi)) too close to horizontal")
            return nil
        }

        // Project all points onto the plane's tangent basis
        let (projected2D, tangentU, _) = projectToPlane(points: points, normal: normal, point: planePoint)

        guard projected2D.count >= 20 else { return nil }

        // Run convex hull + MABR in the plane's 2D coordinate system
        let hull = convexHull2D(projected2D)
        let simplifiedHull = simplifyConvexHull(hull)
        guard simplifiedHull.count >= 3 else { return nil }

        let planeAngle = minimumAreaBoundingRect(hull: simplifiedHull)

        // Convert the MABR direction back to 3D and extract yaw angle in world XZ
        let cosP = cos(planeAngle)
        let sinP = sin(planeAngle)
        let tangentV = simd_cross(normal, tangentU)
        let direction3D = cosP * tangentU + sinP * tangentV
        let yawAngle = atan2(direction3D.z, direction3D.x)

        print("[BBoxEstimator] Plane-fit MABR: tilt=\(String(format: "%.1f°", tiltAngle * 180 / .pi)), inliers=\(String(format: "%.0f%%", inlierRatio * 100)), yaw=\(String(format: "%.1f°", yawAngle * 180 / .pi))")

        return yawAngle
    }

    /// RANSAC plane fitting with PCA refit on inliers.
    /// Returns (normal, point on plane, inlier indices) or nil if insufficient points.
    private func fitDominantPlane(
        points: [SIMD3<Float>]
    ) -> (normal: SIMD3<Float>, point: SIMD3<Float>, inlierIndices: [Int])? {
        let n = points.count
        guard n >= 3 else { return nil }

        let iterations = AppConstants.ransacIterations
        let threshold = AppConstants.ransacDistanceThreshold

        var bestInlierIndices: [Int] = []

        for _ in 0..<iterations {
            // Pick 3 random points
            let i0 = Int.random(in: 0..<n)
            var i1 = Int.random(in: 0..<n)
            while i1 == i0 { i1 = Int.random(in: 0..<n) }
            var i2 = Int.random(in: 0..<n)
            while i2 == i0 || i2 == i1 { i2 = Int.random(in: 0..<n) }

            let v1 = points[i1] - points[i0]
            let v2 = points[i2] - points[i0]
            var normal = simd_cross(v1, v2)
            let len = simd_length(normal)
            guard len > 1e-8 else { continue }
            normal /= len

            // Count inliers
            var inliers: [Int] = []
            for j in 0..<n {
                let dist = abs(simd_dot(points[j] - points[i0], normal))
                if dist <= threshold {
                    inliers.append(j)
                }
            }

            if inliers.count > bestInlierIndices.count {
                bestInlierIndices = inliers
            }
        }

        guard bestInlierIndices.count >= 3 else { return nil }

        // Refit plane via PCA on inliers (smallest eigenvector = plane normal)
        let inlierPoints = bestInlierIndices.map { points[$0] }
        let inlierCentroid = inlierPoints.reduce(.zero, +) / Float(inlierPoints.count)
        let covariance = computeCovariance3D(inlierPoints, centroid: inlierCentroid)
        let (_, eigenvectors) = eigenDecomposition(covariance)

        // Smallest eigenvalue's eigenvector = plane normal (3rd column, sorted descending)
        let planeNormal = SIMD3<Float>(
            eigenvectors.columns.2.x,
            eigenvectors.columns.2.y,
            eigenvectors.columns.2.z
        ).normalized

        return (normal: planeNormal, point: inlierCentroid, inlierIndices: bestInlierIndices)
    }

    /// Project 3D points onto a plane defined by (normal, point).
    /// Returns 2D coordinates in the plane's tangent basis and the basis vectors.
    private func projectToPlane(
        points: [SIMD3<Float>],
        normal: SIMD3<Float>,
        point: SIMD3<Float>
    ) -> (projected2D: [SIMD2<Float>], tangentU: SIMD3<Float>, tangentV: SIMD3<Float>) {
        // Construct tangent basis
        let worldUp = SIMD3<Float>(0, 1, 0)
        var tangentU: SIMD3<Float>
        if abs(simd_dot(normal, worldUp)) > 0.9 {
            tangentU = simd_cross(normal, SIMD3<Float>(1, 0, 0))
        } else {
            tangentU = simd_cross(normal, worldUp)
        }
        tangentU = tangentU.normalized
        let tangentV = simd_cross(normal, tangentU).normalized

        // Project each point
        let projected = points.map { p -> SIMD2<Float> in
            let d = p - point
            return SIMD2<Float>(simd_dot(d, tangentU), simd_dot(d, tangentV))
        }

        return (projected, tangentU, tangentV)
    }

    // MARK: - Iterative Box Refinement

    /// Refine box extents by filtering outlier points, preserving the initial angle.
    /// The initial angle was carefully refined (RANSAC + percentile + face-distance + snap)
    /// so we only recompute tighter extents from filtered points, not re-estimate the angle.
    private func refineBoxIteratively(
        initialBox: BoundingBox3D,
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> BoundingBox3D {
        // Filter outlier points, then recompute tighter extents with preserved angle
        let margin: Float = 0.015  // 1.5cm
        let minRetainRatio: Float = 0.5

        let inverseRotation = initialBox.rotation.inverse
        let filteredPoints = points.filter { point in
            let local = inverseRotation.act(point - initialBox.center)
            let ex = initialBox.extents.x + margin
            let ey = initialBox.extents.y + margin
            let ez = initialBox.extents.z + margin
            return abs(local.x) <= ex && abs(local.y) <= ey && abs(local.z) <= ez
        }

        // If too many points pruned, keep original box
        guard Float(filteredPoints.count) >= Float(points.count) * minRetainRatio,
              filteredPoints.count >= 20 else {
            return initialBox
        }

        // Preserve the initial angle — it was carefully refined (RANSAC + percentile + face-distance + snap)
        // Only recompute tighter extents from filtered points (outliers removed)
        let rotation = initialBox.rotation

        let filteredCentroid = filteredPoints.reduce(.zero, +) / Float(filteredPoints.count)
        let (center, extents) = computeExtents(points: filteredPoints, centroid: filteredCentroid, rotation: rotation)

        return BoundingBox3D(center: center, extents: extents, rotation: rotation)
    }

    // MARK: - AR Plane-Assisted Orientation Snap

    /// Snap MABR angle to a nearby vertical plane's orientation if closely aligned
    private func snapToVerticalPlane(
        angle: Float,
        boxCenter: SIMD3<Float>,
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> Float {
        guard !verticalPlaneAnchors.isEmpty else { return angle }

        let maxDistance: Float = 2.0     // Only consider planes within 2m
        let snapThreshold: Float = 10.0 * .pi / 180.0  // 10 degrees

        var bestPlaneAngle: Float?
        var bestPlaneArea: Float = 0

        for anchor in verticalPlaneAnchors {
            // Distance from box center to plane center
            let planePos = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            let dist = simd_distance(
                SIMD2<Float>(boxCenter.x, boxCenter.z),
                SIMD2<Float>(planePos.x, planePos.z)
            )
            guard dist <= maxDistance else { continue }

            // Project plane normal onto XZ to get its 2D angle
            let normal = SIMD3<Float>(
                anchor.transform.columns.2.x,
                anchor.transform.columns.2.y,
                anchor.transform.columns.2.z
            )
            let planeAngle = atan2(normal.z, normal.x)

            // Check if plane angle is within snapThreshold of MABR angle (or +90°)
            let planeArea = anchor.extent.x * anchor.extent.z

            for offset in [Float(0), .pi / 2, -.pi / 2, .pi] {
                var diff = (angle + offset) - planeAngle
                // Normalize to [-pi, pi]
                while diff > .pi { diff -= 2 * .pi }
                while diff < -.pi { diff += 2 * .pi }

                if abs(diff) < snapThreshold && planeArea > bestPlaneArea {
                    bestPlaneAngle = planeAngle - offset
                    bestPlaneArea = planeArea
                }
            }
        }

        if let snapped = bestPlaneAngle {
            print("[BBoxEstimator] Snapped angle to vertical plane: \(angle * 180 / .pi)° -> \(snapped * 180 / .pi)°")
            return snapped
        }

        return angle
    }

    // MARK: - PCA Fallback

    /// PCA-based horizontal axis estimation (fallback for small point counts)
    private func pcaHorizontalAxes(_ horizontalPoints: [SIMD2<Float>]) -> (xAxis: SIMD3<Float>, zAxis: SIMD3<Float>) {
        let covariance2D = computeCovariance2D(horizontalPoints)
        let (_, eigenvectors2D) = eigenDecomposition2D(covariance2D)

        let xAxis = SIMD3<Float>(eigenvectors2D.columns.0.x, 0, eigenvectors2D.columns.0.y).normalized
        let zAxis = xAxis.cross(SIMD3<Float>(0, 1, 0)).normalized

        return (xAxis, zAxis)
    }

    // MARK: - Helper Methods

    private func computeCovariance3D(_ points: [SIMD3<Float>], centroid: SIMD3<Float>) -> simd_float3x3 {
        var cov = simd_float3x3(0)

        for point in points {
            let d = point - centroid
            cov.columns.0 += SIMD3<Float>(d.x * d.x, d.x * d.y, d.x * d.z)
            cov.columns.1 += SIMD3<Float>(d.y * d.x, d.y * d.y, d.y * d.z)
            cov.columns.2 += SIMD3<Float>(d.z * d.x, d.z * d.y, d.z * d.z)
        }

        let n = Float(points.count)
        cov.columns.0 /= n
        cov.columns.1 /= n
        cov.columns.2 /= n

        return cov
    }

    private func computeCovariance2D(_ points: [SIMD2<Float>]) -> simd_float2x2 {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        var cov = simd_float2x2(0)

        for point in points {
            let d = point - centroid
            cov.columns.0 += SIMD2<Float>(d.x * d.x, d.x * d.y)
            cov.columns.1 += SIMD2<Float>(d.y * d.x, d.y * d.y)
        }

        let n = Float(points.count)
        cov.columns.0 /= n
        cov.columns.1 /= n

        return cov
    }

    /// 2D eigenvalue decomposition for symmetric matrix
    private func eigenDecomposition2D(_ matrix: simd_float2x2) -> (eigenvalues: SIMD2<Float>, eigenvectors: simd_float2x2) {
        let a = matrix.columns.0.x
        let b = matrix.columns.1.x
        let c = matrix.columns.0.y
        let d = matrix.columns.1.y

        let trace = a + d
        let det = a * d - b * c

        let discriminant = sqrt(max(0, trace * trace / 4 - det))
        let lambda1 = trace / 2 + discriminant
        let lambda2 = trace / 2 - discriminant

        var v1: SIMD2<Float>
        var v2: SIMD2<Float>

        if abs(b) > 1e-10 {
            v1 = SIMD2<Float>(lambda1 - d, b).normalized
            v2 = SIMD2<Float>(lambda2 - d, b).normalized
        } else if abs(c) > 1e-10 {
            v1 = SIMD2<Float>(c, lambda1 - a).normalized
            v2 = SIMD2<Float>(c, lambda2 - a).normalized
        } else {
            v1 = SIMD2<Float>(1, 0)
            v2 = SIMD2<Float>(0, 1)
        }

        return (SIMD2<Float>(lambda1, lambda2), simd_float2x2(v1, v2))
    }

    private func computeExtents(
        points: [SIMD3<Float>],
        centroid: SIMD3<Float>,
        rotation: simd_quatf
    ) -> (center: SIMD3<Float>, extents: SIMD3<Float>) {
        let inverseRotation = rotation.inverse
        let localPoints = points.map { inverseRotation.act($0 - centroid) }

        // Use percentile-based extents to trim extreme noise only
        // Trim 1% from each side per axis — conservative to avoid shrinking real boundaries
        let n = localPoints.count
        let trimCount = max(1, Int(Float(n) * 0.01))

        let xVals = localPoints.map { $0.x }.sorted()
        let yVals = localPoints.map { $0.y }.sorted()
        let zVals = localPoints.map { $0.z }.sorted()

        let lo = max(0, trimCount)
        let hi = max(lo + 1, n - 1 - trimCount)

        let minLocal = SIMD3<Float>(xVals[lo], yVals[lo], zVals[lo])
        let maxLocal = SIMD3<Float>(xVals[hi], yVals[hi], zVals[hi])

        // Compute the true box center (not the centroid)
        let localCenter = (minLocal + maxLocal) / 2
        let adjustedCenter = centroid + rotation.act(localCenter)

        // Extents are half-sizes
        let extents = (maxLocal - minLocal) / 2

        return (center: adjustedCenter, extents: extents)
    }
}

// MARK: - SIMD2 Extensions

extension SIMD2 where Scalar == Float {
    var normalized: SIMD2<Float> {
        let len = simd_length(self)
        return len > 0 ? self / len : self
    }
}

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
    ///   - points: 3D points in world coordinates
    ///   - mode: Measurement mode (box priority or free object)
    ///   - verticalPlaneAnchors: Optional vertical plane anchors for orientation snapping
    /// - Returns: Oriented bounding box
    func estimateBoundingBox(
        points: [SIMD3<Float>],
        mode: MeasurementMode,
        verticalPlaneAnchors: [ARPlaneAnchor] = []
    ) -> BoundingBox3D? {
        guard points.count >= 4 else { return nil }

        switch mode {
        case .boxPriority:
            return estimateBoxPriorityOBB(points: points, verticalPlaneAnchors: verticalPlaneAnchors)
        case .freeObject:
            return estimateFreeObjectOBB(points: points)
        }
    }

    // MARK: - Box Priority Mode

    /// Estimate OBB with vertical axis locked to world Y-axis
    /// Uses MABR (Minimum Area Bounding Rectangle) for horizontal orientation
    private func estimateBoxPriorityOBB(
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Project points onto horizontal plane (XZ)
        let horizontalPoints = points.map { SIMD2<Float>($0.x, $0.z) }

        // Use MABR for orientation (fall back to PCA if too few points for convex hull)
        let xAxis: SIMD3<Float>
        let zAxis: SIMD3<Float>

        if horizontalPoints.count >= 20 {
            let hull = convexHull2D(horizontalPoints)
            let simplifiedHull = simplifyConvexHull(hull)
            if simplifiedHull.count >= 3 {
                var mabrAngle = minimumAreaBoundingRect(hull: simplifiedHull)

                // Percentile-based angular refinement using all projected points
                mabrAngle = refineAngleWithPercentiles(initialAngle: mabrAngle, points: horizontalPoints)

                // Snap to vertical plane if one is nearby and aligned (final authority)
                mabrAngle = snapToVerticalPlane(
                    angle: mabrAngle,
                    boxCenter: centroid,
                    verticalPlaneAnchors: verticalPlaneAnchors
                )

                let cosA = cos(mabrAngle)
                let sinA = sin(mabrAngle)
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

    // MARK: - Iterative Box Refinement

    /// Refine box orientation by filtering far-off points and re-running MABR,
    /// but always compute final extents from ALL original points to avoid shrinkage
    private func refineBoxIteratively(
        initialBox: BoundingBox3D,
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> BoundingBox3D {
        // Single refinement pass: filter outlier points, re-estimate angle only
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

        let centroid = filteredPoints.reduce(.zero, +) / Float(filteredPoints.count)
        let horizontalPoints = filteredPoints.map { SIMD2<Float>($0.x, $0.z) }

        guard horizontalPoints.count >= 20 else { return initialBox }
        let hull = convexHull2D(horizontalPoints)
        let simplifiedHull = simplifyConvexHull(hull)
        guard simplifiedHull.count >= 3 else { return initialBox }

        var angle = minimumAreaBoundingRect(hull: simplifiedHull)
        angle = refineAngleWithPercentiles(initialAngle: angle, points: horizontalPoints)
        angle = snapToVerticalPlane(
            angle: angle,
            boxCenter: centroid,
            verticalPlaneAnchors: verticalPlaneAnchors
        )

        let cosA = cos(angle)
        let sinA = sin(angle)
        let xAxis = SIMD3<Float>(cosA, 0, sinA).normalized
        let yAxis = SIMD3<Float>(0, 1, 0)
        let zAxis = SIMD3<Float>(-sinA, 0, cosA).normalized

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Compute extents from ALL original points (not filtered) to avoid shrinkage
        let fullCentroid = points.reduce(.zero, +) / Float(points.count)
        let (center, extents) = computeExtents(points: points, centroid: fullCentroid, rotation: rotation)

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

//
//  BoundingBoxEstimator.swift
//  ProductMeasure
//

import simd
import Foundation

/// Estimates oriented bounding boxes from point clouds using MABR (box mode) or PCA (free object mode)
class BoundingBoxEstimator {
    // MARK: - Public Methods

    /// Estimate an oriented bounding box for a point cloud
    /// - Parameters:
    ///   - points: 3D points in world coordinates
    ///   - mode: Measurement mode (box priority or free object)
    /// - Returns: Oriented bounding box
    func estimateBoundingBox(
        points: [SIMD3<Float>],
        mode: MeasurementMode
    ) -> BoundingBox3D? {
        guard points.count >= 4 else { return nil }

        switch mode {
        case .boxPriority:
            return estimateBoxPriorityOBB(points: points)
        case .freeObject:
            return estimateFreeObjectOBB(points: points)
        }
    }

    // MARK: - Box Priority Mode

    /// Estimate OBB with vertical axis locked to world Y-axis
    /// Uses Minimum-Area Bounding Rectangle (MABR) for edge-aligned orientation
    private func estimateBoxPriorityOBB(points: [SIMD3<Float>]) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Project points onto horizontal plane (XZ)
        let horizontalPoints = points.map { SIMD2<Float>($0.x, $0.z) }

        // Find horizontal orientation using MABR on convex hull
        let direction: SIMD2<Float>
        let hull = computeConvexHull2D(horizontalPoints)

        if hull.count >= 3 {
            direction = minimumAreaBoundingRectangleDirection(hull: hull)
        } else {
            // Fallback to PCA for degenerate cases
            let covariance2D = computeCovariance2D(horizontalPoints)
            let (_, eigenvectors2D) = eigenDecomposition2D(covariance2D)
            direction = eigenvectors2D.columns.0
        }

        // Construct 3D rotation matrix with Y-axis as world up
        let xAxis = SIMD3<Float>(direction.x, 0, direction.y).normalized
        let yAxis = SIMD3<Float>(0, 1, 0)
        let zAxis = xAxis.cross(yAxis).normalized

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Project points onto local axes and find extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        return BoundingBox3D(center: center, extents: extents, rotation: rotation)
    }

    // MARK: - Convex Hull & MABR

    /// Compute 2D convex hull using Andrew's monotone chain algorithm - O(n log n)
    private func computeConvexHull2D(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
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

    /// 2D cross product of vectors OA and OB (positive if counter-clockwise)
    private func cross2D(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Find the direction of the minimum-area bounding rectangle from convex hull
    /// Rotating calipers: for each hull edge, compute aligned bounding rect area, return best direction
    private func minimumAreaBoundingRectangleDirection(hull: [SIMD2<Float>]) -> SIMD2<Float> {
        var bestDirection = SIMD2<Float>(1, 0)
        var bestArea: Float = .infinity

        let n = hull.count
        for i in 0..<n {
            let j = (i + 1) % n
            var edgeDir = hull[j] - hull[i]
            let edgeLen = simd_length(edgeDir)
            guard edgeLen > 1e-10 else { continue }
            edgeDir /= edgeLen

            let perpDir = SIMD2<Float>(-edgeDir.y, edgeDir.x)

            // Project all hull points onto edge and perpendicular directions
            var minProj: Float = .infinity
            var maxProj: Float = -.infinity
            var minPerp: Float = .infinity
            var maxPerp: Float = -.infinity

            for p in hull {
                let proj = simd_dot(p, edgeDir)
                let perp = simd_dot(p, perpDir)
                minProj = min(minProj, proj)
                maxProj = max(maxProj, proj)
                minPerp = min(minPerp, perp)
                maxPerp = max(maxPerp, perp)
            }

            let area = (maxProj - minProj) * (maxPerp - minPerp)
            if area < bestArea {
                bestArea = area
                bestDirection = edgeDir
            }
        }

        return bestDirection.normalized
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
        var minLocal = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxLocal = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        let inverseRotation = rotation.inverse

        for point in points {
            let local = inverseRotation.act(point - centroid)
            minLocal = simd_min(minLocal, local)
            maxLocal = simd_max(maxLocal, local)
        }

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

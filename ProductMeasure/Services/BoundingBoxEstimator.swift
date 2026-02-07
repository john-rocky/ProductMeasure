//
//  BoundingBoxEstimator.swift
//  ProductMeasure
//

import simd
import Foundation

/// Estimates oriented bounding boxes from point clouds using PCA
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
    /// Optimized for box-shaped objects on surfaces
    private func estimateBoxPriorityOBB(points: [SIMD3<Float>]) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Project points onto horizontal plane (XZ)
        let horizontalPoints = points.map { SIMD2<Float>($0.x, $0.z) }

        // Compute 2D covariance matrix
        let covariance2D = computeCovariance2D(horizontalPoints)

        // 2D PCA to find horizontal orientation
        let (_, eigenvectors2D) = eigenDecomposition2D(covariance2D)

        // Construct 3D rotation matrix with Y-axis as world up
        let xAxis = SIMD3<Float>(eigenvectors2D.columns.0.x, 0, eigenvectors2D.columns.0.y).normalized
        let yAxis = SIMD3<Float>(0, 1, 0)
        let zAxis = xAxis.cross(yAxis).normalized

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Project points onto local axes and find extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        return BoundingBox3D(center: center, extents: extents, rotation: rotation)
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
        let inverseRotation = rotation.inverse
        let localPoints = points.map { inverseRotation.act($0 - centroid) }

        // Use percentile-based extents to trim noise from mask bleeding / LiDAR edge artifacts
        // Trim 2% from each side per axis — robust against outlier points at boundaries
        let n = localPoints.count
        let trimCount = max(1, Int(Float(n) * 0.02))

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

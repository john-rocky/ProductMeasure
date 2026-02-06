//
//  PointCloudGenerator.swift
//  ProductMeasure
//

import ARKit
import simd

/// Generates 3D point clouds from depth data
class PointCloudGenerator {
    // MARK: - Types

    /// A 3D point with associated confidence weight
    struct WeightedPoint {
        let position: SIMD3<Float>
        let weight: Float // 0.5 for medium confidence, 1.0 for high confidence
    }

    struct PointCloud {
        /// 3D points in world coordinates
        let points: [SIMD3<Float>]

        /// Quality metrics
        let quality: MeasurementQuality

        var centroid: SIMD3<Float> {
            guard !points.isEmpty else { return .zero }
            return points.reduce(.zero, +) / Float(points.count)
        }

        var isEmpty: Bool { points.isEmpty }
    }

    // MARK: - Properties

    private let depthProcessor = DepthProcessor()

    // MARK: - Public Methods

    /// Generate a point cloud from segmented object
    /// - Parameters:
    ///   - frame: ARFrame with depth data
    ///   - maskedPixels: Pixels in the segmentation mask
    ///   - imageSize: Camera image size
    ///   - depthAccumulator: Optional multi-frame depth accumulator for noise reduction
    /// - Returns: PointCloud with 3D world coordinates
    func generatePointCloud(
        frame: ARFrame,
        maskedPixels: [(x: Int, y: Int)],
        imageSize: CGSize,
        depthAccumulator: DepthAccumulator? = nil
    ) -> PointCloud {
        print("[PointCloud] Starting with \(maskedPixels.count) masked pixels")

        // Extract depth data for masked pixels (with optional multi-frame accumulation)
        var depthData = depthProcessor.extractDepthForMask(
            frame: frame,
            maskedPixels: maskedPixels,
            imageSize: imageSize,
            depthAccumulator: depthAccumulator
        )

        let totalMaskedPixels = maskedPixels.count
        print("[PointCloud] Extracted \(depthData.count) depth points")

        guard !depthData.isEmpty else {
            return PointCloud(
                points: [],
                quality: MeasurementQuality(
                    depthCoverage: 0,
                    depthConfidence: 0,
                    pointCount: 0,
                    trackingState: frame.camera.trackingState
                )
            )
        }

        // Remove outliers
        depthData = depthProcessor.removeOutliers(depthData)
        print("[PointCloud] After outlier removal: \(depthData.count) points")

        // Downsample if too many points
        if depthData.count > AppConstants.maxPointCloudSize {
            depthData = depthProcessor.downsample(depthData, gridSize: 4)
            print("[PointCloud] After downsampling: \(depthData.count) points")
        }

        // Get depth stats and compute adaptive grid size
        let stats = depthProcessor.getDepthStats(depthData: depthData)
        print("[PointCloud] Depth range: \(stats.minDepth)m - \(stats.maxDepth)m")

        // Adaptive grid size based on median depth: closer objects get finer grid
        let sortedDepths = depthData.map { $0.depth }.sorted()
        let medianDepth = DepthProcessor.median(sorted: sortedDepths)
        let adaptiveGridSize = min(max(medianDepth * 0.005, 0.003), 0.020)
        print("[PointCloud] Median depth: \(medianDepth)m, adaptive grid size: \(adaptiveGridSize * 1000)mm")

        // Get depth map size
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return PointCloud(
                points: [],
                quality: MeasurementQuality(
                    depthCoverage: 0,
                    depthConfidence: 0,
                    pointCount: 0,
                    trackingState: frame.camera.trackingState
                )
            )
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        print("[PointCloud] Depth map size: \(depthWidth)x\(depthHeight)")

        // Unproject to 3D world coordinates with confidence weights
        let weightedPoints = unprojectToWorld(
            depthData: depthData,
            frame: frame,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
        print("[PointCloud] Unprojected \(weightedPoints.count) points")

        // Filter outliers in 3D space (uses positions only)
        let filteredWeighted = filter3DOutliersWeighted(weightedPoints)
        print("[PointCloud] After 3D outlier filter: \(filteredWeighted.count) points")

        // Grid-based downsampling in 3D with confidence-weighted centroids (adaptive grid)
        let downsampledPoints = downsample3DWeighted(filteredWeighted, gridSize: adaptiveGridSize)
        print("[PointCloud] Final point count: \(downsampledPoints.count)")

        if let first = downsampledPoints.first {
            print("[PointCloud] Sample point: \(first)")
        }

        let quality = MeasurementQuality(
            depthCoverage: Float(depthData.count) / Float(max(totalMaskedPixels, 1)),
            depthConfidence: stats.averageConfidence,
            pointCount: downsampledPoints.count,
            trackingState: frame.camera.trackingState
        )

        return PointCloud(points: downsampledPoints, quality: quality)
    }

    // MARK: - Private Methods

    private func unprojectToWorld(
        depthData: [DepthProcessor.DepthData],
        frame: ARFrame,
        depthWidth: Int,
        depthHeight: Int
    ) -> [WeightedPoint] {
        let camera = frame.camera

        // Get the camera's transform (position and orientation in world space)
        let cameraTransform = camera.transform

        // Get intrinsics for the camera image
        let intrinsics = camera.intrinsics

        // Image dimensions from capturedImage
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))

        // Also check camera.imageResolution to ensure they match
        let cameraImageWidth = Float(camera.imageResolution.width)
        let cameraImageHeight = Float(camera.imageResolution.height)

        // Scale factors from depth map to camera image
        let scaleX = imageWidth / Float(depthWidth)
        let scaleY = imageHeight / Float(depthHeight)

        // Intrinsic parameters from camera (calibrated for camera.imageResolution)
        // If capturedImage has different resolution, we need to scale the intrinsics
        var fx = intrinsics[0][0]
        var fy = intrinsics[1][1]
        var cx = intrinsics[2][0]
        var cy = intrinsics[2][1]

        // Scale intrinsics if image resolution differs from camera.imageResolution
        if abs(imageWidth - cameraImageWidth) > 1 || abs(imageHeight - cameraImageHeight) > 1 {
            let scaleIntrinsicsX = imageWidth / cameraImageWidth
            let scaleIntrinsicsY = imageHeight / cameraImageHeight
            fx *= scaleIntrinsicsX
            fy *= scaleIntrinsicsY
            cx *= scaleIntrinsicsX
            cy *= scaleIntrinsicsY
            print("[Unproject] WARNING: Scaling intrinsics by \(scaleIntrinsicsX), \(scaleIntrinsicsY)")
        }

        // Debug: Print camera info once
        if depthData.count > 0 {
            print("[Unproject] Image size: \(imageWidth)x\(imageHeight)")
            print("[Unproject] Camera image resolution: \(cameraImageWidth)x\(cameraImageHeight)")
            print("[Unproject] Depth map size: \(depthWidth)x\(depthHeight)")
            print("[Unproject] Scale factors (depth to image): \(scaleX), \(scaleY)")
            print("[Unproject] Intrinsics: fx=\(fx), fy=\(fy), cx=\(cx), cy=\(cy)")
            print("[Unproject] Camera position: \(cameraTransform.columns.3)")
        }

        var points: [WeightedPoint] = []
        var debugCount = 0

        for data in depthData {
            let depth = data.depth

            // Confidence weight: medium=0.5, high=1.0
            let weight: Float = data.confidence == .high ? 1.0 : 0.5

            // Convert depth pixel coordinates to camera image coordinates
            let imageX = Float(data.pixelX) * scaleX
            let imageY = Float(data.pixelY) * scaleY

            // Unproject to camera-local 3D coordinates
            // Standard pinhole camera model: X = (u - cx) * Z / fx
            let localX = (imageX - cx) * depth / fx
            let localY = (imageY - cy) * depth / fy

            // In ARKit camera local space:
            // +X is right, +Y is up, +Z is towards the user (behind the camera)
            // So a point at positive depth (in front) is at negative Z
            let cameraSpacePoint = SIMD4<Float>(localX, -localY, -depth, 1.0)

            // Transform to world space
            let worldPoint = cameraTransform * cameraSpacePoint

            // Debug first few points
            if debugCount < 3 {
                print("[Unproject] Point \(debugCount): depth=\(depth)m, depthPx=(\(data.pixelX),\(data.pixelY)), imagePx=(\(imageX),\(imageY)), weight=\(weight)")
                print("[Unproject]   -> camera local: (\(localX), \(-localY), \(-depth))")
                print("[Unproject]   -> world: (\(worldPoint.x), \(worldPoint.y), \(worldPoint.z))")
                debugCount += 1
            }

            points.append(WeightedPoint(
                position: SIMD3(worldPoint.x, worldPoint.y, worldPoint.z),
                weight: weight
            ))
        }

        // Calculate and print point cloud bounds
        if !points.isEmpty {
            let positions = points.map { $0.position }
            let minX = positions.map { $0.x }.min()!
            let maxX = positions.map { $0.x }.max()!
            let minY = positions.map { $0.y }.min()!
            let maxY = positions.map { $0.y }.max()!
            let minZ = positions.map { $0.z }.min()!
            let maxZ = positions.map { $0.z }.max()!
            print("[Unproject] Point cloud bounds:")
            print("[Unproject]   X: \(minX) to \(maxX) (range: \((maxX - minX) * 100)cm)")
            print("[Unproject]   Y: \(minY) to \(maxY) (range: \((maxY - minY) * 100)cm)")
            print("[Unproject]   Z: \(minZ) to \(maxZ) (range: \((maxZ - minZ) * 100)cm)")
        }

        return points
    }

    /// Per-axis MAD outlier removal on weighted points
    private func filter3DOutliersWeighted(_ points: [WeightedPoint]) -> [WeightedPoint] {
        guard points.count > 10 else { return points }

        let threshold = AppConstants.madOutlierThreshold

        let xs = points.map { $0.position.x }.sorted()
        let ys = points.map { $0.position.y }.sorted()
        let zs = points.map { $0.position.z }.sorted()

        let medX = DepthProcessor.median(sorted: xs)
        let medY = DepthProcessor.median(sorted: ys)
        let medZ = DepthProcessor.median(sorted: zs)

        let madX = DepthProcessor.median(sorted: xs.map { abs($0 - medX) }.sorted())
        let madY = DepthProcessor.median(sorted: ys.map { abs($0 - medY) }.sorted())
        let madZ = DepthProcessor.median(sorted: zs.map { abs($0 - medZ) }.sorted())

        let scaleX = madX > 1e-6 ? 1.4826 * madX : Float.infinity
        let scaleY = madY > 1e-6 ? 1.4826 * madY : Float.infinity
        let scaleZ = madZ > 1e-6 ? 1.4826 * madZ : Float.infinity

        return points.filter { p in
            abs(p.position.x - medX) <= threshold * scaleX &&
            abs(p.position.y - medY) <= threshold * scaleY &&
            abs(p.position.z - medZ) <= threshold * scaleZ
        }
    }

    /// Grid-based 3D downsampling with confidence-weighted centroids
    private func downsample3DWeighted(_ points: [WeightedPoint], gridSize: Float) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }

        struct CellKey: Hashable {
            let x, y, z: Int
        }

        var grid: [CellKey: [WeightedPoint]] = [:]

        for point in points {
            let key = CellKey(
                x: Int(floor(point.position.x / gridSize)),
                y: Int(floor(point.position.y / gridSize)),
                z: Int(floor(point.position.z / gridSize))
            )
            grid[key, default: []].append(point)
        }

        // Return confidence-weighted centroid of each cell
        return grid.values.map { cellPoints in
            var weightedSum = SIMD3<Float>.zero
            var totalWeight: Float = 0
            for p in cellPoints {
                weightedSum += p.position * p.weight
                totalWeight += p.weight
            }
            return totalWeight > 0 ? weightedSum / totalWeight : cellPoints[0].position
        }
    }
}

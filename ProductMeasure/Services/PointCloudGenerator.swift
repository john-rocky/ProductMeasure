//
//  PointCloudGenerator.swift
//  ProductMeasure
//

import ARKit
import simd

/// Generates 3D point clouds from depth data
class PointCloudGenerator {
    // MARK: - Types

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
    ///   - mask: Segmentation mask
    ///   - imageSize: Camera image size
    /// - Returns: PointCloud with 3D world coordinates
    func generatePointCloud(
        frame: ARFrame,
        maskedPixels: [(x: Int, y: Int)],
        imageSize: CGSize
    ) -> PointCloud {
        print("[PointCloud] Starting with \(maskedPixels.count) masked pixels")

        // Extract depth data for masked pixels
        var depthData = depthProcessor.extractDepthForMask(
            frame: frame,
            maskedPixels: maskedPixels,
            imageSize: imageSize
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

        // Get depth stats
        let stats = depthProcessor.getDepthStats(depthData: depthData)
        print("[PointCloud] Depth range: \(stats.minDepth)m - \(stats.maxDepth)m")

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

        // Unproject to 3D world coordinates
        let points = unprojectToWorld(
            depthData: depthData,
            frame: frame,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
        print("[PointCloud] Unprojected \(points.count) points")

        // Filter outliers in 3D space
        let filteredPoints = filter3DOutliers(points)
        print("[PointCloud] After 3D outlier filter: \(filteredPoints.count) points")

        // Grid-based downsampling in 3D
        let downsampledPoints = downsample3D(filteredPoints, gridSize: AppConstants.pointCloudGridSize)
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
    ) -> [SIMD3<Float>] {
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

        var points: [SIMD3<Float>] = []
        var debugCount = 0

        for data in depthData {
            let depth = data.depth

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
                print("[Unproject] Point \(debugCount): depth=\(depth)m, depthPx=(\(data.pixelX),\(data.pixelY)), imagePx=(\(imageX),\(imageY))")
                print("[Unproject]   -> camera local: (\(localX), \(-localY), \(-depth))")
                print("[Unproject]   -> world: (\(worldPoint.x), \(worldPoint.y), \(worldPoint.z))")
                debugCount += 1
            }

            points.append(SIMD3(worldPoint.x, worldPoint.y, worldPoint.z))
        }

        // Calculate and print point cloud bounds
        if !points.isEmpty {
            let minX = points.map { $0.x }.min()!
            let maxX = points.map { $0.x }.max()!
            let minY = points.map { $0.y }.min()!
            let maxY = points.map { $0.y }.max()!
            let minZ = points.map { $0.z }.min()!
            let maxZ = points.map { $0.z }.max()!
            print("[Unproject] Point cloud bounds:")
            print("[Unproject]   X: \(minX) to \(maxX) (range: \((maxX - minX) * 100)cm)")
            print("[Unproject]   Y: \(minY) to \(maxY) (range: \((maxY - minY) * 100)cm)")
            print("[Unproject]   Z: \(minZ) to \(maxZ) (range: \((maxZ - minZ) * 100)cm)")
        }

        return points
    }

    private func filter3DOutliers(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 10 else { return points }

        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Calculate distances from centroid
        let distances = points.map { simd_distance($0, centroid) }
        let meanDistance = distances.reduce(0, +) / Float(distances.count)
        let variance = distances.map { ($0 - meanDistance) * ($0 - meanDistance) }.reduce(0, +) / Float(distances.count)
        let stdDev = sqrt(variance)

        let maxDistance = meanDistance + AppConstants.outlierStdDevThreshold * stdDev

        return zip(points, distances).compactMap { point, distance in
            distance <= maxDistance ? point : nil
        }
    }

    private func downsample3D(_ points: [SIMD3<Float>], gridSize: Float) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }

        var grid: [String: [SIMD3<Float>]] = [:]

        for point in points {
            let cellX = Int(floor(point.x / gridSize))
            let cellY = Int(floor(point.y / gridSize))
            let cellZ = Int(floor(point.z / gridSize))
            let key = "\(cellX)_\(cellY)_\(cellZ)"

            if grid[key] == nil {
                grid[key] = []
            }
            grid[key]!.append(point)
        }

        // Return the centroid of each cell
        return grid.values.map { cellPoints in
            cellPoints.reduce(.zero, +) / Float(cellPoints.count)
        }
    }
}

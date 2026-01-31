//
//  MeasurementCalculator.swift
//  ProductMeasure
//

import ARKit
import simd
import UIKit

/// Calculates dimensions and volume from bounding boxes
class MeasurementCalculator {
    // MARK: - Types

    struct MeasurementResult {
        let boundingBox: BoundingBox3D
        let length: Float  // meters
        let width: Float   // meters
        let height: Float  // meters
        let volume: Float  // cubic meters
        let quality: MeasurementQuality

        // Debug info
        var debugMaskImage: UIImage?
        var debugDepthImage: UIImage?
        var debugPointCloud: [SIMD3<Float>]?

        var formattedDimensions: String {
            String(format: "%.1f × %.1f × %.1f cm",
                   length * 100, width * 100, height * 100)
        }

        var formattedVolume: String {
            let volumeCm3 = volume * 1_000_000
            if volumeCm3 >= 1000 {
                return String(format: "%.0f cm³", volumeCm3)
            } else {
                return String(format: "%.1f cm³", volumeCm3)
            }
        }
    }

    // MARK: - Properties

    private let segmentationService = InstanceSegmentationService()
    private let pointCloudGenerator = PointCloudGenerator()
    private let boundingBoxEstimator = BoundingBoxEstimator()

    // MARK: - Public Methods

    /// Perform a complete measurement from an AR frame at a tap location
    /// - Parameters:
    ///   - frame: Current AR frame
    ///   - tapPoint: Tap location in view coordinates
    ///   - viewSize: Size of the view
    ///   - mode: Measurement mode
    ///   - raycastHitPosition: 3D world position from ARKit raycast (optional, for filtering)
    /// - Returns: MeasurementResult if successful
    func measure(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> MeasurementResult? {
        print("[Calculator] Starting measurement")
        print("[Calculator] Tap point: \(tapPoint), View size: \(viewSize)")

        // Convert tap point to normalized image coordinates (0-1)
        // Note: ARKit camera image is in landscape orientation
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
        print("[Calculator] Image size: \(imageSize)")

        // Convert screen coordinates to image coordinates
        // The AR view displays the camera in portrait, but the pixel buffer is landscape
        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint,
            viewSize: viewSize,
            imageSize: imageSize
        )
        print("[Calculator] Normalized tap point: \(normalizedTap)")

        // 1. Perform instance segmentation
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap
        ) else {
            print("[Calculator] Segmentation failed - no instance found")
            return nil
        }
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")

        // 2. Get masked pixels
        let maskedPixels = segmentationService.getMaskedPixels(
            mask: segmentation.mask,
            imageSize: imageSize
        )

        guard !maskedPixels.isEmpty else {
            print("[Calculator] No masked pixels found")
            return nil
        }
        print("[Calculator] Found \(maskedPixels.count) masked pixels before depth filtering")

        // 3. Filter masked pixels by depth - only keep pixels at similar depth to tap point
        let filteredPixels = filterMaskedPixelsByDepth(
            maskedPixels: maskedPixels,
            frame: frame,
            tapPoint: normalizedTap,
            imageSize: imageSize
        )

        guard !filteredPixels.isEmpty else {
            print("[Calculator] No pixels after depth filtering")
            return nil
        }
        print("[Calculator] Found \(filteredPixels.count) masked pixels after depth filtering")

        // Create debug mask image (memory-optimized version)
        let debugMaskImage = DebugVisualization.visualizeMask(
            mask: segmentation.mask,
            cameraImage: frame.capturedImage,
            tapPoint: normalizedTap
        )

        // Skip depth image to save memory
        let debugDepthImage: UIImage? = nil

        // 4. Generate point cloud from filtered pixels
        var pointCloud = pointCloudGenerator.generatePointCloud(
            frame: frame,
            maskedPixels: filteredPixels,
            imageSize: imageSize
        )

        guard !pointCloud.isEmpty else {
            print("[Calculator] Point cloud is empty")
            return nil
        }
        print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")

        // 5. Filter point cloud by 3D distance from raycast hit position
        // This is more reliable than 2D filtering because raycast handles coordinate transforms internally
        if let hitPosition = raycastHitPosition {
            // Use adaptive radius based on distance - closer objects get tighter filtering
            let distanceToCamera = simd_length(hitPosition - SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            ))
            // Adaptive radius: 20% of distance, clamped between 0.15m and 0.4m
            let adaptiveRadius = min(max(distanceToCamera * 0.20, 0.15), 0.4)
            print("[Calculator] Distance to camera: \(distanceToCamera)m, using radius: \(adaptiveRadius)m")

            var filteredPoints = filterPointsByProximity(
                points: pointCloud.points,
                center: hitPosition,
                maxDistance: adaptiveRadius
            )
            print("[Calculator] After 3D proximity filter: \(filteredPoints.count) points (from \(pointCloud.points.count))")

            // If we still have too many points, use clustering to find the main object
            if filteredPoints.count >= 50 {
                filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition)
                print("[Calculator] After clustering: \(filteredPoints.count) points")

                // Create new point cloud with filtered points
                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else if filteredPoints.count >= 20 {
                // Fewer points but still usable
                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else {
                print("[Calculator] Too few points after 3D filter, using original point cloud")
            }
        }

        // 6. Estimate bounding box
        guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
            points: pointCloud.points,
            mode: mode
        ) else {
            print("[Calculator] Failed to estimate bounding box")
            return nil
        }
        print("[Calculator] Bounding box estimated")
        print("[Calculator] Box center: \(boundingBox.center)")
        print("[Calculator] Box extents: \(boundingBox.extents)")

        // 7. Calculate dimensions
        let sorted = boundingBox.sortedDimensions
        let length = sorted[0].dimension
        let width = sorted[1].dimension
        let height = sorted[2].dimension
        let volume = boundingBox.volume

        print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
        print("[Calculator] Volume: \(volume * 1_000_000) cm³")

        var result = MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: volume,
            quality: pointCloud.quality
        )

        // Attach debug info (images only, not point cloud to save memory)
        result.debugMaskImage = debugMaskImage
        result.debugDepthImage = debugDepthImage

        return result
    }

    /// Convert screen coordinates to normalized image coordinates
    private func convertScreenToImageCoordinates(
        screenPoint: CGPoint,
        viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        // The camera image is captured in landscape orientation
        // ARView displays it rotated 90° CCW to fit portrait
        //
        // Mapping (determined empirically):
        // - screenY/screenHeight → normalizedImageX (top=0, bottom=1)
        // - 1 - screenX/screenWidth → normalizedImageY (left=1, right=0)

        let normalizedX = screenPoint.y / viewSize.height
        let normalizedY = 1.0 - (screenPoint.x / viewSize.width)

        print("[Coords] Screen point: \(screenPoint)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Image size: \(imageSize)")
        print("[Coords] Normalized tap (landscape image): (\(normalizedX), \(normalizedY))")
        print("[Coords] Image pixel: (\(normalizedX * imageSize.width), \(normalizedY * imageSize.height))")

        return CGPoint(x: normalizedX, y: normalizedY)
    }

    /// Update measurement with an edited bounding box
    func recalculate(boundingBox: BoundingBox3D, quality: MeasurementQuality) -> MeasurementResult {
        let sorted = boundingBox.sortedDimensions

        return MeasurementResult(
            boundingBox: boundingBox,
            length: sorted[0].dimension,
            width: sorted[1].dimension,
            height: sorted[2].dimension,
            volume: boundingBox.volume,
            quality: quality
        )
    }

    /// Calculate dimensions from a bounding box
    static func calculateDimensions(from box: BoundingBox3D) -> (length: Float, width: Float, height: Float) {
        let sorted = box.sortedDimensions
        return (sorted[0].dimension, sorted[1].dimension, sorted[2].dimension)
    }

    /// Filter masked pixels to only include those at similar depth to the tap point
    private func filterMaskedPixelsByDepth(
        maskedPixels: [(x: Int, y: Int)],
        frame: ARFrame,
        tapPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            print("[DepthFilter] No depth map available, returning all pixels")
            return maskedPixels
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return maskedPixels
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        // Scale factors from image to depth coordinates
        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        // Get depth at tap point
        let tapDepthX = Int(tapPoint.x * imageSize.width * scaleX)
        let tapDepthY = Int(tapPoint.y * imageSize.height * scaleY)

        guard tapDepthX >= 0 && tapDepthX < depthWidth && tapDepthY >= 0 && tapDepthY < depthHeight else {
            print("[DepthFilter] Tap point out of depth map bounds")
            return maskedPixels
        }

        let tapDepthIndex = tapDepthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + tapDepthX
        let tapDepth = depthPtr[tapDepthIndex]

        print("[DepthFilter] Tap depth: \(tapDepth)m at depth pixel (\(tapDepthX), \(tapDepthY))")

        guard tapDepth.isFinite && tapDepth > 0 else {
            print("[DepthFilter] Invalid tap depth, returning all pixels")
            return maskedPixels
        }

        // Filter pixels by depth - keep those within a tolerance of tap depth
        // Use a percentage-based tolerance (e.g., ±30% of tap depth or ±0.15m, whichever is larger)
        let percentTolerance = tapDepth * 0.3
        let minTolerance: Float = 0.15
        let depthTolerance = max(percentTolerance, minTolerance)

        print("[DepthFilter] Depth tolerance: ±\(depthTolerance)m")

        var filteredPixels: [(x: Int, y: Int)] = []
        filteredPixels.reserveCapacity(maskedPixels.count / 2)

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)

            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }

            let depthIndex = depthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + depthX
            let pixelDepth = depthPtr[depthIndex]

            if pixelDepth.isFinite && pixelDepth > 0 {
                let depthDiff = abs(pixelDepth - tapDepth)
                if depthDiff <= depthTolerance {
                    filteredPixels.append(pixel)
                }
            }
        }

        print("[DepthFilter] Filtered from \(maskedPixels.count) to \(filteredPixels.count) pixels")

        // If filtering removed too many pixels, return original
        if filteredPixels.count < 100 {
            print("[DepthFilter] Too few pixels after filtering, returning original")
            return maskedPixels
        }

        return filteredPixels
    }

    /// Calculate volume from dimensions
    static func calculateVolume(length: Float, width: Float, height: Float) -> Float {
        length * width * height
    }

    /// Filter 3D points by proximity to a center point
    /// This uses world coordinates, bypassing problematic 2D coordinate conversions
    private func filterPointsByProximity(
        points: [SIMD3<Float>],
        center: SIMD3<Float>,
        maxDistance: Float
    ) -> [SIMD3<Float>] {
        print("[ProximityFilter] Filtering \(points.count) points around center: \(center)")
        print("[ProximityFilter] Max distance: \(maxDistance)m")

        var filteredPoints: [SIMD3<Float>] = []
        filteredPoints.reserveCapacity(points.count)

        var distanceStats: [Float] = []

        for point in points {
            let distance = simd_distance(point, center)
            distanceStats.append(distance)

            if distance <= maxDistance {
                filteredPoints.append(point)
            }
        }

        // Log distance statistics
        if !distanceStats.isEmpty {
            let minDist = distanceStats.min()!
            let maxDist = distanceStats.max()!
            let avgDist = distanceStats.reduce(0, +) / Float(distanceStats.count)
            print("[ProximityFilter] Distance stats - min: \(minDist)m, max: \(maxDist)m, avg: \(avgDist)m")
        }

        print("[ProximityFilter] Kept \(filteredPoints.count) of \(points.count) points")

        return filteredPoints
    }

    /// Extract the main cluster of points around the center using density-based clustering
    /// This helps isolate the tapped object from other nearby objects
    private func extractMainCluster(points: [SIMD3<Float>], center: SIMD3<Float>) -> [SIMD3<Float>] {
        guard points.count > 20 else { return points }

        print("[Clustering] Starting with \(points.count) points")

        // Simple grid-based clustering
        // Divide space into cells and find the densest region around center
        let cellSize: Float = 0.03  // 3cm cells

        // Find the point closest to center as seed
        var seedPoint = points[0]
        var minDist = simd_distance(seedPoint, center)
        for point in points {
            let dist = simd_distance(point, center)
            if dist < minDist {
                minDist = dist
                seedPoint = point
            }
        }
        print("[Clustering] Seed point at distance \(minDist)m from center")

        // Grow cluster from seed using flood-fill approach
        var cluster: Set<Int> = []
        var frontier: [Int] = []

        // Find index of seed point
        for (i, point) in points.enumerated() {
            if simd_distance(point, seedPoint) < 0.001 {
                cluster.insert(i)
                frontier.append(i)
                break
            }
        }

        // Neighbor distance threshold - points within this distance are connected
        let neighborThreshold: Float = 0.05  // 5cm

        while !frontier.isEmpty {
            let currentIdx = frontier.removeFirst()
            let currentPoint = points[currentIdx]

            for (i, point) in points.enumerated() {
                if cluster.contains(i) { continue }

                let dist = simd_distance(point, currentPoint)
                if dist <= neighborThreshold {
                    cluster.insert(i)
                    frontier.append(i)
                }
            }

            // Stop if cluster is getting too large (performance)
            if cluster.count > 2000 { break }
        }

        let clusterPoints = cluster.map { points[$0] }
        print("[Clustering] Extracted cluster with \(clusterPoints.count) points")

        // If cluster is too small, return original
        if clusterPoints.count < 20 {
            print("[Clustering] Cluster too small, returning original points")
            return points
        }

        return clusterPoints
    }
}

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

        // Axis mapping (fixed at initial measurement time)
        // Determines which local axis (0=x, 1=y, 2=z) corresponds to each dimension
        let heightAxisIndex: Int   // Axis most aligned with world Y (vertical)
        let lengthAxisIndex: Int   // Axis most aligned with camera depth direction
        let widthAxisIndex: Int    // Axis most aligned with camera horizontal direction

        /// Get the axis mapping as a tuple
        var axisMapping: BoundingBox3D.AxisMapping {
            (height: heightAxisIndex, length: lengthAxisIndex, width: widthAxisIndex)
        }

        // Point cloud for Fit functionality
        var pointCloud: [SIMD3<Float>]?

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
        // This is CRITICAL - if no points are near the tap, the mask is wrong
        if let hitPosition = raycastHitPosition {
            // First check: is the raycast hit anywhere near the point cloud?
            let nearestDistance = pointCloud.points.map { simd_distance($0, hitPosition) }.min() ?? Float.infinity
            print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")

            // If the nearest point is more than 50cm away, the mask is completely wrong
            if nearestDistance > 0.5 {
                print("[Calculator] ERROR: Mask does not contain tapped location. Nearest point is \(nearestDistance)m away.")
                return nil
            }

            // Start with larger radius (50cm) then use clustering to find connected object
            let initialRadius: Float = 0.5
            var filteredPoints = filterPointsByProximity(
                points: pointCloud.points,
                center: hitPosition,
                maxDistance: initialRadius
            )
            print("[Calculator] After initial 50cm filter: \(filteredPoints.count) points")

            // Use clustering to find the connected object - this separates the tapped object from others
            if filteredPoints.count >= 30 {
                filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition)
                print("[Calculator] After clustering: \(filteredPoints.count) points")

                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else if filteredPoints.count >= 10 {
                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else {
                print("[Calculator] Too few points near tap location (\(filteredPoints.count))")
                return nil
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

        // 7. Calculate dimensions using camera-based axis mapping
        let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
        let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
        let volume = boundingBox.volume

        print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
        print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
        print("[Calculator] Volume: \(volume * 1_000_000) cm³")

        var result = MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: volume,
            quality: pointCloud.quality,
            heightAxisIndex: mapping.height,
            lengthAxisIndex: mapping.length,
            widthAxisIndex: mapping.width
        )

        // Store point cloud for Fit functionality
        result.pointCloud = pointCloud.points

        // Attach debug info (images only, not point cloud to save memory)
        result.debugMaskImage = debugMaskImage
        result.debugDepthImage = debugDepthImage

        return result
    }

    /// Perform measurement within a specific region of interest (box selection mode)
    /// - Parameters:
    ///   - frame: Current AR frame
    ///   - regionOfInterest: Screen rect defining the selection box
    ///   - viewSize: Size of the view
    ///   - mode: Measurement mode
    ///   - raycastHitPosition: 3D world position from ARKit raycast (optional)
    /// - Returns: MeasurementResult if successful
    func measureWithROI(
        frame: ARFrame,
        regionOfInterest: CGRect,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> MeasurementResult? {
        print("[Calculator] Starting ROI measurement")
        print("[Calculator] Screen ROI: \(regionOfInterest), View size: \(viewSize)")

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
        print("[Calculator] Image size: \(imageSize)")

        // Convert screen ROI to Vision normalized coordinates
        let visionROI = convertScreenRectToVisionCoordinates(
            screenRect: regionOfInterest,
            viewSize: viewSize
        )
        print("[Calculator] Vision ROI: \(visionROI)")

        // 1. Perform instance segmentation with ROI
        guard let segmentation = try await segmentationService.segmentInstanceWithROI(
            in: frame.capturedImage,
            regionOfInterest: visionROI
        ) else {
            print("[Calculator] Segmentation with ROI failed - no instance found")
            return nil
        }
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")

        // 2. Get masked pixels with ROI coordinate transformation
        let maskedPixels = segmentationService.getMaskedPixelsWithROI(
            mask: segmentation.mask,
            imageSize: imageSize,
            visionROI: visionROI
        )

        guard !maskedPixels.isEmpty else {
            print("[Calculator] No masked pixels found")
            return nil
        }
        print("[Calculator] Found \(maskedPixels.count) masked pixels")

        // 4. Apply depth filtering based on box center
        let boxCenter = CGPoint(x: regionOfInterest.midX, y: regionOfInterest.midY)
        let normalizedCenter = convertScreenToImageCoordinates(
            screenPoint: boxCenter,
            viewSize: viewSize,
            imageSize: imageSize
        )

        let depthFilteredPixels = filterMaskedPixelsByDepth(
            maskedPixels: maskedPixels,
            frame: frame,
            tapPoint: normalizedCenter,
            imageSize: imageSize
        )

        guard !depthFilteredPixels.isEmpty else {
            print("[Calculator] No pixels after depth filtering")
            return nil
        }
        print("[Calculator] Found \(depthFilteredPixels.count) masked pixels after depth filtering")

        // Create debug mask image with ROI
        let debugMaskImage = DebugVisualization.visualizeMaskWithROI(
            mask: segmentation.mask,
            cameraImage: frame.capturedImage,
            visionROI: visionROI,
            screenRect: regionOfInterest,
            viewSize: viewSize,
            tapPoint: normalizedCenter
        )

        // 5. Generate point cloud
        var pointCloud = pointCloudGenerator.generatePointCloud(
            frame: frame,
            maskedPixels: depthFilteredPixels,
            imageSize: imageSize
        )

        guard !pointCloud.isEmpty else {
            print("[Calculator] Point cloud is empty")
            return nil
        }
        print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")

        // 6. Filter by proximity if raycast hit available
        if let hitPosition = raycastHitPosition {
            let nearestDistance = pointCloud.points.map { simd_distance($0, hitPosition) }.min() ?? Float.infinity
            print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")

            if nearestDistance > 0.5 {
                print("[Calculator] ERROR: Point cloud too far from raycast hit")
                return nil
            }

            let initialRadius: Float = 0.5
            var filteredPoints = filterPointsByProximity(
                points: pointCloud.points,
                center: hitPosition,
                maxDistance: initialRadius
            )
            print("[Calculator] After initial 50cm filter: \(filteredPoints.count) points")

            if filteredPoints.count >= 30 {
                filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition)
                print("[Calculator] After clustering: \(filteredPoints.count) points")

                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else if filteredPoints.count >= 10 {
                pointCloud = PointCloudGenerator.PointCloud(
                    points: filteredPoints,
                    quality: pointCloud.quality
                )
            } else {
                print("[Calculator] Too few points near box center (\(filteredPoints.count))")
                return nil
            }
        }

        // 7. Estimate bounding box
        guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
            points: pointCloud.points,
            mode: mode
        ) else {
            print("[Calculator] Failed to estimate bounding box")
            return nil
        }
        print("[Calculator] Bounding box estimated")

        // 8. Calculate dimensions using camera-based axis mapping
        let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
        let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
        let volume = boundingBox.volume

        print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
        print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")

        var result = MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: volume,
            quality: pointCloud.quality,
            heightAxisIndex: mapping.height,
            lengthAxisIndex: mapping.length,
            widthAxisIndex: mapping.width
        )

        result.pointCloud = pointCloud.points
        result.debugMaskImage = debugMaskImage

        return result
    }

    /// Convert screen rectangle to Vision normalized coordinates
    /// Vision uses bottom-left origin (0-1 range)
    private func convertScreenRectToVisionCoordinates(
        screenRect: CGRect,
        viewSize: CGSize
    ) -> CGRect {
        // Screen coordinate system: top-left origin, portrait
        // Vision coordinate system: bottom-left origin, normalized (0-1)
        // Camera image is landscape, display is portrait (90° CCW rotation)
        //
        // Screen point (sx, sy) → Vision point (vx, vy):
        // - Screen Y maps to Vision X: vx = sy / screenHeight
        // - Screen X maps to Vision Y: vy = sx / screenWidth
        //
        // For rectangle (origin at top-left corner in screen coords):
        // - Vision origin.x = screen minY / screenHeight
        // - Vision origin.y = screen minX / screenWidth
        // - Vision width = screen height / screenHeight
        // - Vision height = screen width / screenWidth

        let normalizedX = screenRect.minY / viewSize.height
        let normalizedY = screenRect.minX / viewSize.width
        let normalizedWidth = screenRect.height / viewSize.height
        let normalizedHeight = screenRect.width / viewSize.width

        print("[Coords] Screen rect: \(screenRect)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Vision ROI: x=\(normalizedX), y=\(normalizedY), w=\(normalizedWidth), h=\(normalizedHeight)")

        return CGRect(
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    /// Filter pixels to only include those within the screen ROI
    private func filterPixelsToROI(
        pixels: [(x: Int, y: Int)],
        screenRect: CGRect,
        viewSize: CGSize,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        // Convert screen ROI to image pixel coordinates
        // Screen (portrait, top-left origin) → Image (landscape, top-left origin)
        //
        // Screen point (sx, sy) → Image point (ix, iy):
        // - ix = sy / screenHeight * imageWidth
        // - iy = sx / screenWidth * imageHeight
        //
        // Note: Image Y increases downward, but screen X→image Y mapping
        // means screen left→image top, screen right→image bottom

        let imageMinX = Int(screenRect.minY / viewSize.height * imageSize.width)
        let imageMaxX = Int(screenRect.maxY / viewSize.height * imageSize.width)
        let imageMinY = Int(screenRect.minX / viewSize.width * imageSize.height)
        let imageMaxY = Int(screenRect.maxX / viewSize.width * imageSize.height)

        print("[ROIFilter] Image ROI bounds: x=\(imageMinX)-\(imageMaxX), y=\(imageMinY)-\(imageMaxY)")

        var filtered: [(x: Int, y: Int)] = []
        filtered.reserveCapacity(pixels.count)

        for pixel in pixels {
            if pixel.x >= imageMinX && pixel.x <= imageMaxX &&
               pixel.y >= imageMinY && pixel.y <= imageMaxY {
                filtered.append(pixel)
            }
        }

        print("[ROIFilter] Filtered from \(pixels.count) to \(filtered.count) pixels")
        return filtered
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

    /// Update measurement with an edited bounding box, preserving the original axis mapping
    /// - Parameters:
    ///   - boundingBox: The modified bounding box
    ///   - quality: The measurement quality
    ///   - axisMapping: The original axis mapping from the initial measurement
    /// - Returns: Updated MeasurementResult with recalculated dimensions
    func recalculate(
        boundingBox: BoundingBox3D,
        quality: MeasurementQuality,
        axisMapping: BoundingBox3D.AxisMapping
    ) -> MeasurementResult {
        let (height, length, width) = boundingBox.dimensions(withMapping: axisMapping)

        return MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: boundingBox.volume,
            quality: quality,
            heightAxisIndex: axisMapping.height,
            lengthAxisIndex: axisMapping.length,
            widthAxisIndex: axisMapping.width
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
        // Use larger threshold because point cloud can be sparse
        let neighborThreshold: Float = 0.08  // 8cm

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

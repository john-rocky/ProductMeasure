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

        // Enhanced pipeline: floor Y from nearest horizontal plane
        var detectedFloorY: Float?

        // Point cloud for Fit functionality
        var pointCloud: [SIMD3<Float>]?

        // Debug info
        #if DEBUG
        var debugMaskImage: UIImage?
        var debugDepthImage: UIImage?
        var debugPointCloud: [SIMD3<Float>]?
        #endif

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
#if DEBUG
        print("[Calculator] Starting measurement")
        print("[Calculator] Tap point: \(tapPoint), View size: \(viewSize)")
#endif

        // Branch to boundary-based pipeline for accurateSize
        if AppConstants.currentPipelineVersion.useBoundaryMeasurement {
            return try await measureFromBoundary(
                frame: frame,
                tapPoint: tapPoint,
                viewSize: viewSize,
                mode: mode,
                raycastHitPosition: raycastHitPosition
            )
        }

        // Convert tap point to normalized image coordinates (0-1)
        // Note: ARKit camera image is in landscape orientation
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
#if DEBUG
        print("[Calculator] Image size: \(imageSize)")
#endif

        // Convert screen coordinates to image coordinates
        // The AR view displays the camera in portrait, but the pixel buffer is landscape
        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint,
            viewSize: viewSize,
            imageSize: imageSize
        )
#if DEBUG
        print("[Calculator] Normalized tap point: \(normalizedTap)")
#endif

        // 1. Perform instance segmentation
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap,
            depthMap: frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        ) else {
#if DEBUG
            print("[Calculator] Segmentation failed - no instance found")
#endif
            return nil
        }
#if DEBUG
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")
#endif

        // Offload CPU-heavy processing (depth filter, point cloud, clustering, bbox) off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            // 2. Get masked pixels
            let maskedPixels = segmentationService.getMaskedPixels(
                mask: segmentation.mask,
                imageSize: imageSize
            )

            guard !maskedPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No masked pixels found")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(maskedPixels.count) masked pixels before depth filtering")
#endif

            let pipeline = AppConstants.currentPipelineVersion

            // 2b. Extract 2D connected component around tap point (separate non-touching objects)
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }

            // 2c. Refine mask by depth connectivity — separate touching objects
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels,
                    frame: frame,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }

            // 3. Filter masked pixels by depth - only keep pixels at similar depth to tap point
            let filteredPixels: [(x: Int, y: Int)]
            if pipeline.skipDepthFilter {
                filteredPixels = connectedPixels
#if DEBUG
                print("[Calculator] Depth filter skipped (accurateSize), using \(filteredPixels.count) pixels")
#endif
            } else {
                filteredPixels = filterMaskedPixelsByDepth(
                    maskedPixels: connectedPixels,
                    frame: frame,
                    tapPoint: normalizedTap,
                    imageSize: imageSize
                )
            }

            guard !filteredPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No pixels after depth filtering")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(filteredPixels.count) masked pixels after depth filtering")
#endif

            // Create debug mask image (memory-optimized version)
            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMask(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                tapPoint: normalizedTap
            )

            // Skip depth image to save memory
            let debugDepthImage: UIImage? = nil
            #endif

            // 4. Generate point cloud from filtered pixels
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame,
                maskedPixels: filteredPixels,
                imageSize: imageSize
            )

            guard !pointCloud.isEmpty else {
#if DEBUG
                print("[Calculator] Point cloud is empty")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")
#endif

            // 5. Filter point cloud by 3D distance from raycast hit position
            // This is CRITICAL - if no points are near the tap, the mask is wrong
            if let hitPosition = raycastHitPosition {
                // First check: is the raycast hit anywhere near the point cloud?
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
#if DEBUG
                print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")
#endif

                // If the nearest point is more than 2m away, the mask is completely wrong
                if nearestDistance > 2.0 {
#if DEBUG
                    print("[Calculator] ERROR: Mask does not contain tapped location. Nearest point is \(nearestDistance)m away.")
#endif
                    return nil
                }

                // Use adaptive radius based on point cloud spread
                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points,
                    center: hitPosition,
                    maxDistance: initialRadius
                )
#if DEBUG
                print("[Calculator] After initial \(initialRadius)m filter: \(filteredPoints.count) points")
#endif

                // Use clustering to find the connected object - this separates the tapped object from others
                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    if !pipeline.skipClustering {
                        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                        filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                        print("[Calculator] After clustering: \(filteredPoints.count) points")
#endif
                    }

                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Calculator] Too few points near tap location (\(filteredPoints.count))")
#endif
                    return nil
                }
            }

            // 6. Estimate bounding box (with vertical plane snap for box mode)
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }

            guard var boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: pointCloud.points,
                mode: mode,
                verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                print("[Calculator] Failed to estimate bounding box")
#endif
                return nil
            }

            // Apply size compensation to offset systematic LiDAR/segmentation bias
            let compensation = pipeline.sizeCompensationPerSide
            if compensation > 0 {
                boundingBox.extents.x += compensation
                boundingBox.extents.y += compensation
                boundingBox.extents.z += compensation
#if DEBUG
                print("[Calculator] Size compensation +\(compensation * 1000)mm/side applied")
#endif
            }

#if DEBUG
            print("[Calculator] Bounding box estimated")
            print("[Calculator] Box center: \(boundingBox.center)")
            print("[Calculator] Box extents: \(boundingBox.extents)")
#endif

            // 7. Calculate dimensions using camera-based axis mapping
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
            let volume = boundingBox.volume

#if DEBUG
            print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
            print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
            print("[Calculator] Volume: \(volume * 1_000_000) cm³")
#endif

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

            // Detect floor from horizontal plane (current pipelines only)
            if pipeline.useARPlaneFloor {
                result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)
            }

            // Attach debug info (images only, not point cloud to save memory)
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            result.debugDepthImage = debugDepthImage
            #endif

            return result
        }.value
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
#if DEBUG
        print("[Calculator] Starting ROI measurement")
        print("[Calculator] Screen ROI: \(regionOfInterest), View size: \(viewSize)")
#endif

        // Branch to boundary-based pipeline for accurateSize (using ROI center as tap point)
        if AppConstants.currentPipelineVersion.useBoundaryMeasurement {
            let boxCenter = CGPoint(x: regionOfInterest.midX, y: regionOfInterest.midY)
            return try await measureFromBoundary(
                frame: frame,
                tapPoint: boxCenter,
                viewSize: viewSize,
                mode: mode,
                raycastHitPosition: raycastHitPosition
            )
        }

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
#if DEBUG
        print("[Calculator] Image size: \(imageSize)")
#endif

        // Convert screen ROI to Vision normalized coordinates
        let visionROI = convertScreenRectToVisionCoordinates(
            screenRect: regionOfInterest,
            viewSize: viewSize
        )
#if DEBUG
        print("[Calculator] Vision ROI: \(visionROI)")
#endif

        // 1. Perform instance segmentation with ROI
        guard let segmentation = try await segmentationService.segmentInstanceWithROI(
            in: frame.capturedImage,
            regionOfInterest: visionROI
        ) else {
#if DEBUG
            print("[Calculator] Segmentation with ROI failed - no instance found")
#endif
            return nil
        }
#if DEBUG
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")
#endif

        // Pre-compute normalized center on calling thread (cheap)
        let boxCenter = CGPoint(x: regionOfInterest.midX, y: regionOfInterest.midY)
        let normalizedCenter = convertScreenToImageCoordinates(
            screenPoint: boxCenter,
            viewSize: viewSize,
            imageSize: imageSize
        )

        // Offload CPU-heavy processing off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            // 2. Get masked pixels with ROI coordinate transformation
            let maskedPixels = segmentationService.getMaskedPixelsWithROI(
                mask: segmentation.mask,
                imageSize: imageSize,
                visionROI: visionROI
            )

            guard !maskedPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No masked pixels found")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(maskedPixels.count) masked pixels")
#endif

            let pipeline = AppConstants.currentPipelineVersion

            // 3b. Extract 2D connected component around box center
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedCenter,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }

            // 3c. Refine mask by depth connectivity — separate touching objects
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels,
                    frame: frame,
                    seedPoint: normalizedCenter,
                    imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }

            // 4. Apply depth filtering based on box center
            let depthFilteredPixels: [(x: Int, y: Int)]
            if pipeline.skipDepthFilter {
                depthFilteredPixels = connectedPixels
#if DEBUG
                print("[Calculator] Depth filter skipped (accurateSize), using \(depthFilteredPixels.count) pixels")
#endif
            } else {
                depthFilteredPixels = filterMaskedPixelsByDepth(
                    maskedPixels: connectedPixels,
                    frame: frame,
                    tapPoint: normalizedCenter,
                    imageSize: imageSize
                )
            }

            guard !depthFilteredPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No pixels after depth filtering")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(depthFilteredPixels.count) masked pixels after depth filtering")
#endif

            // Create debug mask image with ROI
            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMaskWithROI(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                visionROI: visionROI,
                screenRect: regionOfInterest,
                viewSize: viewSize,
                tapPoint: normalizedCenter
            )
            #endif

            // 5. Generate point cloud
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame,
                maskedPixels: depthFilteredPixels,
                imageSize: imageSize
            )

            guard !pointCloud.isEmpty else {
#if DEBUG
                print("[Calculator] Point cloud is empty")
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")
#endif

            // 6. Filter by proximity if raycast hit available
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
#if DEBUG
                print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")
#endif

                if nearestDistance > 2.0 {
#if DEBUG
                    print("[Calculator] ERROR: Point cloud too far from raycast hit")
#endif
                    return nil
                }

                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points,
                    center: hitPosition,
                    maxDistance: initialRadius
                )
#if DEBUG
                print("[Calculator] After initial \(initialRadius)m filter: \(filteredPoints.count) points")
#endif

                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    if !pipeline.skipClustering {
                        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                        filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                        print("[Calculator] After clustering: \(filteredPoints.count) points")
#endif
                    }

                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Calculator] Too few points near box center (\(filteredPoints.count))")
#endif
                    return nil
                }
            }

            // 7. Estimate bounding box (with vertical plane snap for box mode)
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }

            guard var boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: pointCloud.points,
                mode: mode,
                verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                print("[Calculator] Failed to estimate bounding box")
#endif
                return nil
            }

            // Apply size compensation to offset systematic LiDAR/segmentation bias
            let compensation = pipeline.sizeCompensationPerSide
            if compensation > 0 {
                boundingBox.extents.x += compensation
                boundingBox.extents.y += compensation
                boundingBox.extents.z += compensation
#if DEBUG
                print("[Calculator] Size compensation +\(compensation * 1000)mm/side applied")
#endif
            }

#if DEBUG
            print("[Calculator] Bounding box estimated")
#endif

            // 8. Calculate dimensions using camera-based axis mapping
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
            let volume = boundingBox.volume

#if DEBUG
            print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
            print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
#endif

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
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            #endif

            // Detect floor from horizontal plane (current pipelines only)
            if pipeline.useARPlaneFloor {
                result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)
            }

            return result
        }.value
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

#if DEBUG
        print("[Coords] Screen rect: \(screenRect)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Vision ROI: x=\(normalizedX), y=\(normalizedY), w=\(normalizedWidth), h=\(normalizedHeight)")
#endif

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

#if DEBUG
        print("[ROIFilter] Image ROI bounds: x=\(imageMinX)-\(imageMaxX), y=\(imageMinY)-\(imageMaxY)")
#endif

        var filtered: [(x: Int, y: Int)] = []
        filtered.reserveCapacity(pixels.count)

        for pixel in pixels {
            if pixel.x >= imageMinX && pixel.x <= imageMaxX &&
               pixel.y >= imageMinY && pixel.y <= imageMaxY {
                filtered.append(pixel)
            }
        }

#if DEBUG
        print("[ROIFilter] Filtered from \(pixels.count) to \(filtered.count) pixels")
#endif
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

#if DEBUG
        print("[Coords] Screen point: \(screenPoint)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Image size: \(imageSize)")
        print("[Coords] Normalized tap (landscape image): (\(normalizedX), \(normalizedY))")
        print("[Coords] Image pixel: (\(normalizedX * imageSize.width), \(normalizedY * imageSize.height))")
#endif

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

    // MARK: - Refinement

    /// Point cloud captured from a refinement angle
    struct RefinementPointCloud {
        let points: [SIMD3<Float>]
        let quality: MeasurementQuality
        #if DEBUG
        var debugMaskImage: UIImage?
        #endif
    }

    /// Perform a refinement measurement: segment + point cloud only (no bounding box estimation).
    /// Validates that the new point cloud overlaps the existing bounding box.
    func measureForRefinement(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        existingBox: BoundingBox3D,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> RefinementPointCloud? {
#if DEBUG
        print("[Refine] Starting refinement measurement")
#endif

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )

        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint, viewSize: viewSize, imageSize: imageSize
        )

        // 1. Segmentation
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap,
            depthMap: frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        ) else {
#if DEBUG
            print("[Refine] Segmentation failed")
#endif
            return nil
        }

        // Offload CPU-heavy processing off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            // 2. Masked pixels
            let maskedPixels = segmentationService.getMaskedPixels(
                mask: segmentation.mask, imageSize: imageSize
            )
            guard !maskedPixels.isEmpty else { return nil }

            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMask(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                tapPoint: normalizedTap
            )
            #endif

            let pipeline = AppConstants.currentPipelineVersion

            // 2b. Extract 2D connected component around tap point
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }

            // 2c. Refine mask by depth connectivity
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels, frame: frame,
                    seedPoint: normalizedTap, imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }

            // 3. Depth filtering
            let filteredPixels: [(x: Int, y: Int)]
            if pipeline.skipDepthFilter {
                filteredPixels = connectedPixels
            } else {
                filteredPixels = filterMaskedPixelsByDepth(
                    maskedPixels: connectedPixels, frame: frame,
                    tapPoint: normalizedTap, imageSize: imageSize
                )
            }
            guard !filteredPixels.isEmpty else { return nil }

            // 4. Point cloud generation
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame, maskedPixels: filteredPixels, imageSize: imageSize
            )
            guard !pointCloud.isEmpty else { return nil }
#if DEBUG
            print("[Refine] Generated \(pointCloud.points.count) points")
#endif

            // 5. Proximity filter + clustering (same as measure())
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
                if nearestDistance > 2.0 { return nil }

                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points, center: hitPosition, maxDistance: initialRadius
                )

                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    if !pipeline.skipClustering {
                        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                        filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
                    }
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints, quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints, quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Refine] Too few points near tap (\(filteredPoints.count))")
#endif
                    return nil
                }
            }

            // 6. Same-object validation: check overlap with expanded existing box
            let expandedBox = Self.expandedBoundingBox(existingBox, scale: AppConstants.refinementProximityScale)
            let insideCount = pointCloud.points.filter { expandedBox.contains($0) }.count
            let overlapRatio = Float(insideCount) / Float(pointCloud.points.count)
#if DEBUG
            print("[Refine] Overlap ratio: \(overlapRatio) (\(insideCount)/\(pointCloud.points.count))")
#endif

            guard overlapRatio >= AppConstants.refinementOverlapThreshold else {
#if DEBUG
                print("[Refine] Overlap too low – object not matched")
#endif
                return nil
            }

            var result = RefinementPointCloud(points: pointCloud.points, quality: pointCloud.quality)
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            #endif
            return result
        }.value
    }

    // MARK: - Boundary-Based Measurement (accurateSize)

    /// Boundary-based measurement pipeline: uses mask boundary pixels + interior depth sampling.
    /// Instead of generating a full point cloud and filtering down, this extracts the object's
    /// silhouette edges directly — preserving edge geometry that traditional filters would remove.
    private func measureFromBoundary(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>?
    ) async throws -> MeasurementResult? {
#if DEBUG
        print("[BoundaryCalc] Starting boundary-based measurement")
#endif

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )

        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint,
            viewSize: viewSize,
            imageSize: imageSize
        )

        // 1. Segmentation (reuses existing instance segmentation)
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap,
            depthMap: frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        ) else {
#if DEBUG
            print("[BoundaryCalc] Segmentation failed")
#endif
            return nil
        }

        // Offload CPU-heavy processing off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            // 2. Extract boundary pixels (4-connected edge detection on mask)
            let boundaryPixels = segmentationService.getBoundaryPixels(
                mask: segmentation.mask,
                imageSize: imageSize
            )

            guard !boundaryPixels.isEmpty else {
#if DEBUG
                print("[BoundaryCalc] No boundary pixels found")
#endif
                return nil
            }

            // Compute mask center for interior depth sampling direction
            var sumX = 0, sumY = 0
            for px in boundaryPixels { sumX += px.x; sumY += px.y }
            let maskCenter = CGPoint(
                x: CGFloat(sumX) / CGFloat(boundaryPixels.count),
                y: CGFloat(sumY) / CGFloat(boundaryPixels.count)
            )

            // DEBUG: Compare boundary extent with standard getMaskedPixels extent
#if DEBUG
            let standardPixels = segmentationService.getMaskedPixels(
                mask: segmentation.mask,
                imageSize: imageSize
            )
            if !standardPixels.isEmpty && !boundaryPixels.isEmpty {
                let stdMinX = standardPixels.map { $0.x }.min()!
                let stdMaxX = standardPixels.map { $0.x }.max()!
                let stdMinY = standardPixels.map { $0.y }.min()!
                let stdMaxY = standardPixels.map { $0.y }.max()!
                let bndMinX = boundaryPixels.map { $0.x }.min()!
                let bndMaxX = boundaryPixels.map { $0.x }.max()!
                let bndMinY = boundaryPixels.map { $0.y }.min()!
                let bndMaxY = boundaryPixels.map { $0.y }.max()!
                print("[BoundaryCalc] DIAGNOSTIC — Standard masked pixels extent: x=\(stdMinX)-\(stdMaxX) (\(stdMaxX-stdMinX)px), y=\(stdMinY)-\(stdMaxY) (\(stdMaxY-stdMinY)px)")
                print("[BoundaryCalc] DIAGNOSTIC — Boundary pixels extent:        x=\(bndMinX)-\(bndMaxX) (\(bndMaxX-bndMinX)px), y=\(bndMinY)-\(bndMaxY) (\(bndMaxY-bndMinY)px)")
                print("[BoundaryCalc] DIAGNOSTIC — Ratio: x=\(Float(bndMaxX-bndMinX)/Float(max(1,stdMaxX-stdMinX))), y=\(Float(bndMaxY-bndMinY)/Float(max(1,stdMaxY-stdMinY)))")
                print("[BoundaryCalc] DIAGNOSTIC — Mask center (img px): (\(maskCenter.x), \(maskCenter.y))")
            }
#endif

            // 3. Sample interior depth for each boundary pixel (avoids edge bleeding)
            let allDepthSamples = sampleInteriorDepth(
                boundaryPixels: boundaryPixels,
                frame: frame,
                imageSize: imageSize,
                maskCenter: maskCenter
            )

            guard !allDepthSamples.isEmpty else {
#if DEBUG
                print("[BoundaryCalc] No valid depth samples")
#endif
                return nil
            }

            // 3b. Depth range filter: keep only boundary samples near the tap-point depth.
            // This removes floor/table/background boundary points while preserving all object edges.
            let tapDepth = Self.sampleTapDepth(
                normalizedTap: normalizedTap,
                frame: frame,
                imageSize: imageSize
            )

            let depthSamples: [(imageX: Int, imageY: Int, depth: Float)]
            if let tapDepth = tapDepth, tapDepth > 0 {
                // Tolerance: ±30% of tap depth (min 10cm) — generous enough for box front-to-back
                let tolerance = max(0.10, tapDepth * 0.30)
                depthSamples = allDepthSamples.filter {
                    abs($0.depth - tapDepth) <= tolerance
                }
#if DEBUG
                print("[BoundaryCalc] Depth filter: \(allDepthSamples.count) → \(depthSamples.count) (tapDepth=\(tapDepth)m, tol=±\(tolerance)m)")
#endif
            } else {
                depthSamples = allDepthSamples
#if DEBUG
                print("[BoundaryCalc] No tap depth available, skipping depth filter")
#endif
            }

            guard !depthSamples.isEmpty else {
#if DEBUG
                print("[BoundaryCalc] No samples after depth filter")
#endif
                return nil
            }
#if DEBUG
            print("[BoundaryCalc] \(depthSamples.count) depth samples from \(boundaryPixels.count) boundary pixels")
#endif

            // 4. Unproject boundary pixels to 3D world coordinates
            // Uses boundary pixel position (silhouette edge) + interior pixel depth (clean value)
            var points = PointCloudGenerator.unprojectImagePixelsToWorld(
                pixels: depthSamples,
                frame: frame
            )

            guard !points.isEmpty else {
#if DEBUG
                print("[BoundaryCalc] Unprojection produced no points")
#endif
                return nil
            }

            // 5. Proximity filter + clustering (isolate tapped object from surrounding surface)
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }

                if nearestDistance > 2.0 {
#if DEBUG
                    print("[BoundaryCalc] Points too far from raycast hit: \(nearestDistance)m")
#endif
                    return nil
                }

                // Adaptive proximity filter
                let pointSpread = Self.estimatePointSpread(points: points)
                let radius: Float = max(0.5, pointSpread * 0.8)
                var filtered = filterPointsByProximity(
                    points: points,
                    center: hitPosition,
                    maxDistance: radius
                )

                // 3D clustering: separates object boundary from surrounding surface boundary.
                // Even when depths match (top-down view), world-Y differs by box height.
                if filtered.count >= 15 {
                    let camPos = SIMD3<Float>(
                        frame.camera.transform.columns.3.x,
                        frame.camera.transform.columns.3.y,
                        frame.camera.transform.columns.3.z
                    )
                    let clustered = extractMainCluster(
                        points: filtered,
                        center: hitPosition,
                        cameraPosition: camPos
                    )
                    if clustered.count >= 10 {
                        filtered = clustered
#if DEBUG
                        print("[BoundaryCalc] After clustering: \(filtered.count) points")
#endif
                    }
                }

                if filtered.count >= 10 {
                    points = filtered
                }
            }

            // 6. Estimate bounding box (reuses existing MABR + plane snap)
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }

            guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: points,
                mode: mode,
                verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                print("[BoundaryCalc] Failed to estimate bounding box")
#endif
                return nil
            }

            // 7. Calculate dimensions with camera-based axis mapping
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)

#if DEBUG
            print("[BoundaryCalc] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
#endif

            var result = MeasurementResult(
                boundingBox: boundingBox,
                length: length,
                width: width,
                height: height,
                volume: boundingBox.volume,
                quality: MeasurementQuality(
                    depthCoverage: Float(depthSamples.count) / Float(max(boundaryPixels.count, 1)),
                    depthConfidence: 0.8,
                    pointCount: points.count,
                    trackingState: frame.camera.trackingState
                ),
                heightAxisIndex: mapping.height,
                lengthAxisIndex: mapping.length,
                widthAxisIndex: mapping.width
            )

            result.pointCloud = points

            // 8. Floor detection from horizontal AR planes
            result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)

            #if DEBUG
            result.debugMaskImage = DebugVisualization.visualizeMask(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                tapPoint: normalizedTap
            )
            #endif

            return result
        }.value
    }

    /// Sample depth from interior pixels for boundary pixels.
    /// For each boundary pixel, moves 1-3 depth pixels toward the mask center
    /// to avoid edge-bleeding artifacts in the LiDAR depth map.
    private func sampleInteriorDepth(
        boundaryPixels: [(x: Int, y: Int)],
        frame: ARFrame,
        imageSize: CGSize,
        maskCenter: CGPoint
    ) -> [(imageX: Int, imageY: Int, depth: Float)] {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
        let depthMap = depthData.depthMap
        guard let confidenceMap = depthData.confidenceMap else { return [] }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return [] }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr = confBase.assumingMemoryBound(to: UInt8.self)
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        // Mask center in depth map coordinates
        let centerDX = Float(maskCenter.x * scaleX)
        let centerDY = Float(maskCenter.y * scaleY)

        // Helper: read depth + confidence at depth map coordinates
        func depthAt(dx: Int, dy: Int) -> (depth: Float, confident: Bool)? {
            guard dx >= 0 && dx < depthWidth && dy >= 0 && dy < depthHeight else { return nil }
            let depth = depthPtr[dy * depthStride + dx]
            let conf = confPtr[dy * confBytesPerRow + dx]
            guard depth.isFinite && depth > 0 else { return nil }
            return (depth, conf >= ARConfidenceLevel.medium.rawValue)
        }

        var results: [(imageX: Int, imageY: Int, depth: Float)] = []
        results.reserveCapacity(boundaryPixels.count)

        for pixel in boundaryPixels {
            let dx = Int(CGFloat(pixel.x) * scaleX)
            let dy = Int(CGFloat(pixel.y) * scaleY)

            // Direction from boundary pixel toward mask center (in depth map coords)
            let dirX = centerDX - Float(dx)
            let dirY = centerDY - Float(dy)
            let dirLen = sqrt(dirX * dirX + dirY * dirY)
            guard dirLen > 0 else { continue }
            let ndirX = dirX / dirLen
            let ndirY = dirY / dirLen

            // Try 1-3 pixels inward along the direction toward mask center
            var foundDepth: Float? = nil
            for offset in 1...3 {
                let sampleDX = dx + Int(Float(offset) * ndirX)
                let sampleDY = dy + Int(Float(offset) * ndirY)
                if let (d, confident) = depthAt(dx: sampleDX, dy: sampleDY), confident {
                    foundDepth = d
                    break
                }
            }

            // Fallback: 3×3 median around the boundary pixel
            if foundDepth == nil {
                var neighbors: [Float] = []
                for oy in -1...1 {
                    for ox in -1...1 {
                        if let (d, _) = depthAt(dx: dx + ox, dy: dy + oy) {
                            neighbors.append(d)
                        }
                    }
                }
                if !neighbors.isEmpty {
                    neighbors.sort()
                    foundDepth = neighbors[neighbors.count / 2]
                }
            }

            if let depth = foundDepth {
                results.append((imageX: pixel.x, imageY: pixel.y, depth: depth))
            }
        }

#if DEBUG
        print("[BoundaryDepth] Sampled \(results.count) of \(boundaryPixels.count) boundary pixels with valid depth")
#endif

        return results
    }

    /// Sample depth at the tap point from the depth map
    private static func sampleTapDepth(
        normalizedTap: CGPoint,
        frame: ARFrame,
        imageSize: CGSize
    ) -> Float? {
        guard let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        let tapDX = Int(normalizedTap.x * imageSize.width * scaleX)
        let tapDY = Int(normalizedTap.y * imageSize.height * scaleY)

        guard tapDX >= 0 && tapDX < depthWidth && tapDY >= 0 && tapDY < depthHeight else { return nil }

        let depth = depthPtr[tapDY * (depthBytesPerRow / MemoryLayout<Float32>.size) + tapDX]
        return (depth.isFinite && depth > 0) ? depth : nil
    }

    /// Expand a bounding box by scaling its extents
    static func expandedBoundingBox(_ box: BoundingBox3D, scale: Float) -> BoundingBox3D {
        var expanded = box
        expanded.extents = box.extents * scale
        return expanded
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
        let pipelineForDepth = AppConstants.currentPipelineVersion
        let depthSourceForFilter: ARDepthData? = pipelineForDepth.useRawDepth
            ? (frame.sceneDepth ?? frame.smoothedSceneDepth)
            : (frame.smoothedSceneDepth ?? frame.sceneDepth)
        guard let depthMap = depthSourceForFilter?.depthMap else {
#if DEBUG
            print("[DepthFilter] No depth map available, returning all pixels")
#endif
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
#if DEBUG
            print("[DepthFilter] Tap point out of depth map bounds")
#endif
            return maskedPixels
        }

        let tapDepthIndex = tapDepthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + tapDepthX
        let tapDepth = depthPtr[tapDepthIndex]

#if DEBUG
        print("[DepthFilter] Tap depth: \(tapDepth)m at depth pixel (\(tapDepthX), \(tapDepthY))")
#endif

        guard tapDepth.isFinite && tapDepth > 0 else {
#if DEBUG
            print("[DepthFilter] Invalid tap depth, returning all pixels")
#endif
            return maskedPixels
        }

        // Filter pixels by depth - keep those within a tolerance of tap depth
        let pipeline = AppConstants.currentPipelineVersion
        let percentTolerance = tapDepth * pipeline.depthFilterPercent
        let depthTolerance: Float
        if let maxTol = pipeline.depthFilterMax {
            depthTolerance = min(max(percentTolerance, pipeline.depthFilterMin), maxTol)
        } else {
            depthTolerance = max(percentTolerance, pipeline.depthFilterMin)  // v1: no max clamp
        }

#if DEBUG
        print("[DepthFilter] Depth tolerance: ±\(depthTolerance)m (percent=\(pipeline.depthFilterPercent), min=\(pipeline.depthFilterMin), max=\(pipeline.depthFilterMax as Any))")
#endif

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

#if DEBUG
        print("[DepthFilter] Filtered from \(maskedPixels.count) to \(filteredPixels.count) pixels")
#endif

        // Safety valve: behavior differs by pipeline version
        if pipeline.depthFilterReturnsOriginalOnTooFew {
            // Legacy: if too few pass filter, return original pixels
            if filteredPixels.count < 100 {
#if DEBUG
                print("[DepthFilter] Too few pixels after filtering (\(filteredPixels.count) < 100), returning original \(maskedPixels.count) pixels")
#endif
                return maskedPixels
            }
        } else {
            // Current: proportional minimum, return empty on failure
            let minRequired = max(20, maskedPixels.count / 20)
            if filteredPixels.count < minRequired {
#if DEBUG
                print("[DepthFilter] Too few pixels after filtering (\(filteredPixels.count) < \(minRequired)), returning empty")
#endif
                return []
            }
        }

        return filteredPixels
    }

    /// Refine masked pixels by depth-based connected-component analysis.
    /// Keeps only the connected region around the seed pixel where depth is continuous.
    /// This separates objects that Vision grouped into a single instance but differ in depth.
    private func refineMaskedPixelsByDepthConnectivity(
        maskedPixels: [(x: Int, y: Int)],
        frame: ARFrame,
        seedPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
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
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        // Build spatial hash for fast neighbor lookup (cell size in image pixels)
        let cellSize = AppConstants.depthConnectivityCellSize
        struct Cell: Hashable { let x, y: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(maskedPixels.count / 4)
        for (i, px) in maskedPixels.enumerated() {
            let cell = Cell(x: px.x / cellSize, y: px.y / cellSize)
            grid[cell, default: []].append(i)
        }

        // Find seed: closest masked pixel to seedPoint (in image coordinates)
        let seedImgX = Int(seedPoint.x * imageSize.width)
        let seedImgY = Int(seedPoint.y * imageSize.height)
        var seedIdx = 0
        var minDist = Int.max
        for (i, px) in maskedPixels.enumerated() {
            let d = abs(px.x - seedImgX) + abs(px.y - seedImgY)
            if d < minDist { minDist = d; seedIdx = i }
        }

        // Get seed depth
        let seedPx = maskedPixels[seedIdx]
        let seedDX = Int(CGFloat(seedPx.x) * scaleX)
        let seedDY = Int(CGFloat(seedPx.y) * scaleY)
        guard seedDX >= 0 && seedDX < depthWidth && seedDY >= 0 && seedDY < depthHeight else {
            return maskedPixels
        }
        let seedDepth = depthPtr[seedDY * depthStride + seedDX]
        guard seedDepth.isFinite && seedDepth > 0 else { return maskedPixels }

        let pipeline = AppConstants.currentPipelineVersion
        let seedTolerance = seedDepth * pipeline.depthConnectivitySeedTolerance
        let localTolerance = pipeline.depthConnectivityLocalTolerance

        // Helper: get depth for a masked pixel
        func depthAt(_ px: (x: Int, y: Int)) -> Float? {
            let dx = Int(CGFloat(px.x) * scaleX)
            let dy = Int(CGFloat(px.y) * scaleY)
            guard dx >= 0 && dx < depthWidth && dy >= 0 && dy < depthHeight else { return nil }
            let d = depthPtr[dy * depthStride + dx]
            return (d.isFinite && d > 0) ? d : nil
        }

        // Flood-fill through spatial hash neighbors
        var visited = [Bool](repeating: false, count: maskedPixels.count)
        var frontier: [Int] = [seedIdx]
        visited[seedIdx] = true
        var result: [Int] = [seedIdx]

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let px = maskedPixels[idx]
            guard let currentDepth = depthAt(px) else { continue }

            let cx = px.x / cellSize
            let cy = px.y / cellSize

            // Check 3x3 neighboring cells
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let neighbors = grid[Cell(x: cx + dx, y: cy + dy)] else { continue }
                    for ni in neighbors {
                        if visited[ni] { continue }
                        guard let neighborDepth = depthAt(maskedPixels[ni]) else { continue }

                        // (a) Within seed depth tolerance (global)
                        let seedDiff = abs(neighborDepth - seedDepth)
                        guard seedDiff <= seedTolerance else { continue }

                        // (b) Within local continuity tolerance
                        let localDiff = abs(neighborDepth - currentDepth)
                        guard localDiff <= currentDepth * localTolerance else { continue }

                        visited[ni] = true
                        frontier.append(ni)
                        result.append(ni)
                    }
                }
            }
        }

        let refined = result.map { maskedPixels[$0] }

#if DEBUG
        print("[DepthConnectivity] Seed depth: \(seedDepth)m, tolerance: ±\(seedTolerance)m")
        print("[DepthConnectivity] Refined from \(maskedPixels.count) to \(refined.count) pixels")
#endif

        // Safety: if too few pixels remain, skip refinement
        let minRetain = Int(Float(maskedPixels.count) * AppConstants.depthConnectivityMinRetainRatio)
        if refined.count < minRetain {
#if DEBUG
            print("[DepthConnectivity] Too few pixels retained (\(refined.count) < \(minRetain)), skipping refinement")
#endif
            return maskedPixels
        }

        return refined
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
#if DEBUG
        print("[ProximityFilter] Filtering \(points.count) points around center: \(center)")
        print("[ProximityFilter] Max distance: \(maxDistance)m")
#endif

        var filteredPoints: [SIMD3<Float>] = []
        filteredPoints.reserveCapacity(points.count)
        var minDist: Float = .infinity, maxDist: Float = 0, totalDist: Float = 0

        for point in points {
            let d = simd_distance(point, center)
            minDist = min(minDist, d); maxDist = max(maxDist, d); totalDist += d
            if d <= maxDistance {
                filteredPoints.append(point)
            }
        }

        if !points.isEmpty {
#if DEBUG
            print("[ProximityFilter] Distance stats - min: \(minDist)m, max: \(maxDist)m, avg: \(totalDist / Float(points.count))m")
#endif
        }
#if DEBUG
        print("[ProximityFilter] Kept \(filteredPoints.count) of \(points.count) points")
#endif

        return filteredPoints
    }

    /// Extract the main cluster of points around the center using spatial-hash flood-fill
    /// This helps isolate the tapped object from other nearby objects
    private func extractMainCluster(points: [SIMD3<Float>], center: SIMD3<Float>, cameraPosition: SIMD3<Float>? = nil) -> [SIMD3<Float>] {
        let pipeline = AppConstants.currentPipelineVersion
        guard points.count > pipeline.clusteringGuardMinPoints else { return points }

#if DEBUG
        print("[Clustering] Starting with \(points.count) points")
#endif

        // Determine clustering threshold based on pipeline version
        let neighborThreshold: Float
        if pipeline.useStatisticalClustering {
            // k-NN MAD statistical threshold (standard)
            neighborThreshold = computeKNNThreshold(points: points, pipeline: pipeline)
        } else if let fixed = pipeline.clusteringFixedThreshold {
            neighborThreshold = fixed
        } else {
            // Depth-adaptive (enhanced only)
            let medianDepth = estimateMedianDepth(points: points, cameraPosition: cameraPosition)
            let adaptive = AppConstants.clusteringBaseOffset + medianDepth * AppConstants.clusteringDepthScale
            neighborThreshold = min(max(adaptive, AppConstants.clusteringMinThreshold), AppConstants.clusteringMaxThreshold)
#if DEBUG
            print("[Clustering] Depth-adaptive threshold: \(neighborThreshold * 100)cm (medianDepth=\(medianDepth)m)")
#endif
        }
        let cellSize = neighborThreshold

        // Build spatial hash grid: cell → [point indices]
        struct Cell: Hashable { let x, y, z: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(points.count / 2)
        for (i, p) in points.enumerated() {
            let cell = Cell(x: Int(floor(p.x / cellSize)),
                            y: Int(floor(p.y / cellSize)),
                            z: Int(floor(p.z / cellSize)))
            grid[cell, default: []].append(i)
        }

        // Find seed (closest to center)
        var seedIdx = 0
        var minDist = simd_distance(points[0], center)
        for (i, p) in points.enumerated() {
            let d = simd_distance(p, center)
            if d < minDist { minDist = d; seedIdx = i }
        }
#if DEBUG
        print("[Clustering] Seed point at distance \(minDist)m from center")
#endif

        // Flood-fill using grid neighbors only (DFS with stack)
        var inCluster = [Bool](repeating: false, count: points.count)
        var frontier: [Int] = [seedIdx]
        inCluster[seedIdx] = true
        var clusterCount = 1

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let p = points[idx]
            let cx = Int(floor(p.x / cellSize))
            let cy = Int(floor(p.y / cellSize))
            let cz = Int(floor(p.z / cellSize))

            // Check only 27 neighboring cells
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let neighbors = grid[Cell(x: cx+dx, y: cy+dy, z: cz+dz)] else { continue }
                        for ni in neighbors {
                            if inCluster[ni] { continue }
                            if simd_distance(p, points[ni]) <= neighborThreshold {
                                inCluster[ni] = true
                                frontier.append(ni)
                                clusterCount += 1
                            }
                        }
                    }
                }
            }

            // Stop if cluster is getting too large (performance)
            if clusterCount > 10000 { break }
        }

        let clusterPoints = (0..<points.count).compactMap { inCluster[$0] ? points[$0] : nil }
#if DEBUG
        print("[Clustering] Extracted cluster with \(clusterPoints.count) points")
#endif

        // If cluster is too small, return original
        if clusterPoints.count < pipeline.clusteringGuardMinPoints {
#if DEBUG
            print("[Clustering] Cluster too small (\(clusterPoints.count) < \(pipeline.clusteringGuardMinPoints)), returning original points")
#endif
            return points
        }

        return clusterPoints
    }

    /// Estimate median depth (distance from camera) of point cloud
    private func estimateMedianDepth(points: [SIMD3<Float>], cameraPosition: SIMD3<Float>?) -> Float {
        guard !points.isEmpty else { return 1.0 }
        let origin = cameraPosition ?? .zero
        var distances = points.map { simd_distance($0, origin) }
        distances.sort()
        return distances[distances.count / 2]
    }

    /// Compute clustering threshold from k-NN distance distribution using MAD.
    /// Falls back to fixed 4cm when point count is insufficient.
    private func computeKNNThreshold(points: [SIMD3<Float>], pipeline: PipelineVersion) -> Float {
        let k = pipeline.clusteringKnnK
        let madMultiplier = pipeline.clusteringKnnMADMultiplier
        let gridCell = pipeline.clusteringKnnSearchRadius

        // Need at least 2*k points for meaningful statistics
        guard points.count >= 2 * k else {
#if DEBUG
            print("[Clustering] Too few points (\(points.count)) for k-NN, using fixed 4cm")
#endif
            return 0.04
        }

        // Subsample for performance if needed
        let maxSample = 5000
        let samplePoints: [SIMD3<Float>]
        if points.count > maxSample {
            var rng = SystemRandomNumberGenerator()
            samplePoints = Array(points.shuffled(using: &rng).prefix(maxSample))
        } else {
            samplePoints = points
        }

        // Build spatial hash grid for k-NN search
        struct Cell: Hashable { let x, y, z: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(samplePoints.count / 2)
        for (i, p) in samplePoints.enumerated() {
            let cell = Cell(x: Int(floor(p.x / gridCell)),
                            y: Int(floor(p.y / gridCell)),
                            z: Int(floor(p.z / gridCell)))
            grid[cell, default: []].append(i)
        }

        // Compute k-th nearest neighbor distance for each sample point
        var knnDistances: [Float] = []
        knnDistances.reserveCapacity(samplePoints.count)

        for (i, p) in samplePoints.enumerated() {
            let cx = Int(floor(p.x / gridCell))
            let cy = Int(floor(p.y / gridCell))
            let cz = Int(floor(p.z / gridCell))

            // Collect distances from neighboring cells
            var distances: [Float] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let neighbors = grid[Cell(x: cx+dx, y: cy+dy, z: cz+dz)] else { continue }
                        for ni in neighbors {
                            if ni == i { continue }
                            distances.append(simd_distance(p, samplePoints[ni]))
                        }
                    }
                }
            }

            guard distances.count >= k else {
                // Not enough neighbors in grid range; skip this point
                continue
            }
            distances.sort()
            knnDistances.append(distances[k - 1])
        }

        guard knnDistances.count >= k else {
#if DEBUG
            print("[Clustering] Insufficient k-NN data, using fixed 4cm")
#endif
            return 0.04
        }

        // MAD-based threshold: median + MAD * multiplier * 1.4826
        knnDistances.sort()
        let median = knnDistances[knnDistances.count / 2]
        let deviations = knnDistances.map { abs($0 - median) }
        let sortedDeviations = deviations.sorted()
        let mad = sortedDeviations[sortedDeviations.count / 2]
        let threshold = median + mad * madMultiplier * 1.4826

        // Clamp to [clusteringMinThreshold, clusteringMaxThreshold]
        let clamped = min(max(threshold, AppConstants.clusteringMinThreshold), AppConstants.clusteringMaxThreshold)

#if DEBUG
        print("[Clustering] k-NN statistical threshold: \(clamped * 100)cm (median=\(median * 100)cm, MAD=\(mad * 100)cm, raw=\(threshold * 100)cm)")
#endif
        return clamped
    }

    /// Detect floor Y from horizontal ARPlaneAnchor below the object
    /// Filters to planes below the bounding box center and picks the lowest Y (actual floor)
    static func detectHorizontalPlaneFloorY(frame: ARFrame, nearPoint: SIMD3<Float>) -> Float? {
        let horizontalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return plane
        }
        guard !horizontalPlanes.isEmpty else { return nil }

        // Filter to planes below the bounding box center (floor is below the object)
        // and within 3m XZ distance
        var candidatePlanes: [(plane: ARPlaneAnchor, y: Float, xzDist: Float)] = []
        for plane in horizontalPlanes {
            let planeY = plane.transform.columns.3.y
            // Only consider planes below the object center
            guard planeY < nearPoint.y else { continue }

            let xzDist = simd_distance(
                SIMD2<Float>(nearPoint.x, nearPoint.z),
                SIMD2<Float>(plane.transform.columns.3.x, plane.transform.columns.3.z)
            )
            guard xzDist < 3.0 else { continue }
            candidatePlanes.append((plane: plane, y: planeY, xzDist: xzDist))
        }

        // Pick the lowest Y plane (actual floor, not table)
        guard let best = candidatePlanes.min(by: { $0.y < $1.y }) else { return nil }
        let floorY = best.y
#if DEBUG
        print("[Calculator] Horizontal plane floor detected: y=\(floorY) (xzDist=\(best.xzDist)m, candidates=\(candidatePlanes.count))")
#endif
        return floorY
    }

    /// Extract the 2D connected component containing the seed point from the mask.
    /// Uses spatial-hash flood-fill (no depth checks) to separate non-touching objects
    /// that Vision may have merged into a single instance.
    private func extractConnectedComponent(
        maskedPixels: [(x: Int, y: Int)],
        seedPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard maskedPixels.count > 10 else { return maskedPixels }

        let cellSize = AppConstants.depthConnectivityCellSize
        struct Cell: Hashable { let x, y: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(maskedPixels.count / 4)
        for (i, px) in maskedPixels.enumerated() {
            let cell = Cell(x: px.x / cellSize, y: px.y / cellSize)
            grid[cell, default: []].append(i)
        }

        // Find seed: closest masked pixel to seedPoint (in image coordinates)
        let seedImgX = Int(seedPoint.x * imageSize.width)
        let seedImgY = Int(seedPoint.y * imageSize.height)
        var seedIdx = 0
        var minDist = Int.max
        for (i, px) in maskedPixels.enumerated() {
            let d = abs(px.x - seedImgX) + abs(px.y - seedImgY)
            if d < minDist { minDist = d; seedIdx = i }
        }

        // Flood-fill through spatial hash neighbors (pure 2D, no depth)
        var visited = [Bool](repeating: false, count: maskedPixels.count)
        var frontier: [Int] = [seedIdx]
        visited[seedIdx] = true
        var result: [Int] = [seedIdx]

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let px = maskedPixels[idx]
            let cx = px.x / cellSize
            let cy = px.y / cellSize

            for dx in -1...1 {
                for dy in -1...1 {
                    guard let neighbors = grid[Cell(x: cx + dx, y: cy + dy)] else { continue }
                    for ni in neighbors {
                        if visited[ni] { continue }
                        visited[ni] = true
                        frontier.append(ni)
                        result.append(ni)
                    }
                }
            }
        }

        let connected = result.map { maskedPixels[$0] }

#if DEBUG
        print("[2DCC] Connected component: \(connected.count) of \(maskedPixels.count) pixels")
#endif

        // Safety: if less than 5% retained, skip (mask might be sparse)
        if connected.count < maskedPixels.count / 20 {
#if DEBUG
            print("[2DCC] Too few pixels retained (\(connected.count)), skipping 2D CC")
#endif
            return maskedPixels
        }

        return connected
    }

    /// Estimate the spatial spread (max extent) of a point cloud
    static func estimatePointSpread(points: [SIMD3<Float>]) -> Float {
        guard let first = points.first else { return 1.0 }
        var minP = first
        var maxP = first
        for p in points {
            minP = min(minP, p)
            maxP = max(maxP, p)
        }
        let extent = maxP - minP
        return max(extent.x, extent.y, extent.z)
    }
}

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
    /// - Returns: MeasurementResult if successful
    func measure(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode
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

        // Debug: Create mask visualization
        let debugMaskImage = DebugVisualization.visualizeMask(
            mask: segmentation.mask,
            cameraImage: frame.capturedImage,
            tapPoint: normalizedTap
        )

        // 2. Get masked pixels
        let maskedPixels = segmentationService.getMaskedPixels(
            mask: segmentation.mask,
            imageSize: imageSize
        )

        guard !maskedPixels.isEmpty else {
            print("[Calculator] No masked pixels found")
            return nil
        }
        print("[Calculator] Found \(maskedPixels.count) masked pixels")

        // Debug: Create depth visualization
        var debugDepthImage: UIImage?
        if let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap {
            debugDepthImage = DebugVisualization.visualizeDepthMap(
                depthMap: depthMap,
                maskedPixels: maskedPixels,
                imageSize: imageSize
            )
        }

        // 3. Generate point cloud
        let pointCloud = pointCloudGenerator.generatePointCloud(
            frame: frame,
            maskedPixels: maskedPixels,
            imageSize: imageSize
        )

        guard !pointCloud.isEmpty else {
            print("[Calculator] Point cloud is empty")
            return nil
        }
        print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")

        // 4. Estimate bounding box
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

        // 5. Calculate dimensions
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

        // Attach debug info
        result.debugMaskImage = debugMaskImage
        result.debugDepthImage = debugDepthImage
        result.debugPointCloud = pointCloud.points

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

    /// Calculate volume from dimensions
    static func calculateVolume(length: Float, width: Float, height: Float) -> Float {
        length * width * height
    }
}

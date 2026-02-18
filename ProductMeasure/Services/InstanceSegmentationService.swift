//
//  InstanceSegmentationService.swift
//  ProductMeasure
//

import Vision
import CoreImage
import UIKit
import ARKit

/// Service for performing instance segmentation using Vision framework
class InstanceSegmentationService {
    // MARK: - Types

    struct SegmentationResult {
        /// The mask for the selected instance (CVPixelBuffer)
        let mask: CVPixelBuffer

        /// Bounding box of the instance in normalized coordinates (0-1)
        let boundingBox: CGRect

        /// Size of the mask
        let maskSize: CGSize
    }

    // MARK: - Properties

    private let ciContext = CIContext()

    // MARK: - Public Methods

    /// Segment the foreground object at the given tap location
    /// - Parameters:
    ///   - pixelBuffer: The camera image pixel buffer
    ///   - tapPoint: Tap location in normalized image coordinates (0-1, origin top-left)
    /// - Returns: SegmentationResult if an instance is found at the tap point
    func segmentInstance(
        in pixelBuffer: CVPixelBuffer,
        at tapPoint: CGPoint
    ) async throws -> SegmentationResult? {
#if DEBUG
        print("[Segmentation] Starting segmentation at point: \(tapPoint)")
#endif

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
#if DEBUG
        print("[Segmentation] Input image size: \(imageWidth)x\(imageHeight)")
#endif

        // Create the foreground instance mask request (iOS 17+)
        let request = VNGenerateForegroundInstanceMaskRequest()

        // Use .up orientation - process image as-is
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        try handler.perform([request])

        guard let observation = request.results?.first else {
#if DEBUG
            print("[Segmentation] No observation results")
#endif
            return nil
        }

        let allInstances = observation.allInstances
#if DEBUG
        print("[Segmentation] Found \(allInstances.count) instances")
#endif

        guard !allInstances.isEmpty else {
#if DEBUG
            print("[Segmentation] No instances found")
#endif
            return nil
        }

        // Try to isolate the specific instance the user tapped
        let tappedInstanceId = findInstance(at: tapPoint, in: observation, from: handler)

        let instancesToMask: IndexSet
        if let instanceId = tappedInstanceId {
            instancesToMask = IndexSet([instanceId])
#if DEBUG
            print("[Segmentation] Using tapped instance \(instanceId)")
#endif
        } else {
            // Fallback: use all instances — depth connectivity refinement will separate objects
            instancesToMask = IndexSet(allInstances)
#if DEBUG
            print("[Segmentation] No instance at tap point, falling back to ALL \(allInstances.count) instances")
#endif
        }

        // Generate mask for selected instance(s)
        do {
            let instanceMask = try observation.generateMaskedImage(
                ofInstances: instancesToMask,
                from: handler,
                croppedToInstancesExtent: false
            )

            let maskSize = CGSize(
                width: CVPixelBufferGetWidth(instanceMask),
                height: CVPixelBufferGetHeight(instanceMask)
            )
#if DEBUG
            print("[Segmentation] Generated mask size: \(maskSize)")
            print("[Segmentation] Mask is in portrait orientation (rotated from camera)")
#endif

            return SegmentationResult(
                mask: instanceMask,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                maskSize: maskSize
            )
        } catch {
#if DEBUG
            print("[Segmentation] Failed to generate mask: \(error)")
#endif
            throw error
        }
    }

    /// Segment the foreground object within a specific region of interest
    /// - Parameters:
    ///   - pixelBuffer: The camera image pixel buffer
    ///   - regionOfInterest: ROI in normalized image coordinates (0-1, origin bottom-left for Vision)
    /// - Returns: SegmentationResult if an instance is found in the ROI
    func segmentInstanceWithROI(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect
    ) async throws -> SegmentationResult? {
#if DEBUG
        print("[Segmentation] Starting segmentation with ROI: \(regionOfInterest)")
#endif

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
#if DEBUG
        print("[Segmentation] Input image size: \(imageWidth)x\(imageHeight)")
#endif

        // Create the foreground instance mask request with ROI
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.regionOfInterest = regionOfInterest

        // Use .up orientation - process image as-is
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        try handler.perform([request])

        guard let observation = request.results?.first else {
#if DEBUG
            print("[Segmentation] No observation results with ROI")
#endif
            return nil
        }

        let allInstances = observation.allInstances
#if DEBUG
        print("[Segmentation] Found \(allInstances.count) instances in ROI")
#endif

        guard !allInstances.isEmpty else {
#if DEBUG
            print("[Segmentation] No instances found in ROI")
#endif
            return nil
        }

#if DEBUG
        print("[Segmentation] Using ALL \(allInstances.count) instances from ROI")
#endif

        do {
            let instanceMask = try observation.generateMaskedImage(
                ofInstances: IndexSet(allInstances),
                from: handler,
                croppedToInstancesExtent: false
            )

            let maskSize = CGSize(
                width: CVPixelBufferGetWidth(instanceMask),
                height: CVPixelBufferGetHeight(instanceMask)
            )
#if DEBUG
            print("[Segmentation] Generated mask size: \(maskSize)")
#endif

            return SegmentationResult(
                mask: instanceMask,
                boundingBox: regionOfInterest,
                maskSize: maskSize
            )
        } catch {
#if DEBUG
            print("[Segmentation] Failed to generate mask with ROI: \(error)")
#endif
            throw error
        }
    }

    // MARK: - Private Methods

    /// Find which instance the user tapped by generating per-instance masks
    /// and checking coverage near the tap point.
    /// Uses generateMaskedImage (proven reliable) instead of generateScaledMaskForImage.
    private func findInstance(
        at point: CGPoint,
        in observation: VNInstanceMaskObservation,
        from handler: VNImageRequestHandler
    ) -> Int? {
        let allInstances = observation.allInstances
        guard !allInstances.isEmpty else { return nil }

#if DEBUG
        print("[Segmentation] Finding instance at normalized point: \(point)")
        print("[Segmentation] All instances: \(Array(allInstances))")
#endif

        var bestInstance: Int? = nil
        var bestScore = 0

        for instanceId in allInstances {
            guard let mask = try? observation.generateMaskedImage(
                ofInstances: IndexSet([instanceId]),
                from: handler,
                croppedToInstancesExtent: false
            ) else {
#if DEBUG
                print("[Segmentation] Failed to generate mask for instance \(instanceId)")
#endif
                continue
            }

            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

            let width = CVPixelBufferGetWidth(mask)
            let height = CVPixelBufferGetHeight(mask)

            guard let base = CVPixelBufferGetBaseAddress(mask) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
            let pixelFormat = CVPixelBufferGetPixelFormatType(mask)
            let buffer = base.assumingMemoryBound(to: UInt8.self)

            let bytesPerPixel = (pixelFormat == kCVPixelFormatType_32BGRA ||
                                 pixelFormat == kCVPixelFormatType_32ARGB) ? 4 : 1

            let cx = Int(point.x * CGFloat(width))
            let cy = Int(point.y * CGFloat(height))

            // Search radius proportional to mask size (~5%)
            let searchRadius = max(10, max(width, height) / 20)
            let step = max(1, searchRadius / 15)
            var score = 0

            for dy in Swift.stride(from: -searchRadius, through: searchRadius, by: step) {
                for dx in Swift.stride(from: -searchRadius, through: searchRadius, by: step) {
                    let px = cx + dx
                    let py = cy + dy
                    guard px >= 0 && px < width && py >= 0 && py < height else { continue }

                    let value: UInt8
                    if bytesPerPixel == 4 {
                        value = buffer[py * bytesPerRow + px * 4 + 3]
                    } else {
                        value = buffer[py * bytesPerRow + px]
                    }

                    if value > 0 {
                        // Weight closer pixels higher (inverse Manhattan distance)
                        let dist = max(1, abs(dx) + abs(dy))
                        score += searchRadius / dist
                    }
                }
            }

#if DEBUG
            print("[Segmentation] Instance \(instanceId): score=\(score) near tap (\(cx), \(cy)) in \(width)x\(height)")
#endif

            if score > bestScore {
                bestScore = score
                bestInstance = instanceId
            }
        }

#if DEBUG
        if let best = bestInstance {
            print("[Segmentation] Selected instance \(best) with score \(bestScore)")
        } else {
            print("[Segmentation] No instance found near tap point")
        }
#endif

        return bestInstance
    }
}

// MARK: - Mask Utilities

extension InstanceSegmentationService {
    /// Get the pixels that are part of the mask
    /// Note: The mask from generateMaskedImage is in the SAME coordinate system as the original image
    /// (regardless of the orientation parameter used for detection)
    func getMaskedPixels(
        mask: CVPixelBuffer,
        imageSize: CGSize  // This is the original camera image size
    ) -> [(x: Int, y: Int)] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

#if DEBUG
        print("[Segmentation] Mask size: \(maskWidth)x\(maskHeight)")
        print("[Segmentation] Mask pixel format: \(pixelFormat)")
        print("[Segmentation] Camera image size: \(imageSize)")
#endif

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
#if DEBUG
            print("[Segmentation] No base address for mask")
#endif
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var pixels: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(20000)  // Pre-allocate to reduce reallocations

        // The mask is in the same coordinate system as the original camera image
        // Just scale from mask resolution to image resolution
        let scaleX = imageSize.width / CGFloat(maskWidth)
        let scaleY = imageSize.height / CGFloat(maskHeight)

        // Sample every Nth pixel - balance between accuracy and memory
        let step = max(2, min(maskWidth, maskHeight) / 160)
        let maxPixels = 20000  // Limit total pixels to prevent memory issues

        // Determine bytes per pixel based on format
        // BGRA = 4 bytes per pixel, OneComponent8 = 1 byte per pixel
        let bytesPerPixel: Int
        if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
#if DEBUG
            print("[Segmentation] Using 4 bytes per pixel (BGRA/ARGB format)")
#endif
        } else {
            bytesPerPixel = 1
#if DEBUG
            print("[Segmentation] Using 1 byte per pixel")
#endif
        }

        outerLoop: for y in Swift.stride(from: 0, to: maskHeight, by: step) {
            for x in Swift.stride(from: 0, to: maskWidth, by: step) {
                let pixelOffset = y * bytesPerRow + x * bytesPerPixel
                // For BGRA, check alpha channel (offset +3) or any non-zero channel
                // For single channel, just check the value
                let pixelValue: UInt8
                if bytesPerPixel == 4 {
                    // Check alpha channel (BGRA: B=0, G=1, R=2, A=3)
                    pixelValue = buffer[pixelOffset + 3]
                } else {
                    pixelValue = buffer[pixelOffset]
                }

                if pixelValue > 0 {
                    let imageX = Int(CGFloat(x) * scaleX)
                    let imageY = Int(CGFloat(y) * scaleY)
                    pixels.append((imageX, imageY))

                    // Limit pixels to prevent memory issues
                    if pixels.count >= maxPixels {
                        break outerLoop
                    }
                }
            }
        }

#if DEBUG
        print("[Segmentation] Found \(pixels.count) masked pixels")
#endif

        // Debug: print bounds of masked region
        if !pixels.isEmpty {
            let minX = pixels.map { $0.x }.min()!
            let maxX = pixels.map { $0.x }.max()!
            let minY = pixels.map { $0.y }.min()!
            let maxY = pixels.map { $0.y }.max()!
#if DEBUG
            print("[Segmentation] Mask bounds in image coords: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
            print("[Segmentation] Mask center: (\((minX+maxX)/2), \((minY+maxY)/2))")
            print("[Segmentation] Mask size: \(maxX-minX) x \(maxY-minY) pixels")
#endif

            // Also show as normalized coordinates for comparison with tap point
            let normalizedCenterX = Float(minX + maxX) / 2.0 / Float(imageSize.width)
            let normalizedCenterY = Float(minY + maxY) / 2.0 / Float(imageSize.height)
#if DEBUG
            print("[Segmentation] Mask center (normalized): (\(normalizedCenterX), \(normalizedCenterY))")
#endif
        }

        return pixels
    }

    /// Get the pixels that are part of the mask when ROI was used
    /// Handles both full-size masks and ROI-cropped masks
    /// - Parameters:
    ///   - mask: The mask pixel buffer
    ///   - imageSize: The original camera image size
    ///   - visionROI: The ROI in Vision normalized coordinates (0-1, bottom-left origin)
    func getMaskedPixelsWithROI(
        mask: CVPixelBuffer,
        imageSize: CGSize,
        visionROI: CGRect
    ) -> [(x: Int, y: Int)] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

#if DEBUG
        print("[Segmentation] Mask size: \(maskWidth)x\(maskHeight)")
        print("[Segmentation] Vision ROI: \(visionROI)")
        print("[Segmentation] Camera image size: \(imageSize)")
#endif

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
#if DEBUG
            print("[Segmentation] No base address for mask")
#endif
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var pixels: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(20000)

        // Determine bytes per pixel based on format
        let bytesPerPixel: Int
        if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
        } else {
            bytesPerPixel = 1
        }

        // Check if mask is full-size or ROI-cropped
        // Full-size: mask dimensions match image dimensions (within tolerance)
        let isFullSizeMask = abs(CGFloat(maskWidth) - imageSize.width) < 10 &&
                             abs(CGFloat(maskHeight) - imageSize.height) < 10
#if DEBUG
        print("[Segmentation] Mask is full-size: \(isFullSizeMask)")
#endif

        let step = max(2, min(maskWidth, maskHeight) / 160)
        let maxPixels = 20000

        outerLoop: for my in Swift.stride(from: 0, to: maskHeight, by: step) {
            for mx in Swift.stride(from: 0, to: maskWidth, by: step) {
                let pixelOffset = my * bytesPerRow + mx * bytesPerPixel
                let pixelValue: UInt8
                if bytesPerPixel == 4 {
                    pixelValue = buffer[pixelOffset + 3]  // Alpha channel
                } else {
                    pixelValue = buffer[pixelOffset]
                }

                if pixelValue > 0 {
                    let imageX: Int
                    let imageY: Int

                    if isFullSizeMask {
                        // Full-size mask: mask coordinates directly correspond to image coordinates
                        // No ROI transformation needed
                        imageX = mx
                        imageY = my
                    } else {
                        // ROI-cropped mask: need to transform coordinates
                        // Mask coordinates to ROI-relative normalized (0-1)
                        let roiRelativeX = CGFloat(mx) / CGFloat(maskWidth)
                        let roiRelativeY = CGFloat(my) / CGFloat(maskHeight)

                        // ROI-relative to Vision absolute coordinates
                        // Vision uses bottom-left origin, mask uses top-left origin
                        // So we need to flip Y within the ROI
                        let visionX = visionROI.origin.x + roiRelativeX * visionROI.width
                        let visionY = visionROI.origin.y + (1.0 - roiRelativeY) * visionROI.height

                        // Vision coordinates (bottom-left origin) to image coordinates (top-left origin)
                        imageX = Int(visionX * imageSize.width)
                        imageY = Int((1.0 - visionY) * imageSize.height)
                    }

                    pixels.append((imageX, imageY))

                    if pixels.count >= maxPixels {
                        break outerLoop
                    }
                }
            }
        }

#if DEBUG
        print("[Segmentation] Found \(pixels.count) masked pixels")
#endif

        if !pixels.isEmpty {
            let minX = pixels.map { $0.x }.min()!
            let maxX = pixels.map { $0.x }.max()!
            let minY = pixels.map { $0.y }.min()!
            let maxY = pixels.map { $0.y }.max()!
#if DEBUG
            print("[Segmentation] Mask bounds in image coords: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
#endif
        }

        return pixels
    }

    /// Get mask coverage statistics
    func getMaskStats(mask: CVPixelBuffer) -> (totalPixels: Int, maskedPixels: Int) {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            return (width * height, 0)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var maskedCount = 0
        for y in 0..<height {
            for x in 0..<width {
                if buffer[y * bytesPerRow + x] > 0 {
                    maskedCount += 1
                }
            }
        }

        return (width * height, maskedCount)
    }
}

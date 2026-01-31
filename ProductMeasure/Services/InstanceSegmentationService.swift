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
        print("[Segmentation] Starting segmentation at point: \(tapPoint)")

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        print("[Segmentation] Input image size: \(imageWidth)x\(imageHeight)")

        // Create the foreground instance mask request (iOS 17+)
        let request = VNGenerateForegroundInstanceMaskRequest()

        // Use .up orientation - process image as-is
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        try handler.perform([request])

        guard let observation = request.results?.first else {
            print("[Segmentation] No observation results")
            return nil
        }

        let allInstances = observation.allInstances
        print("[Segmentation] Found \(allInstances.count) instances")

        guard !allInstances.isEmpty else {
            print("[Segmentation] No instances found")
            return nil
        }

        // Use ALL instances - the 3D filtering will isolate the correct one based on raycast hit
        print("[Segmentation] Using ALL \(allInstances.count) instances (3D filtering will select correct one)")

        // Generate combined mask for all instances
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
            print("[Segmentation] Generated mask size: \(maskSize)")
            print("[Segmentation] Mask is in portrait orientation (rotated from camera)")

            return SegmentationResult(
                mask: instanceMask,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                maskSize: maskSize
            )
        } catch {
            print("[Segmentation] Failed to generate mask: \(error)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func findInstance(
        at point: CGPoint,
        in observation: VNInstanceMaskObservation,
        pixelBuffer: CVPixelBuffer
    ) -> Int? {
        let allInstances = observation.allInstances

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        print("[Segmentation] Finding instance at normalized point: \(point)")
        print("[Segmentation] Expected image pixel: (\(Int(point.x * CGFloat(imageWidth))), \(Int(point.y * CGFloat(imageHeight))))")
        print("[Segmentation] Original image size: \(imageWidth)x\(imageHeight)")
        print("[Segmentation] All instances found: \(Array(allInstances))")

        // Try to get the scaled mask using .up orientation (same as segmentation request)
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            let instanceMap = try observation.generateScaledMaskForImage(
                forInstances: allInstances,
                from: handler
            )

            CVPixelBufferLockBaseAddress(instanceMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(instanceMap, .readOnly) }

            let width = CVPixelBufferGetWidth(instanceMap)
            let height = CVPixelBufferGetHeight(instanceMap)

            print("[Segmentation] Instance map size: \(width)x\(height)")

            // Convert normalized point to pixel coordinates
            let x = Int(point.x * CGFloat(width))
            let y = Int(point.y * CGFloat(height))

            print("[Segmentation] Looking for instance at pixel: (\(x), \(y))")

            guard x >= 0 && x < width && y >= 0 && y < height else {
                print("[Segmentation] Point out of bounds: (\(x), \(y)) in \(width)x\(height)")
                return nil
            }

            guard let baseAddress = CVPixelBufferGetBaseAddress(instanceMap) else {
                return nil
            }

            let bytesPerRow = CVPixelBufferGetBytesPerRow(instanceMap)
            let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
            let instanceId = Int(buffer[y * bytesPerRow + x])

            print("[Segmentation] Instance ID at (\(x), \(y)): \(instanceId)")

            // Also check surrounding area in case tap is slightly off
            if instanceId == 0 {
                print("[Segmentation] Checking surrounding pixels for nearby instances...")
                let searchRadius = 50
                var foundInstances: [(id: Int, dist: Int)] = []
                for dy in Swift.stride(from: -searchRadius, through: searchRadius, by: 5) {
                    for dx in Swift.stride(from: -searchRadius, through: searchRadius, by: 5) {
                        let sx = x + dx
                        let sy = y + dy
                        if sx >= 0 && sx < width && sy >= 0 && sy < height {
                            let sId = Int(buffer[sy * bytesPerRow + sx])
                            if sId > 0 {
                                let dist = abs(dx) + abs(dy)
                                if !foundInstances.contains(where: { $0.id == sId }) {
                                    foundInstances.append((id: sId, dist: dist))
                                }
                            }
                        }
                    }
                }
                // Use the closest found instance
                if let closest = foundInstances.min(by: { $0.dist < $1.dist }), allInstances.contains(closest.id) {
                    print("[Segmentation] Using nearby instance \(closest.id) at distance \(closest.dist)")
                    return closest.id
                }
            }

            // Instance ID 0 is background
            if instanceId > 0 && allInstances.contains(instanceId) {
                return instanceId
            }
        } catch {
            print("[Segmentation] Error generating scaled mask: \(error)")
        }

        return nil
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

        print("[Segmentation] Mask size: \(maskWidth)x\(maskHeight)")
        print("[Segmentation] Mask pixel format: \(pixelFormat)")
        print("[Segmentation] Camera image size: \(imageSize)")

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            print("[Segmentation] No base address for mask")
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var pixels: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(5000)  // Pre-allocate to reduce reallocations

        // The mask is in the same coordinate system as the original camera image
        // Just scale from mask resolution to image resolution
        let scaleX = imageSize.width / CGFloat(maskWidth)
        let scaleY = imageSize.height / CGFloat(maskHeight)

        // Sample every Nth pixel - balance between accuracy and memory
        let step = max(4, min(maskWidth, maskHeight) / 80)
        let maxPixels = 5000  // Limit total pixels to prevent memory issues

        // Determine bytes per pixel based on format
        // BGRA = 4 bytes per pixel, OneComponent8 = 1 byte per pixel
        let bytesPerPixel: Int
        if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
            print("[Segmentation] Using 4 bytes per pixel (BGRA/ARGB format)")
        } else {
            bytesPerPixel = 1
            print("[Segmentation] Using 1 byte per pixel")
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

        print("[Segmentation] Found \(pixels.count) masked pixels")

        // Debug: print bounds of masked region
        if !pixels.isEmpty {
            let minX = pixels.map { $0.x }.min()!
            let maxX = pixels.map { $0.x }.max()!
            let minY = pixels.map { $0.y }.min()!
            let maxY = pixels.map { $0.y }.max()!
            print("[Segmentation] Mask bounds in image coords: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
            print("[Segmentation] Mask center: (\((minX+maxX)/2), \((minY+maxY)/2))")
            print("[Segmentation] Mask size: \(maxX-minX) x \(maxY-minY) pixels")

            // Also show as normalized coordinates for comparison with tap point
            let normalizedCenterX = Float(minX + maxX) / 2.0 / Float(imageSize.width)
            let normalizedCenterY = Float(minY + maxY) / 2.0 / Float(imageSize.height)
            print("[Segmentation] Mask center (normalized): (\(normalizedCenterX), \(normalizedCenterY))")
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

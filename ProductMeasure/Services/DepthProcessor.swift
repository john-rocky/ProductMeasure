//
//  DepthProcessor.swift
//  ProductMeasure
//

import ARKit
import simd

/// Processes depth data from ARKit LiDAR
class DepthProcessor {
    // MARK: - Types

    struct DepthData {
        /// Depth value in meters
        let depth: Float

        /// Confidence level (0-2, higher is better)
        let confidence: ARConfidenceLevel

        /// Pixel coordinates in depth map
        let pixelX: Int
        let pixelY: Int
    }

    struct DepthStats {
        let validPixels: Int
        let totalPixels: Int
        let averageConfidence: Float
        let minDepth: Float
        let maxDepth: Float

        var coverage: Float {
            Float(validPixels) / Float(max(totalPixels, 1))
        }
    }

    // MARK: - Public Methods

    /// Extract depth values for masked pixels
    /// - Parameters:
    ///   - frame: ARFrame containing depth data
    ///   - maskedPixels: Pixels in the segmentation mask (in image coordinates)
    ///   - imageSize: Size of the camera image
    /// - Returns: Array of depth data for valid pixels
    func extractDepthForMask(
        frame: ARFrame,
        maskedPixels: [(x: Int, y: Int)],
        imageSize: CGSize
    ) -> [DepthData] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
              let confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap else {
            print("[Depth] No depth or confidence map available")
            return []
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        print("[Depth] Depth map size: \(depthWidth)x\(depthHeight)")
        print("[Depth] Image size: \(imageSize)")

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return []
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)

        print("[Depth] Depth bytes per row: \(depthBytesPerRow) (elements per row: \(depthBytesPerRow / 4))")

        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr = confBase.assumingMemoryBound(to: UInt8.self)

        // Scale factors from image to depth coordinates
        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        print("[Depth] Scale factors (image to depth): \(scaleX), \(scaleY)")

        var results: [DepthData] = []
        var debugCount = 0
        var rejectedCount = 0

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)

            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }

            let depthIndex = depthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + depthX
            let depth = depthPtr[depthIndex]

            let confIndex = depthY * confBytesPerRow + depthX
            let confValue = confPtr[confIndex]
            let confidence = ARConfidenceLevel(rawValue: Int(confValue)) ?? .low

            // Debug first few samples
            if debugCount < 5 {
                print("[Depth] Sample \(debugCount): imagePx=(\(pixel.x),\(pixel.y)) -> depthPx=(\(depthX),\(depthY)), depth=\(depth)m, conf=\(confValue)")
                debugCount += 1
            }

            if depth.isFinite && depth > 0 && confidence.rawValue >= ARConfidenceLevel.medium.rawValue {
                results.append(DepthData(
                    depth: depth,
                    confidence: confidence,
                    pixelX: depthX,
                    pixelY: depthY
                ))
            } else {
                rejectedCount += 1
            }
        }

        print("[Depth] Accepted: \(results.count), Rejected: \(rejectedCount)")

        return results
    }

    /// Get depth statistics for a region
    func getDepthStats(depthData: [DepthData]) -> DepthStats {
        guard !depthData.isEmpty else {
            return DepthStats(
                validPixels: 0,
                totalPixels: 0,
                averageConfidence: 0,
                minDepth: 0,
                maxDepth: 0
            )
        }

        var totalConfidence: Float = 0
        var minDepth: Float = .infinity
        var maxDepth: Float = -.infinity

        for data in depthData {
            totalConfidence += Float(data.confidence.rawValue)
            minDepth = min(minDepth, data.depth)
            maxDepth = max(maxDepth, data.depth)
        }

        return DepthStats(
            validPixels: depthData.count,
            totalPixels: depthData.count,
            averageConfidence: totalConfidence / Float(depthData.count) / 2.0, // Normalize to 0-1
            minDepth: minDepth,
            maxDepth: maxDepth
        )
    }

    /// Filter depth data by confidence threshold
    func filterByConfidence(
        _ depthData: [DepthData],
        minConfidence: ARConfidenceLevel
    ) -> [DepthData] {
        depthData.filter { $0.confidence.rawValue >= minConfidence.rawValue }
    }

    /// Remove outliers using statistical filtering
    func removeOutliers(
        _ depthData: [DepthData],
        stdDevThreshold: Float = AppConstants.depthOutlierStdDevThreshold
    ) -> [DepthData] {
        guard depthData.count > 10 else { return depthData }

        // Calculate mean depth
        let depths = depthData.map { $0.depth }
        let mean = depths.reduce(0, +) / Float(depths.count)

        // Calculate standard deviation
        let variance = depths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(depths.count)
        let stdDev = sqrt(variance)

        // Filter outliers
        let minDepth = mean - stdDevThreshold * stdDev
        let maxDepth = mean + stdDevThreshold * stdDev

        return depthData.filter { $0.depth >= minDepth && $0.depth <= maxDepth }
    }

    /// Downsample depth data using grid-based sampling
    func downsample(
        _ depthData: [DepthData],
        gridSize: Int = 4
    ) -> [DepthData] {
        guard !depthData.isEmpty else { return [] }

        // Find bounds
        let minX = depthData.map { $0.pixelX }.min()!
        let maxX = depthData.map { $0.pixelX }.max()!
        let minY = depthData.map { $0.pixelY }.min()!
        let maxY = depthData.map { $0.pixelY }.max()!

        // Create grid cells
        var grid: [String: [DepthData]] = [:]

        for data in depthData {
            let cellX = (data.pixelX - minX) / gridSize
            let cellY = (data.pixelY - minY) / gridSize
            let key = "\(cellX)_\(cellY)"

            if grid[key] == nil {
                grid[key] = []
            }
            grid[key]!.append(data)
        }

        // Take the highest confidence point from each cell
        return grid.values.compactMap { cellData in
            cellData.max { $0.confidence.rawValue < $1.confidence.rawValue }
        }
    }
}

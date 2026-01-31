//
//  DepthProcessor.swift
//  ProductMeasure
//

import ARKit
import simd
import UIKit

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
        stdDevThreshold: Float = AppConstants.outlierStdDevThreshold
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

    // MARK: - Depth-Based Region Growing

    /// Find object region using depth-based flood fill from tap point
    /// This method doesn't rely on Vision segmentation - it uses depth continuity directly
    func regionGrowingFromTapPoint(
        frame: ARFrame,
        tapPointInDepthMap: (x: Int, y: Int),
        maxDepthDifference: Float = 0.05  // 5cm depth difference threshold
    ) -> [DepthData] {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
              let confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap else {
            print("[RegionGrow] No depth map available")
            return []
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return []
        }

        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr = confBase.assumingMemoryBound(to: UInt8.self)
        let depthRowStride = depthBytesPerRow / MemoryLayout<Float32>.size

        print("[RegionGrow] Depth map size: \(width)x\(height)")
        print("[RegionGrow] Starting from tap point: (\(tapPointInDepthMap.x), \(tapPointInDepthMap.y))")

        // Check bounds
        guard tapPointInDepthMap.x >= 0 && tapPointInDepthMap.x < width &&
              tapPointInDepthMap.y >= 0 && tapPointInDepthMap.y < height else {
            print("[RegionGrow] Tap point out of bounds")
            return []
        }

        // Get seed depth at tap point
        let seedIndex = tapPointInDepthMap.y * depthRowStride + tapPointInDepthMap.x
        let seedDepth = depthPtr[seedIndex]

        guard seedDepth.isFinite && seedDepth > 0 else {
            print("[RegionGrow] Invalid seed depth: \(seedDepth)")
            return []
        }

        print("[RegionGrow] Seed depth: \(seedDepth)m")

        // Adaptive depth threshold based on distance (farther objects need looser threshold)
        let adaptiveThreshold = max(maxDepthDifference, seedDepth * 0.08)  // 8% of depth or 5cm
        print("[RegionGrow] Using depth threshold: \(adaptiveThreshold)m")

        // Flood fill using BFS
        var visited = Set<Int>()  // Use linear index as key
        var frontier: [(x: Int, y: Int)] = [(tapPointInDepthMap.x, tapPointInDepthMap.y)]
        var results: [DepthData] = []

        // Limit region size to prevent growing too large
        let maxPixels = 3000
        let step = 2  // Sample every 2nd pixel for performance

        // 8-directional neighbors (with step)
        let neighbors = [
            (-step, 0), (step, 0), (0, -step), (0, step),
            (-step, -step), (step, -step), (-step, step), (step, step)
        ]

        while !frontier.isEmpty && results.count < maxPixels {
            let current = frontier.removeFirst()
            let linearIndex = current.y * width + current.x

            if visited.contains(linearIndex) { continue }
            visited.insert(linearIndex)

            let depthIndex = current.y * depthRowStride + current.x
            let depth = depthPtr[depthIndex]

            // Check if this pixel is part of the same object (similar depth to seed)
            guard depth.isFinite && depth > 0 else { continue }

            let depthDiff = abs(depth - seedDepth)
            if depthDiff > adaptiveThreshold { continue }

            // Check confidence
            let confIndex = current.y * confBytesPerRow + current.x
            let confValue = confPtr[confIndex]
            let confidence = ARConfidenceLevel(rawValue: Int(confValue)) ?? .low

            if confidence.rawValue >= ARConfidenceLevel.medium.rawValue {
                results.append(DepthData(
                    depth: depth,
                    confidence: confidence,
                    pixelX: current.x,
                    pixelY: current.y
                ))
            }

            // Add neighbors to frontier
            for (dx, dy) in neighbors {
                let nx = current.x + dx
                let ny = current.y + dy
                let nLinearIndex = ny * width + nx

                if nx >= 0 && nx < width && ny >= 0 && ny < height && !visited.contains(nLinearIndex) {
                    frontier.append((nx, ny))
                }
            }
        }

        print("[RegionGrow] Found \(results.count) pixels in region")

        // Print region bounds
        if !results.isEmpty {
            let minX = results.map { $0.pixelX }.min()!
            let maxX = results.map { $0.pixelX }.max()!
            let minY = results.map { $0.pixelY }.min()!
            let maxY = results.map { $0.pixelY }.max()!
            print("[RegionGrow] Region bounds: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
            print("[RegionGrow] Region size: \(maxX - minX) x \(maxY - minY) pixels")
        }

        return results
    }

    /// Convert world position to depth map coordinates
    func worldPositionToDepthMapCoords(
        worldPosition: SIMD3<Float>,
        frame: ARFrame
    ) -> (x: Int, y: Int)? {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return nil
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Project world position to camera image coordinates
        let camera = frame.camera
        let imageResolution = camera.imageResolution

        // Transform world point to camera space
        let orientation = UIInterfaceOrientation.landscapeRight
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(
            for: orientation,
            viewportSize: imageResolution,
            zNear: 0.001,
            zFar: 100
        )

        let worldPoint4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let cameraPoint = viewMatrix * worldPoint4
        let clipPoint = projectionMatrix * cameraPoint

        // Perspective divide
        guard clipPoint.w != 0 else { return nil }
        let ndcX = clipPoint.x / clipPoint.w
        let ndcY = clipPoint.y / clipPoint.w

        // NDC to pixel coordinates (NDC is -1 to 1, need to convert to 0 to width/height)
        let resWidth = Float(imageResolution.width)
        let resHeight = Float(imageResolution.height)
        let imageX = (ndcX + 1.0) * 0.5 * resWidth
        let imageY = (1.0 - ndcY) * 0.5 * resHeight  // Y is flipped

        // Scale to depth map coordinates
        let depthWidthF = Float(depthWidth)
        let depthHeightF = Float(depthHeight)
        let scaleToDepthX = depthWidthF / resWidth
        let scaleToDepthY = depthHeightF / resHeight
        let depthX = Int(imageX * scaleToDepthX)
        let depthY = Int(imageY * scaleToDepthY)

        print("[DepthCoords] World: \(worldPosition) -> Image: (\(imageX), \(imageY)) -> Depth: (\(depthX), \(depthY))")

        guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
            print("[DepthCoords] Out of bounds")
            return nil
        }

        return (depthX, depthY)
    }
}

//
//  ScenePointCloudAccumulator.swift
//  ProductMeasure
//

import ARKit
import simd

/// Accumulates sparse depth samples from AR frames into a voxel grid,
/// enabling transparent multi-angle point cloud enhancement on a single tap.
class ScenePointCloudAccumulator {

    // MARK: - Types

    private struct VoxelKey: Hashable {
        let x, y, z: Int
    }

    private struct VoxelData {
        var point: SIMD3<Float>
        var timestamp: TimeInterval
    }

    // MARK: - State

    private var voxelGrid: [VoxelKey: VoxelData] = [:]
    private let voxelSize: Float
    private let maxAge: TimeInterval
    private let sampleStride: Int
    private let minConfidence: Int
    private var lastPruneTimestamp: TimeInterval = 0
    private let pruneInterval: TimeInterval = 1.0 // prune at most once per second

    // MARK: - Init

    init(
        voxelSize: Float = AppConstants.accumulatorVoxelSize,
        maxAge: TimeInterval = AppConstants.accumulatorMaxAge,
        sampleStride: Int = AppConstants.accumulatorSampleStride,
        minConfidence: Int = AppConstants.accumulatorMinConfidence
    ) {
        self.voxelSize = voxelSize
        self.maxAge = maxAge
        self.sampleStride = sampleStride
        self.minConfidence = minConfidence
    }

    // MARK: - Accumulate

    /// Accumulate sparse depth samples from an AR frame.
    /// Call this every frame when not processing a measurement.
    func accumulate(frame: ARFrame) {
        // Only accumulate when tracking is normal
        guard frame.camera.trackingState == .normal else { return }

        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap,
              let confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap else {
            return
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confBase = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confPtr = confBase.assumingMemoryBound(to: UInt8.self)

        // Camera intrinsics (for the captured image resolution)
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        // Scale from depth map to camera image coordinates
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let cameraImageWidth = Float(frame.camera.imageResolution.width)
        let cameraImageHeight = Float(frame.camera.imageResolution.height)

        let scaleDepthToImageX = imageWidth / Float(depthWidth)
        let scaleDepthToImageY = imageHeight / Float(depthHeight)

        var fx = intrinsics[0][0]
        var fy = intrinsics[1][1]
        var cx = intrinsics[2][0]
        var cy = intrinsics[2][1]

        // Scale intrinsics if capturedImage resolution differs from camera.imageResolution
        if abs(imageWidth - cameraImageWidth) > 1 || abs(imageHeight - cameraImageHeight) > 1 {
            let sx = imageWidth / cameraImageWidth
            let sy = imageHeight / cameraImageHeight
            fx *= sx; fy *= sy; cx *= sx; cy *= sy
        }

        let now = frame.timestamp
        let stride = sampleStride

        // Sparse sample depth map
        var dy = stride / 2
        while dy < depthHeight {
            var dx = stride / 2
            while dx < depthWidth {
                // Confidence check
                let confIndex = dy * confBytesPerRow + dx
                let conf = Int(confPtr[confIndex])
                guard conf >= minConfidence else {
                    dx += stride
                    continue
                }

                // Depth check
                let depthIndex = dy * (depthBytesPerRow / MemoryLayout<Float32>.size) + dx
                let depth = depthPtr[depthIndex]
                guard depth.isFinite && depth > 0 && depth < 5.0 else {
                    dx += stride
                    continue
                }

                // Unproject to world coordinates (same math as PointCloudGenerator)
                let imageX = Float(dx) * scaleDepthToImageX
                let imageY = Float(dy) * scaleDepthToImageY

                let localX = (imageX - cx) * depth / fx
                let localY = (imageY - cy) * depth / fy
                let cameraSpacePoint = SIMD4<Float>(localX, -localY, -depth, 1.0)
                let worldPoint = cameraTransform * cameraSpacePoint
                let point = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)

                // Quantize to voxel and store (latest timestamp wins)
                let key = VoxelKey(
                    x: Int(floor(point.x / voxelSize)),
                    y: Int(floor(point.y / voxelSize)),
                    z: Int(floor(point.z / voxelSize))
                )
                voxelGrid[key] = VoxelData(point: point, timestamp: now)

                dx += stride
            }
            dy += stride
        }

        // Periodic pruning of old entries
        if now - lastPruneTimestamp > pruneInterval {
            pruneOldEntries(currentTime: now)
            lastPruneTimestamp = now
        }
    }

    // MARK: - Query

    /// Query accumulated points near a bounding box.
    /// - Parameters:
    ///   - box: The bounding box to query around
    ///   - expansion: Scale factor for the query region (default from constants)
    /// - Returns: Array of world-space points within the expanded box
    func queryPoints(near box: BoundingBox3D, expansion: Float = AppConstants.accumulatorQueryExpansion) -> [SIMD3<Float>] {
        let expandedBox = expandBox(box, scale: expansion)
        let now = voxelGrid.values.map(\.timestamp).max() ?? 0

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(voxelGrid.count / 4)

        for (_, data) in voxelGrid {
            // Skip expired entries
            guard now - data.timestamp <= maxAge else { continue }
            // Spatial filter
            if expandedBox.contains(data.point) {
                result.append(data.point)
            }
        }

        return result
    }

    // MARK: - Reset

    /// Clear all accumulated data. Call on session start/reset.
    func reset() {
        voxelGrid.removeAll(keepingCapacity: true)
        lastPruneTimestamp = 0
    }

    /// Number of voxels currently stored (for diagnostics)
    var voxelCount: Int { voxelGrid.count }

    // MARK: - Private

    private func pruneOldEntries(currentTime: TimeInterval) {
        let cutoff = currentTime - maxAge
        voxelGrid = voxelGrid.filter { $0.value.timestamp >= cutoff }
    }

    private func expandBox(_ box: BoundingBox3D, scale: Float) -> BoundingBox3D {
        var expanded = box
        expanded.extents = box.extents * scale
        return expanded
    }
}

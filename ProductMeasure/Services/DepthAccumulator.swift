//
//  DepthAccumulator.swift
//  ProductMeasure
//

import ARKit
import simd

/// Accumulates multiple depth frames and produces a temporal median depth map
/// to reduce per-frame LiDAR noise (~1-2cm). Averaging N frames reduces noise by sqrt(N).
class DepthAccumulator: @unchecked Sendable {
    // MARK: - Types

    struct AccumulatedDepthMap {
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        let width: Int
        let height: Int
    }

    // MARK: - Properties

    private let maxFrames: Int
    private var depthBuffers: [(depths: [Float], width: Int, height: Int)] = []
    private var lastCameraPosition: SIMD3<Float>?
    private let maxCameraTranslation: Float = 0.01 // Only accumulate when camera moves < 1cm
    private let lock = NSLock()

    // MARK: - Initialization

    init(maxFrames: Int = AppConstants.depthAccumulationFrameCount) {
        self.maxFrames = maxFrames
    }

    // MARK: - Public Methods

    /// Add a new frame to the accumulator
    /// Only accumulates if camera hasn't moved significantly
    func addFrame(_ frame: ARFrame) {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let cameraPos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        lock.lock()
        defer { lock.unlock() }

        // Check camera movement - reset if moved too much
        if let lastPos = lastCameraPosition {
            let translation = simd_distance(cameraPos, lastPos)
            if translation > maxCameraTranslation {
                // Camera moved too much, reset buffer
                depthBuffers.removeAll()
            }
        }
        lastCameraPosition = cameraPos

        // Extract depth values
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr = baseAddress.assumingMemoryBound(to: Float32.self)
        let elementsPerRow = bytesPerRow / MemoryLayout<Float32>.size

        var depths = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                depths[y * width + x] = ptr[y * elementsPerRow + x]
            }
        }

        depthBuffers.append((depths: depths, width: width, height: height))

        // Keep only the last N frames
        if depthBuffers.count > maxFrames {
            depthBuffers.removeFirst()
        }
    }

    /// Get the accumulated (temporal median) depth values at specific pixel locations
    /// Falls back to single-frame depth if fewer than 3 frames accumulated
    func getAccumulatedDepth(at pixelX: Int, pixelY: Int, width: Int) -> Float? {
        lock.lock()
        defer { lock.unlock() }

        guard depthBuffers.count >= 3 else { return nil }

        // Collect depth values from all frames for this pixel
        var values: [Float] = []
        values.reserveCapacity(depthBuffers.count)

        for buffer in depthBuffers {
            guard buffer.width == width else { continue }
            let index = pixelY * buffer.width + pixelX
            guard index >= 0 && index < buffer.depths.count else { continue }
            let depth = buffer.depths[index]
            if depth.isFinite && depth > 0 {
                values.append(depth)
            }
        }

        guard values.count >= 3 else { return nil }

        // Return median
        values.sort()
        return DepthProcessor.median(sorted: values)
    }

    /// Get the number of accumulated frames
    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return depthBuffers.count
    }

    /// Reset the accumulator
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        depthBuffers.removeAll()
        lastCameraPosition = nil
    }
}

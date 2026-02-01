//
//  VoxelVolumeCalculator.swift
//  ProductMeasure
//
//  Voxel-based precise volume calculation for irregular shapes
//

import Foundation
import simd

/// Result of voxel-based volume calculation
struct VoxelVolumeResult {
    /// Calculated volume in cubic meters
    let volume: Float

    /// Number of occupied voxels
    let occupiedVoxelCount: Int

    /// Voxel size used for calculation (meters)
    let voxelSize: Float

    /// Processing time in seconds
    let processingTime: TimeInterval

    /// Grid dimensions (x, y, z)
    let gridDimensions: (x: Int, y: Int, z: Int)

    /// Minimum bound of the voxel grid (world coordinates)
    let gridOrigin: SIMD3<Float>

    /// Surface voxel indices (for visualization - only outer shell)
    let surfaceVoxels: [VoxelIndex]

    /// Formatted volume string
    var formattedVolume: String {
        let volumeCm3 = volume * 1_000_000
        if volumeCm3 >= 1000 {
            return String(format: "%.0f cm³", volumeCm3)
        } else {
            return String(format: "%.1f cm³", volumeCm3)
        }
    }
}

/// Voxel index for sparse grid storage
struct VoxelIndex: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// Calculates precise volume using voxel-based approach
final class VoxelVolumeCalculator: Sendable {

    // MARK: - Configuration

    /// Default voxel size (1cm)
    static let defaultVoxelSize: Float = 0.01

    /// Minimum voxel size (5mm)
    static let minimumVoxelSize: Float = 0.005

    /// Maximum voxel size (5cm)
    static let maximumVoxelSize: Float = 0.05

    /// Maximum grid cells per dimension to prevent memory issues
    private let maxGridSize = 500

    // MARK: - Public Methods

    /// Calculate volume from point cloud using voxelization
    /// - Parameters:
    ///   - points: 3D point cloud
    ///   - voxelSize: Size of each voxel in meters (default: 1cm)
    /// - Returns: VoxelVolumeResult with calculated volume
    func calculateVolume(
        points: [SIMD3<Float>],
        voxelSize: Float = defaultVoxelSize
    ) -> VoxelVolumeResult {
        let startTime = Date()

        guard points.count >= 10 else {
            return VoxelVolumeResult(
                volume: 0,
                occupiedVoxelCount: 0,
                voxelSize: voxelSize,
                processingTime: Date().timeIntervalSince(startTime),
                gridDimensions: (0, 0, 0),
                gridOrigin: .zero,
                surfaceVoxels: []
            )
        }

        // 1. Calculate bounding box of point cloud
        let bounds = calculateBounds(points: points)

        // 2. Adjust voxel size if grid would be too large
        let adjustedVoxelSize = adjustVoxelSize(
            bounds: bounds,
            requestedSize: voxelSize
        )

        // 3. Create sparse voxel grid
        var occupiedVoxels = voxelizePointCloud(
            points: points,
            bounds: bounds,
            voxelSize: adjustedVoxelSize
        )

        // 4. Fill interior voxels (flood fill from outside to find interior)
        // Note: No dilation - we only use the actual point cloud coverage
        occupiedVoxels = fillInterior(
            voxels: occupiedVoxels,
            bounds: bounds,
            voxelSize: adjustedVoxelSize
        )

        // 6. Calculate volume
        let voxelVolume = adjustedVoxelSize * adjustedVoxelSize * adjustedVoxelSize
        let totalVolume = Float(occupiedVoxels.count) * voxelVolume

        // Calculate grid dimensions
        let gridDimensions = calculateGridDimensions(bounds: bounds, voxelSize: adjustedVoxelSize)

        // 7. Extract surface voxels for visualization
        let surfaceVoxels = extractSurfaceVoxels(from: occupiedVoxels)

        let processingTime = Date().timeIntervalSince(startTime)

        print("[VoxelCalc] Calculated volume: \(totalVolume * 1_000_000) cm³")
        print("[VoxelCalc] Occupied voxels: \(occupiedVoxels.count)")
        print("[VoxelCalc] Surface voxels: \(surfaceVoxels.count)")
        print("[VoxelCalc] Voxel size: \(adjustedVoxelSize * 100) cm")
        print("[VoxelCalc] Processing time: \(processingTime * 1000) ms")

        return VoxelVolumeResult(
            volume: totalVolume,
            occupiedVoxelCount: occupiedVoxels.count,
            voxelSize: adjustedVoxelSize,
            processingTime: processingTime,
            gridDimensions: gridDimensions,
            gridOrigin: bounds.min,
            surfaceVoxels: surfaceVoxels
        )
    }

    /// Calculate volume asynchronously on a background queue
    func calculateVolumeAsync(
        points: [SIMD3<Float>],
        voxelSize: Float = defaultVoxelSize
    ) async -> VoxelVolumeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.calculateVolume(points: points, voxelSize: voxelSize)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Private Methods

    /// Calculate axis-aligned bounding box of point cloud
    private func calculateBounds(points: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for point in points {
            minBound = simd_min(minBound, point)
            maxBound = simd_max(maxBound, point)
        }

        return (minBound, maxBound)
    }

    /// Adjust voxel size to ensure grid doesn't exceed memory limits
    private func adjustVoxelSize(
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        requestedSize: Float
    ) -> Float {
        let extent = bounds.max - bounds.min
        let maxExtent = max(extent.x, max(extent.y, extent.z))

        // Calculate minimum voxel size to keep grid within limits
        let minRequiredSize = maxExtent / Float(maxGridSize)

        // Use the larger of requested size or minimum required size
        let adjustedSize = max(requestedSize, minRequiredSize)

        // Clamp to valid range
        return min(max(adjustedSize, Self.minimumVoxelSize), Self.maximumVoxelSize)
    }

    /// Calculate grid dimensions
    private func calculateGridDimensions(
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        voxelSize: Float
    ) -> (x: Int, y: Int, z: Int) {
        let extent = bounds.max - bounds.min
        return (
            x: Int(ceil(extent.x / voxelSize)),
            y: Int(ceil(extent.y / voxelSize)),
            z: Int(ceil(extent.z / voxelSize))
        )
    }

    /// Convert point cloud to voxel grid
    private func voxelizePointCloud(
        points: [SIMD3<Float>],
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        voxelSize: Float
    ) -> Set<VoxelIndex> {
        var occupiedVoxels = Set<VoxelIndex>()

        for point in points {
            let index = pointToVoxelIndex(
                point: point,
                minBound: bounds.min,
                voxelSize: voxelSize
            )
            occupiedVoxels.insert(index)
        }

        print("[VoxelCalc] Initial occupied voxels: \(occupiedVoxels.count)")
        return occupiedVoxels
    }

    /// Convert 3D point to voxel index
    private func pointToVoxelIndex(
        point: SIMD3<Float>,
        minBound: SIMD3<Float>,
        voxelSize: Float
    ) -> VoxelIndex {
        let offset = point - minBound
        return VoxelIndex(
            x: Int(floor(offset.x / voxelSize)),
            y: Int(floor(offset.y / voxelSize)),
            z: Int(floor(offset.z / voxelSize))
        )
    }

    /// Dilate voxels to fill surface gaps
    /// Uses 6-connectivity (face neighbors only)
    private func dilateVoxels(
        voxels: Set<VoxelIndex>,
        iterations: Int
    ) -> Set<VoxelIndex> {
        var currentVoxels = voxels

        for _ in 0..<iterations {
            var newVoxels = currentVoxels

            for voxel in currentVoxels {
                // Add 6-connected neighbors
                let neighbors = [
                    VoxelIndex(x: voxel.x - 1, y: voxel.y, z: voxel.z),
                    VoxelIndex(x: voxel.x + 1, y: voxel.y, z: voxel.z),
                    VoxelIndex(x: voxel.x, y: voxel.y - 1, z: voxel.z),
                    VoxelIndex(x: voxel.x, y: voxel.y + 1, z: voxel.z),
                    VoxelIndex(x: voxel.x, y: voxel.y, z: voxel.z - 1),
                    VoxelIndex(x: voxel.x, y: voxel.y, z: voxel.z + 1)
                ]

                for neighbor in neighbors {
                    newVoxels.insert(neighbor)
                }
            }

            currentVoxels = newVoxels
        }

        print("[VoxelCalc] After dilation: \(currentVoxels.count) voxels")
        return currentVoxels
    }

    /// Fill interior voxels using inverse flood fill
    /// Flood fills from outside, then marks everything not reached as interior
    private func fillInterior(
        voxels: Set<VoxelIndex>,
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        voxelSize: Float
    ) -> Set<VoxelIndex> {
        let dims = calculateGridDimensions(bounds: bounds, voxelSize: voxelSize)

        // Add padding around the grid for flood fill to work
        let padding = 2
        let gridMinX = -padding
        let gridMinY = -padding
        let gridMinZ = -padding
        let gridMaxX = dims.x + padding
        let gridMaxY = dims.y + padding
        let gridMaxZ = dims.z + padding

        // Skip interior fill for very large grids to avoid memory issues
        let totalCells = (gridMaxX - gridMinX) * (gridMaxY - gridMinY) * (gridMaxZ - gridMinZ)
        if totalCells > 1_000_000 {
            print("[VoxelCalc] Grid too large for interior fill, skipping")
            return voxels
        }

        // Flood fill from corner to find all exterior voxels
        var exterior = Set<VoxelIndex>()
        var queue: [VoxelIndex] = []

        // Start from corner
        let startVoxel = VoxelIndex(x: gridMinX, y: gridMinY, z: gridMinZ)
        queue.append(startVoxel)
        exterior.insert(startVoxel)

        while !queue.isEmpty {
            let current = queue.removeFirst()

            // Check 6-connected neighbors
            let neighbors = [
                VoxelIndex(x: current.x - 1, y: current.y, z: current.z),
                VoxelIndex(x: current.x + 1, y: current.y, z: current.z),
                VoxelIndex(x: current.x, y: current.y - 1, z: current.z),
                VoxelIndex(x: current.x, y: current.y + 1, z: current.z),
                VoxelIndex(x: current.x, y: current.y, z: current.z - 1),
                VoxelIndex(x: current.x, y: current.y, z: current.z + 1)
            ]

            for neighbor in neighbors {
                // Check bounds
                guard neighbor.x >= gridMinX && neighbor.x < gridMaxX &&
                      neighbor.y >= gridMinY && neighbor.y < gridMaxY &&
                      neighbor.z >= gridMinZ && neighbor.z < gridMaxZ else {
                    continue
                }

                // Skip if already visited or occupied
                guard !exterior.contains(neighbor) && !voxels.contains(neighbor) else {
                    continue
                }

                exterior.insert(neighbor)
                queue.append(neighbor)
            }
        }

        // All voxels in grid that are not exterior and not already occupied are interior
        var filledVoxels = voxels

        for x in 0..<dims.x {
            for y in 0..<dims.y {
                for z in 0..<dims.z {
                    let index = VoxelIndex(x: x, y: y, z: z)
                    if !exterior.contains(index) && !voxels.contains(index) {
                        filledVoxels.insert(index)
                    }
                }
            }
        }

        let interiorCount = filledVoxels.count - voxels.count
        print("[VoxelCalc] Filled \(interiorCount) interior voxels")

        return filledVoxels
    }

    /// Extract surface voxels (voxels with at least one empty neighbor)
    /// Used for visualization - we only need to render the outer shell
    private func extractSurfaceVoxels(from voxels: Set<VoxelIndex>) -> [VoxelIndex] {
        var surfaceVoxels: [VoxelIndex] = []

        for voxel in voxels {
            // Check if any of the 6 neighbors is empty
            let neighbors = [
                VoxelIndex(x: voxel.x - 1, y: voxel.y, z: voxel.z),
                VoxelIndex(x: voxel.x + 1, y: voxel.y, z: voxel.z),
                VoxelIndex(x: voxel.x, y: voxel.y - 1, z: voxel.z),
                VoxelIndex(x: voxel.x, y: voxel.y + 1, z: voxel.z),
                VoxelIndex(x: voxel.x, y: voxel.y, z: voxel.z - 1),
                VoxelIndex(x: voxel.x, y: voxel.y, z: voxel.z + 1)
            ]

            let hasEmptyNeighbor = neighbors.contains { !voxels.contains($0) }
            if hasEmptyNeighbor {
                surfaceVoxels.append(voxel)
            }
        }

        // Limit to reasonable number for visualization performance
        let maxVisualizationVoxels = 5000
        if surfaceVoxels.count > maxVisualizationVoxels {
            // Subsample evenly
            let step = surfaceVoxels.count / maxVisualizationVoxels
            surfaceVoxels = Swift.stride(from: 0, to: surfaceVoxels.count, by: step).map { surfaceVoxels[$0] }
        }

        return surfaceVoxels
    }
}

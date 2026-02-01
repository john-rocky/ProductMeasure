//
//  PointCloudOctree.swift
//  ProductMeasure
//
//  Spatial indexing structure for efficient point cloud management
//  with automatic duplicate removal.
//

import Foundation
import simd

/// Octree node for spatial indexing of 3D points
final class OctreeNode {
    let center: SIMD3<Float>
    let halfSize: Float
    var points: [SIMD3<Float>] = []
    var children: [OctreeNode?] = Array(repeating: nil, count: 8)
    var isLeaf: Bool = true

    static let maxPointsPerNode = 16
    static let minHalfSize: Float = 0.001 // 1mm minimum subdivision

    init(center: SIMD3<Float>, halfSize: Float) {
        self.center = center
        self.halfSize = halfSize
    }

    /// Determines which octant a point belongs to
    func octantIndex(for point: SIMD3<Float>) -> Int {
        var index = 0
        if point.x >= center.x { index |= 1 }
        if point.y >= center.y { index |= 2 }
        if point.z >= center.z { index |= 4 }
        return index
    }

    /// Gets the center of a child octant
    func childCenter(for index: Int) -> SIMD3<Float> {
        let offset = halfSize * 0.5
        return SIMD3<Float>(
            center.x + ((index & 1) != 0 ? offset : -offset),
            center.y + ((index & 2) != 0 ? offset : -offset),
            center.z + ((index & 4) != 0 ? offset : -offset)
        )
    }

    /// Subdivides this node into 8 children
    func subdivide() {
        guard isLeaf else { return }

        let childHalfSize = halfSize * 0.5
        for i in 0..<8 {
            children[i] = OctreeNode(center: childCenter(for: i), halfSize: childHalfSize)
        }

        // Redistribute existing points to children
        for point in points {
            let index = octantIndex(for: point)
            children[index]?.points.append(point)
        }

        points.removeAll()
        isLeaf = false
    }

    /// Checks if a point is within the node's bounds
    func contains(_ point: SIMD3<Float>) -> Bool {
        return abs(point.x - center.x) <= halfSize &&
               abs(point.y - center.y) <= halfSize &&
               abs(point.z - center.z) <= halfSize
    }

    /// Inserts a point into the octree
    /// - Returns: true if point was inserted, false if duplicate found
    func insert(_ point: SIMD3<Float>, minSpacing: Float) -> Bool {
        guard contains(point) else { return false }

        // Check for duplicates within this node
        if isLeaf {
            for existing in points {
                if simd_distance(existing, point) < minSpacing {
                    return false // Duplicate found
                }
            }

            // Add point if below capacity or can't subdivide further
            if points.count < Self.maxPointsPerNode || halfSize <= Self.minHalfSize {
                points.append(point)
                return true
            }

            // Subdivide and try again
            subdivide()
        }

        // Insert into appropriate child
        let index = octantIndex(for: point)
        if let child = children[index] {
            // Check nearby children for duplicates (points near boundaries)
            for i in 0..<8 {
                guard let sibling = children[i], i != index else { continue }
                let distToChild = simd_distance(point, sibling.center) - sibling.halfSize * 1.732
                if distToChild < minSpacing {
                    if sibling.hasPointNear(point, within: minSpacing) {
                        return false
                    }
                }
            }
            return child.insert(point, minSpacing: minSpacing)
        }

        return false
    }

    /// Checks if there's a point within the given distance
    func hasPointNear(_ target: SIMD3<Float>, within distance: Float) -> Bool {
        // Quick bounds check
        let closestPoint = SIMD3<Float>(
            max(center.x - halfSize, min(target.x, center.x + halfSize)),
            max(center.y - halfSize, min(target.y, center.y + halfSize)),
            max(center.z - halfSize, min(target.z, center.z + halfSize))
        )

        if simd_distance(target, closestPoint) > distance {
            return false
        }

        if isLeaf {
            for point in points {
                if simd_distance(point, target) < distance {
                    return true
                }
            }
            return false
        }

        for child in children {
            if let child = child, child.hasPointNear(target, within: distance) {
                return true
            }
        }

        return false
    }

    /// Collects all points in the tree
    func collectPoints(into result: inout [SIMD3<Float>]) {
        if isLeaf {
            result.append(contentsOf: points)
        } else {
            for child in children {
                child?.collectPoints(into: &result)
            }
        }
    }

    /// Finds points within a given sphere
    func findPointsInSphere(center: SIMD3<Float>, radius: Float, result: inout [SIMD3<Float>]) {
        // Quick bounds check
        let closestPoint = SIMD3<Float>(
            max(self.center.x - halfSize, min(center.x, self.center.x + halfSize)),
            max(self.center.y - halfSize, min(center.y, self.center.y + halfSize)),
            max(self.center.z - halfSize, min(center.z, self.center.z + halfSize))
        )

        if simd_distance(center, closestPoint) > radius {
            return
        }

        if isLeaf {
            for point in points {
                if simd_distance(point, center) <= radius {
                    result.append(point)
                }
            }
        } else {
            for child in children {
                child?.findPointsInSphere(center: center, radius: radius, result: &result)
            }
        }
    }

    /// Finds k nearest neighbors
    func findKNearest(_ target: SIMD3<Float>, k: Int, result: inout [(point: SIMD3<Float>, distance: Float)]) {
        if isLeaf {
            for point in points {
                let dist = simd_distance(point, target)
                if result.count < k {
                    result.append((point, dist))
                    result.sort { $0.distance < $1.distance }
                } else if dist < result[k-1].distance {
                    result[k-1] = (point, dist)
                    result.sort { $0.distance < $1.distance }
                }
            }
        } else {
            // Sort children by distance to target for better pruning
            var childDistances: [(index: Int, distance: Float)] = []
            for i in 0..<8 {
                if let child = children[i] {
                    let dist = simd_distance(target, child.center)
                    childDistances.append((i, dist))
                }
            }
            childDistances.sort { $0.distance < $1.distance }

            for (index, _) in childDistances {
                if let child = children[index] {
                    let maxDist = result.count < k ? Float.infinity : result[k-1].distance
                    let closestPoint = SIMD3<Float>(
                        max(child.center.x - child.halfSize, min(target.x, child.center.x + child.halfSize)),
                        max(child.center.y - child.halfSize, min(target.y, child.center.y + child.halfSize)),
                        max(child.center.z - child.halfSize, min(target.z, child.center.z + child.halfSize))
                    )
                    if simd_distance(target, closestPoint) <= maxDist {
                        child.findKNearest(target, k: k, result: &result)
                    }
                }
            }
        }
    }
}

/// Point Cloud Octree for efficient spatial operations
struct PointCloudOctree {
    /// Minimum spacing between points (3mm default for duplicate detection)
    let minPointSpacing: Float

    private var root: OctreeNode?
    private var totalPointCount: Int = 0
    private var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    init(minPointSpacing: Float = 0.003) {
        self.minPointSpacing = minPointSpacing
    }

    /// Initialize with known bounds for better performance
    init(bounds: (min: SIMD3<Float>, max: SIMD3<Float>), minPointSpacing: Float = 0.003) {
        self.minPointSpacing = minPointSpacing
        let center = (bounds.min + bounds.max) * 0.5
        let size = bounds.max - bounds.min
        let halfSize = max(size.x, max(size.y, size.z)) * 0.5 + 0.1 // Add margin
        self.root = OctreeNode(center: center, halfSize: halfSize)
        self.bounds = bounds
    }

    /// Inserts points into the octree, filtering duplicates
    /// - Returns: Number of new points actually inserted
    mutating func insert(points: [SIMD3<Float>]) -> Int {
        guard !points.isEmpty else { return 0 }

        // Initialize root if needed
        if root == nil {
            let minBound = points.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let maxBound = points.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let center = (minBound + maxBound) * 0.5
            let size = maxBound - minBound
            let halfSize = max(size.x, max(size.y, size.z)) * 0.5 + 0.1 // Add margin
            root = OctreeNode(center: center, halfSize: max(halfSize, 0.5))
            bounds = (minBound, maxBound)
        }

        var insertedCount = 0
        for point in points {
            // Expand bounds if necessary
            if var currentBounds = bounds {
                currentBounds.min = simd_min(currentBounds.min, point)
                currentBounds.max = simd_max(currentBounds.max, point)
                bounds = currentBounds
            }

            // Expand tree if point is outside current bounds
            while let currentRoot = root, !currentRoot.contains(point) {
                expandRoot(toward: point)
            }

            if root?.insert(point, minSpacing: minPointSpacing) == true {
                insertedCount += 1
                totalPointCount += 1
            }
        }

        return insertedCount
    }

    /// Expands the root node to contain a point outside current bounds
    private mutating func expandRoot(toward point: SIMD3<Float>) {
        guard let oldRoot = root else { return }

        let newHalfSize = oldRoot.halfSize * 2

        // Determine which octant the old root should become
        let dirX: Float = point.x > oldRoot.center.x ? 1 : -1
        let dirY: Float = point.y > oldRoot.center.y ? 1 : -1
        let dirZ: Float = point.z > oldRoot.center.z ? 1 : -1

        let newCenter = oldRoot.center + SIMD3<Float>(
            dirX * oldRoot.halfSize,
            dirY * oldRoot.halfSize,
            dirZ * oldRoot.halfSize
        )

        let newRoot = OctreeNode(center: newCenter, halfSize: newHalfSize)
        newRoot.isLeaf = false

        // Place old root as appropriate child
        let oldIndex = newRoot.octantIndex(for: oldRoot.center)
        newRoot.children[oldIndex] = oldRoot

        // Create empty siblings
        for i in 0..<8 where i != oldIndex {
            newRoot.children[i] = OctreeNode(center: newRoot.childCenter(for: i), halfSize: oldRoot.halfSize)
        }

        root = newRoot
    }

    /// Returns all unique points in the octree
    func getAllPoints() -> [SIMD3<Float>] {
        guard let root = root else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(totalPointCount)
        root.collectPoints(into: &result)
        return result
    }

    /// Returns the current point count
    var pointCount: Int {
        return totalPointCount
    }

    /// Checks if there's a point within the given distance of target
    func hasPointNear(_ target: SIMD3<Float>, within distance: Float) -> Bool {
        return root?.hasPointNear(target, within: distance) ?? false
    }

    /// Finds all points within a sphere
    func findPointsInSphere(center: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
        guard let root = root else { return [] }
        var result: [SIMD3<Float>] = []
        root.findPointsInSphere(center: center, radius: radius, result: &result)
        return result
    }

    /// Finds k nearest neighbors to target point
    func findKNearest(_ target: SIMD3<Float>, k: Int) -> [SIMD3<Float>] {
        guard let root = root, k > 0 else { return [] }
        var result: [(point: SIMD3<Float>, distance: Float)] = []
        result.reserveCapacity(k)
        root.findKNearest(target, k: k, result: &result)
        return result.map { $0.point }
    }

    /// Computes the average nearest neighbor distance
    func averageNearestNeighborDistance(sampleSize: Int = 100) -> Float {
        let allPoints = getAllPoints()
        guard allPoints.count > 1 else { return 0 }

        let sampleCount = min(sampleSize, allPoints.count)
        var totalDistance: Float = 0
        var validSamples = 0

        let stride = max(1, allPoints.count / sampleCount)
        for i in Swift.stride(from: 0, to: allPoints.count, by: stride) {
            let nearest = findKNearest(allPoints[i], k: 2)
            if nearest.count > 1 {
                totalDistance += simd_distance(allPoints[i], nearest[1])
                validSamples += 1
            }
        }

        return validSamples > 0 ? totalDistance / Float(validSamples) : 0
    }

    /// Returns the bounding box of all points
    func getBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        return bounds
    }

    /// Clears all points from the octree
    mutating func clear() {
        root = nil
        totalPointCount = 0
        bounds = nil
    }
}

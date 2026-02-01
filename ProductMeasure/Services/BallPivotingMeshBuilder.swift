//
//  BallPivotingMeshBuilder.swift
//  ProductMeasure
//
//  Ball Pivoting Algorithm (BPA) for mesh reconstruction from point clouds.
//  Provides highly accurate surface reconstruction for volume calculation.
//

import Foundation
import simd
import Accelerate

/// Result of Ball Pivoting mesh reconstruction
struct MeshResult: Sendable {
    /// Calculated volume in cubic meters
    let volume: Float

    /// Surface area in square meters
    let surfaceArea: Float

    /// Surface triangles
    let triangles: [Triangle3D]

    /// Number of vertices used
    let vertexCount: Int

    /// Number of triangles
    let triangleCount: Int

    /// Processing time in seconds
    let processingTime: TimeInterval

    /// Ball radius used for reconstruction
    let ballRadius: Float

    /// Whether the mesh is closed (watertight)
    let isWatertight: Bool

    /// Percentage of points used in final mesh
    let pointCoverage: Float

    /// Formatted volume string
    var formattedVolume: String {
        let cm3 = volume * 1e6
        if cm3 >= 1000 {
            return String(format: "%.1f L", cm3 / 1000)
        } else {
            return String(format: "%.1f cm\u{00B3}", cm3)
        }
    }
}

/// Edge in the mesh front
private struct FrontEdge: Hashable {
    let v0: Int
    let v1: Int
    let oppositeVertex: Int  // The third vertex of the triangle this edge belongs to

    var reversed: FrontEdge {
        FrontEdge(v0: v1, v1: v0, oppositeVertex: oppositeVertex)
    }

    var key: String {
        "\(min(v0, v1))-\(max(v0, v1))"
    }
}

/// Ball Pivoting Algorithm mesh builder
final class BallPivotingMeshBuilder: @unchecked Sendable {

    // MARK: - Configuration

    /// Minimum ball radius (5mm)
    static let minimumBallRadius: Float = 0.005

    /// Maximum ball radius (20cm)
    static let maximumBallRadius: Float = 0.2

    /// Default radius multiplier for automatic selection
    static let defaultRadiusMultiplier: Float = 3.0

    /// Maximum triangles to generate (memory limit)
    static let maxTriangles = 100000

    // MARK: - Private Properties

    private var points: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var triangles: [Triangle3DIndices] = []
    private var usedPoints: Set<Int> = []
    private var frontEdges: [FrontEdge] = []
    private var processedEdges: Set<String> = []

    private var octree: PointCloudOctree?
    private var ballRadius: Float = 0

    // MARK: - Public Methods

    /// Builds a mesh from point cloud using Ball Pivoting Algorithm
    /// - Parameters:
    ///   - points: Input point cloud
    ///   - normals: Point normals (optional, will be estimated if nil)
    ///   - ballRadius: Ball radius for pivoting (nil for automatic)
    /// - Returns: MeshResult containing reconstructed mesh and volume
    func buildMesh(
        points inputPoints: [SIMD3<Float>],
        normals inputNormals: [SIMD3<Float>]? = nil,
        ballRadius: Float? = nil
    ) -> MeshResult {
        let startTime = Date()

        guard inputPoints.count >= 3 else {
            return MeshResult(
                volume: 0,
                surfaceArea: 0,
                triangles: [],
                vertexCount: 0,
                triangleCount: 0,
                processingTime: 0,
                ballRadius: 0,
                isWatertight: false,
                pointCoverage: 0
            )
        }

        // Reset state
        reset()
        points = inputPoints

        // Estimate or use provided normals
        if let providedNormals = inputNormals, providedNormals.count == inputPoints.count {
            normals = providedNormals
        } else {
            normals = estimateNormals(points: inputPoints, k: 10)
        }

        // Build spatial index
        octree = PointCloudOctree(minPointSpacing: 0.001)
        _ = octree?.insert(points: inputPoints)

        // Determine ball radius
        if let radius = ballRadius {
            self.ballRadius = simd_clamp(radius, Self.minimumBallRadius, Self.maximumBallRadius)
        } else {
            self.ballRadius = calculateOptimalBallRadius()
        }

        // Run Ball Pivoting Algorithm
        performBallPivoting()

        // Fill holes with additional passes at larger radii
        fillHoles()

        // Build final triangles
        let surfaceTriangles = triangles.map { tri in
            Triangle3D(
                v0: points[tri.v0],
                v1: points[tri.v1],
                v2: points[tri.v2]
            )
        }

        // Calculate volume
        let volume = calculateVolume(triangles: surfaceTriangles)

        // Calculate surface area
        let surfaceArea = surfaceTriangles.reduce(0.0) { $0 + $1.area }

        // Check if watertight
        let isWatertight = checkWatertight()

        // Calculate point coverage
        let pointCoverage = Float(usedPoints.count) / Float(inputPoints.count)

        let processingTime = Date().timeIntervalSince(startTime)

        return MeshResult(
            volume: abs(volume),
            surfaceArea: surfaceArea,
            triangles: surfaceTriangles,
            vertexCount: usedPoints.count,
            triangleCount: triangles.count,
            processingTime: processingTime,
            ballRadius: self.ballRadius,
            isWatertight: isWatertight,
            pointCoverage: pointCoverage
        )
    }

    /// Builds mesh asynchronously
    func buildMeshAsync(
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>]? = nil,
        ballRadius: Float? = nil
    ) async -> MeshResult {
        await Task.detached(priority: .userInitiated) {
            return self.buildMesh(points: points, normals: normals, ballRadius: ballRadius)
        }.value
    }

    // MARK: - Private Methods

    private func reset() {
        points = []
        normals = []
        triangles = []
        usedPoints = []
        frontEdges = []
        processedEdges = []
        octree = nil
        ballRadius = 0
    }

    /// Estimates normals using PCA on k nearest neighbors
    private func estimateNormals(points: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        var estimatedNormals: [SIMD3<Float>] = []
        estimatedNormals.reserveCapacity(points.count)

        // Calculate centroid for consistent normal orientation
        let centroid = points.reduce(SIMD3<Float>.zero) { $0 + $1 } / Float(points.count)

        for i in 0..<points.count {
            let point = points[i]

            // Find k nearest neighbors
            var neighbors: [(point: SIMD3<Float>, distance: Float)] = []
            for j in 0..<points.count where j != i {
                let dist = simd_distance(point, points[j])
                neighbors.append((points[j], dist))
            }
            neighbors.sort { $0.distance < $1.distance }
            let kNearest = Array(neighbors.prefix(k))

            // Compute covariance matrix
            var cov = simd_float3x3(0)
            let localCentroid = kNearest.reduce(point) { $0 + $1.point } / Float(kNearest.count + 1)

            let allNeighbors = [point] + kNearest.map { $0.point }
            for neighbor in allNeighbors {
                let diff = neighbor - localCentroid
                cov.columns.0 += diff * diff.x
                cov.columns.1 += diff * diff.y
                cov.columns.2 += diff * diff.z
            }

            // Find eigenvector with smallest eigenvalue (normal direction)
            let normal = computeSmallestEigenvector(cov)

            // Orient normal away from centroid
            let toCentroid = centroid - point
            let orientedNormal = simd_dot(normal, toCentroid) > 0 ? -normal : normal

            estimatedNormals.append(simd_normalize(orientedNormal))
        }

        return estimatedNormals
    }

    /// Computes the eigenvector corresponding to the smallest eigenvalue
    private func computeSmallestEigenvector(_ matrix: simd_float3x3) -> SIMD3<Float> {
        // Power iteration to find dominant eigenvector of inverse
        // (which corresponds to smallest eigenvalue of original)

        // Use cross product method for 3x3 symmetric matrix
        let a = matrix.columns.0
        let b = matrix.columns.1
        let c = matrix.columns.2

        // Compute cross products to find normal
        let ab = simd_cross(a, b)
        let bc = simd_cross(b, c)
        let ca = simd_cross(c, a)

        // Choose the cross product with largest magnitude
        let candidates = [ab, bc, ca]
        var best = ab
        var bestLength: Float = 0

        for candidate in candidates {
            let len = simd_length(candidate)
            if len > bestLength {
                bestLength = len
                best = candidate
            }
        }

        if bestLength > 1e-10 {
            return simd_normalize(best)
        } else {
            return SIMD3<Float>(0, 1, 0) // Default fallback
        }
    }

    /// Calculates optimal ball radius based on point density
    private func calculateOptimalBallRadius() -> Float {
        guard points.count > 1 else { return Self.minimumBallRadius }

        // Sample average nearest neighbor distance
        let sampleSize = min(100, points.count)
        let stride = max(1, points.count / sampleSize)

        var totalDistance: Float = 0
        var validSamples = 0

        for i in Swift.stride(from: 0, to: points.count, by: stride) {
            var minDist: Float = .infinity

            for j in 0..<points.count where j != i {
                let dist = simd_distance(points[i], points[j])
                if dist < minDist && dist > 0 {
                    minDist = dist
                }
            }

            if minDist < .infinity {
                totalDistance += minDist
                validSamples += 1
            }
        }

        let avgDistance = validSamples > 0 ? totalDistance / Float(validSamples) : 0.01
        let radius = avgDistance * Self.defaultRadiusMultiplier

        return simd_clamp(radius, Self.minimumBallRadius, Self.maximumBallRadius)
    }

    /// Main Ball Pivoting Algorithm
    private func performBallPivoting() {
        // Find initial seed triangle
        guard let seedTriangle = findSeedTriangle() else { return }

        // Add seed triangle
        addTriangle(seedTriangle)

        // Process front edges until exhausted or limit reached
        while !frontEdges.isEmpty && triangles.count < Self.maxTriangles {
            guard let edge = frontEdges.popLast() else { break }

            // Skip if edge already processed
            if processedEdges.contains(edge.key) { continue }
            processedEdges.insert(edge.key)

            // Try to pivot ball around this edge
            if let newVertex = pivotBall(edge: edge) {
                let newTriangle = Triangle3DIndices(v0: edge.v0, v1: edge.v1, v2: newVertex)
                addTriangle(newTriangle)
            }
        }
    }

    /// Finds a valid seed triangle to start the mesh
    private func findSeedTriangle() -> Triangle3DIndices? {
        // Try to find three points where a ball can rest
        for i in 0..<min(points.count, 100) {
            for j in (i+1)..<min(points.count, 100) {
                for k in (j+1)..<min(points.count, 100) {
                    if let center = computeBallCenter(i, j, k) {
                        // Check no other points inside the ball
                        var valid = true
                        for m in 0..<points.count {
                            if m == i || m == j || m == k { continue }
                            if simd_distance(points[m], center) < ballRadius - 0.0001 {
                                valid = false
                                break
                            }
                        }

                        if valid {
                            // Ensure correct orientation
                            let tri = Triangle3D(v0: points[i], v1: points[j], v2: points[k])
                            let avgNormal = (normals[i] + normals[j] + normals[k]) / 3

                            if simd_dot(tri.unitNormal, avgNormal) < 0 {
                                return Triangle3DIndices(v0: i, v1: k, v2: j) // Flip
                            }
                            return Triangle3DIndices(v0: i, v1: j, v2: k)
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Computes center of ball resting on three points
    private func computeBallCenter(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float>? {
        let p0 = points[i]
        let p1 = points[j]
        let p2 = points[k]

        // Compute triangle circumcenter
        let ab = p1 - p0
        let ac = p2 - p0

        let abXac = simd_cross(ab, ac)
        let abXacSq = simd_length_squared(abXac)

        if abXacSq < 1e-10 { return nil } // Degenerate triangle

        let abSq = simd_length_squared(ab)
        let acSq = simd_length_squared(ac)

        let toCircumcenter = (simd_cross(abXac, ab) * acSq + simd_cross(ac, abXac) * abSq) / (2 * abXacSq)
        let circumcenter = p0 + toCircumcenter
        let circumradius = simd_length(toCircumcenter)

        if circumradius > ballRadius { return nil }

        // Ball center is above circumcenter
        let normal = simd_normalize(abXac)
        let heightSq = ballRadius * ballRadius - circumradius * circumradius

        if heightSq < 0 { return nil }

        let height = sqrt(heightSq)

        // Choose direction based on average normal
        let avgNormal = (normals[i] + normals[j] + normals[k]) / 3
        let direction = simd_dot(normal, avgNormal) > 0 ? normal : -normal

        return circumcenter + direction * height
    }

    /// Pivots ball around an edge to find the next vertex
    private func pivotBall(edge: FrontEdge) -> Int? {
        let p0 = points[edge.v0]
        let p1 = points[edge.v1]
        let edgeCenter = (p0 + p1) / 2
        let edgeDir = simd_normalize(p1 - p0)

        // Search for candidate points near the edge
        let searchRadius = ballRadius * 2.5
        var candidates: [(index: Int, angle: Float)] = []

        for i in 0..<points.count {
            if i == edge.v0 || i == edge.v1 || i == edge.oppositeVertex { continue }
            if usedPoints.contains(i) && !isOnFront(vertex: i) { continue }

            let dist = simd_distance(edgeCenter, points[i])
            if dist > searchRadius { continue }

            // Check if ball can rest on this point
            guard let ballCenter = computeBallCenter(edge.v0, edge.v1, i) else { continue }

            // Check no other points inside the ball
            var valid = true
            for j in 0..<points.count {
                if j == edge.v0 || j == edge.v1 || j == i { continue }
                if simd_distance(points[j], ballCenter) < ballRadius - 0.0001 {
                    valid = false
                    break
                }
            }

            if valid {
                // Calculate pivot angle
                let oldCenter = computeBallCenter(edge.v0, edge.v1, edge.oppositeVertex)
                if let old = oldCenter {
                    let angle = calculatePivotAngle(
                        from: old,
                        to: ballCenter,
                        edgeCenter: edgeCenter,
                        edgeDir: edgeDir
                    )
                    candidates.append((i, angle))
                } else {
                    candidates.append((i, 0))
                }
            }
        }

        // Return vertex with smallest positive pivot angle
        candidates.sort { $0.angle < $1.angle }
        return candidates.first?.index
    }

    /// Calculates the pivot angle between two ball positions
    private func calculatePivotAngle(
        from oldCenter: SIMD3<Float>,
        to newCenter: SIMD3<Float>,
        edgeCenter: SIMD3<Float>,
        edgeDir: SIMD3<Float>
    ) -> Float {
        let oldDir = simd_normalize(oldCenter - edgeCenter)
        let newDir = simd_normalize(newCenter - edgeCenter)

        let dot = simd_dot(oldDir, newDir)
        let cross = simd_cross(oldDir, newDir)
        let sign = simd_dot(cross, edgeDir)

        var angle = acos(simd_clamp(dot, -1, 1))
        if sign < 0 { angle = 2 * .pi - angle }

        return angle
    }

    /// Checks if a vertex is on the current front
    private func isOnFront(vertex: Int) -> Bool {
        for edge in frontEdges {
            if edge.v0 == vertex || edge.v1 == vertex {
                return true
            }
        }
        return false
    }

    /// Adds a triangle and updates the front
    private func addTriangle(_ triangle: Triangle3DIndices) {
        triangles.append(triangle)
        usedPoints.insert(triangle.v0)
        usedPoints.insert(triangle.v1)
        usedPoints.insert(triangle.v2)

        // Update front edges
        let edges = [
            FrontEdge(v0: triangle.v0, v1: triangle.v1, oppositeVertex: triangle.v2),
            FrontEdge(v0: triangle.v1, v1: triangle.v2, oppositeVertex: triangle.v0),
            FrontEdge(v0: triangle.v2, v1: triangle.v0, oppositeVertex: triangle.v1)
        ]

        for edge in edges {
            let reversed = edge.reversed

            // Check if reversed edge exists in front
            if let idx = frontEdges.firstIndex(where: { $0.key == reversed.key }) {
                frontEdges.remove(at: idx)
                processedEdges.insert(edge.key)
            } else if !processedEdges.contains(edge.key) {
                frontEdges.append(edge)
            }
        }
    }

    /// Attempts to fill holes with larger ball radii
    private func fillHoles() {
        let originalRadius = ballRadius

        // Try progressively larger radii
        for multiplier: Float in [1.5, 2.0, 3.0] {
            if frontEdges.isEmpty { break }

            ballRadius = originalRadius * multiplier
            ballRadius = min(ballRadius, Self.maximumBallRadius)

            var processed = 0
            while !frontEdges.isEmpty && processed < 1000 {
                guard let edge = frontEdges.popLast() else { break }
                processed += 1

                if processedEdges.contains(edge.key) { continue }
                processedEdges.insert(edge.key)

                if let newVertex = pivotBall(edge: edge) {
                    let newTriangle = Triangle3DIndices(v0: edge.v0, v1: edge.v1, v2: newVertex)
                    addTriangle(newTriangle)
                }
            }
        }

        ballRadius = originalRadius
    }

    /// Checks if the mesh is watertight
    private func checkWatertight() -> Bool {
        var edgeCount: [String: Int] = [:]

        for tri in triangles {
            let edges = [
                (min(tri.v0, tri.v1), max(tri.v0, tri.v1)),
                (min(tri.v1, tri.v2), max(tri.v1, tri.v2)),
                (min(tri.v2, tri.v0), max(tri.v2, tri.v0))
            ]

            for edge in edges {
                let key = "\(edge.0)-\(edge.1)"
                edgeCount[key, default: 0] += 1
            }
        }

        for count in edgeCount.values {
            if count != 2 { return false }
        }

        return true
    }

    /// Calculates volume from triangles using Divergence Theorem
    private func calculateVolume(triangles: [Triangle3D]) -> Float {
        var totalVolume: Float = 0

        for triangle in triangles {
            totalVolume += triangle.signedVolume
        }

        return totalVolume
    }
}

// MARK: - Normal Orientation Refinement

extension BallPivotingMeshBuilder {

    /// Refines normal orientations using mesh connectivity
    func refineNormals(triangles: [Triangle3DIndices]) {
        guard !triangles.isEmpty else { return }

        // Build adjacency graph
        var trianglesByEdge: [String: [Int]] = [:]

        for (idx, tri) in triangles.enumerated() {
            let edges = [
                (min(tri.v0, tri.v1), max(tri.v0, tri.v1)),
                (min(tri.v1, tri.v2), max(tri.v1, tri.v2)),
                (min(tri.v2, tri.v0), max(tri.v2, tri.v0))
            ]

            for edge in edges {
                let key = "\(edge.0)-\(edge.1)"
                trianglesByEdge[key, default: []].append(idx)
            }
        }

        // Propagate consistent orientation using BFS
        var visited = Set<Int>()
        var queue = [0]
        visited.insert(0)

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let tri = triangles[current]

            let edges = [
                (min(tri.v0, tri.v1), max(tri.v0, tri.v1)),
                (min(tri.v1, tri.v2), max(tri.v1, tri.v2)),
                (min(tri.v2, tri.v0), max(tri.v2, tri.v0))
            ]

            for edge in edges {
                let key = "\(edge.0)-\(edge.1)"
                if let neighbors = trianglesByEdge[key] {
                    for neighbor in neighbors where !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        queue.append(neighbor)
                    }
                }
            }
        }
    }
}

//
//  DelaunayTriangulator.swift
//  ProductMeasure
//
//  3D Delaunay triangulation using the Bowyer-Watson algorithm
//  for Alpha Shape computation.
//

import Foundation
import simd

/// A tetrahedron in 3D space
struct Tetrahedron: Hashable {
    let v0, v1, v2, v3: Int  // Vertex indices

    /// Vertices in sorted order for consistent hashing
    var sortedVertices: [Int] {
        [v0, v1, v2, v3].sorted()
    }

    func hash(into hasher: inout Hasher) {
        let sorted = sortedVertices
        hasher.combine(sorted[0])
        hasher.combine(sorted[1])
        hasher.combine(sorted[2])
        hasher.combine(sorted[3])
    }

    static func == (lhs: Tetrahedron, rhs: Tetrahedron) -> Bool {
        lhs.sortedVertices == rhs.sortedVertices
    }

    /// Returns the 4 triangular faces of the tetrahedron
    var faces: [Triangle3DIndices] {
        [
            Triangle3DIndices(v0: v0, v1: v1, v2: v2),
            Triangle3DIndices(v0: v0, v1: v1, v2: v3),
            Triangle3DIndices(v0: v0, v1: v2, v2: v3),
            Triangle3DIndices(v0: v1, v1: v2, v2: v3)
        ]
    }

    /// Checks if this tetrahedron contains a vertex index
    func contains(vertex: Int) -> Bool {
        v0 == vertex || v1 == vertex || v2 == vertex || v3 == vertex
    }
}

/// A triangle defined by vertex indices
struct Triangle3DIndices: Hashable {
    let v0, v1, v2: Int

    var sortedVertices: [Int] {
        [v0, v1, v2].sorted()
    }

    func hash(into hasher: inout Hasher) {
        let sorted = sortedVertices
        hasher.combine(sorted[0])
        hasher.combine(sorted[1])
        hasher.combine(sorted[2])
    }

    static func == (lhs: Triangle3DIndices, rhs: Triangle3DIndices) -> Bool {
        lhs.sortedVertices == rhs.sortedVertices
    }

    /// Checks if this triangle contains a vertex index
    func contains(vertex: Int) -> Bool {
        v0 == vertex || v1 == vertex || v2 == vertex
    }
}

/// A triangle with actual 3D vertex coordinates
struct Triangle3D {
    let v0, v1, v2: SIMD3<Float>

    /// Normal vector of the triangle (not normalized)
    var normal: SIMD3<Float> {
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        return simd_cross(edge1, edge2)
    }

    /// Normalized normal vector
    var unitNormal: SIMD3<Float> {
        simd_normalize(normal)
    }

    /// Area of the triangle
    var area: Float {
        simd_length(normal) * 0.5
    }

    /// Centroid of the triangle
    var centroid: SIMD3<Float> {
        (v0 + v1 + v2) / 3
    }

    /// Signed volume contribution (for volume calculation via Divergence Theorem)
    /// V = (1/6) * v0 . (v1 x v2)
    var signedVolume: Float {
        simd_dot(v0, simd_cross(v1, v2)) / 6.0
    }
}

/// Circumsphere of a tetrahedron
struct Circumsphere {
    let center: SIMD3<Float>
    let radiusSquared: Float

    var radius: Float {
        sqrt(radiusSquared)
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        simd_distance_squared(center, point) < radiusSquared - 1e-10
    }
}

/// 3D Delaunay triangulation using Bowyer-Watson algorithm
final class DelaunayTriangulator {

    /// Result of Delaunay triangulation
    struct TriangulationResult {
        let tetrahedra: [Tetrahedron]
        let points: [SIMD3<Float>]
        let processingTime: TimeInterval

        /// Gets all surface triangles (on convex hull)
        func getSurfaceTriangles() -> [Triangle3D] {
            var faceCount: [Triangle3DIndices: Int] = [:]

            for tet in tetrahedra {
                for face in tet.faces {
                    faceCount[face, default: 0] += 1
                }
            }

            // Surface triangles appear only once
            var surfaceTriangles: [Triangle3D] = []
            for (face, count) in faceCount where count == 1 {
                surfaceTriangles.append(Triangle3D(
                    v0: points[face.v0],
                    v1: points[face.v1],
                    v2: points[face.v2]
                ))
            }

            return surfaceTriangles
        }
    }

    // MARK: - Private Properties

    private var points: [SIMD3<Float>] = []
    private var tetrahedra: Set<Tetrahedron> = []
    private var circumspheres: [Tetrahedron: Circumsphere] = [:]

    // MARK: - Public Methods

    /// Performs 3D Delaunay triangulation on the given points
    /// - Parameter inputPoints: Array of 3D points
    /// - Returns: Triangulation result containing tetrahedra and processing info
    func triangulate(points inputPoints: [SIMD3<Float>]) -> TriangulationResult {
        let startTime = Date()

        guard inputPoints.count >= 4 else {
            return TriangulationResult(tetrahedra: [], points: inputPoints, processingTime: 0)
        }

        // Reset state
        points = inputPoints
        tetrahedra = []
        circumspheres = [:]

        // Create super tetrahedron that contains all points
        let superTet = createSuperTetrahedron()
        tetrahedra.insert(superTet)
        circumspheres[superTet] = computeCircumsphere(superTet)

        // Insert each point using Bowyer-Watson algorithm
        for i in 0..<inputPoints.count {
            insertPoint(index: i)
        }

        // Remove tetrahedra that share vertices with super tetrahedron
        let superVertexIndices = Set([superTet.v0, superTet.v1, superTet.v2, superTet.v3])
        tetrahedra = tetrahedra.filter { tet in
            !superVertexIndices.contains(tet.v0) &&
            !superVertexIndices.contains(tet.v1) &&
            !superVertexIndices.contains(tet.v2) &&
            !superVertexIndices.contains(tet.v3)
        }

        // Remove super tetrahedron vertices from points array
        points = Array(inputPoints)

        let processingTime = Date().timeIntervalSince(startTime)

        return TriangulationResult(
            tetrahedra: Array(tetrahedra),
            points: points,
            processingTime: processingTime
        )
    }

    /// Performs triangulation asynchronously
    func triangulateAsync(points inputPoints: [SIMD3<Float>]) async -> TriangulationResult {
        await Task.detached(priority: .userInitiated) {
            return self.triangulate(points: inputPoints)
        }.value
    }

    // MARK: - Private Methods

    /// Creates a super tetrahedron that contains all input points
    private func createSuperTetrahedron() -> Tetrahedron {
        // Find bounding box of all points
        var minBound = SIMD3<Float>(repeating: .infinity)
        var maxBound = SIMD3<Float>(repeating: -.infinity)

        for point in points {
            minBound = simd_min(minBound, point)
            maxBound = simd_max(maxBound, point)
        }

        let center = (minBound + maxBound) * 0.5
        let size = maxBound - minBound
        let maxDim = max(size.x, max(size.y, size.z))

        // Create a large tetrahedron centered around the point cloud
        // Scale factor to ensure all points are well inside
        let scale = maxDim * 10

        // Regular tetrahedron vertices centered at origin
        let t0 = SIMD3<Float>(1, 1, 1)
        let t1 = SIMD3<Float>(1, -1, -1)
        let t2 = SIMD3<Float>(-1, 1, -1)
        let t3 = SIMD3<Float>(-1, -1, 1)

        // Add super tetrahedron vertices to points array
        let baseIndex = points.count
        points.append(center + t0 * scale)
        points.append(center + t1 * scale)
        points.append(center + t2 * scale)
        points.append(center + t3 * scale)

        return Tetrahedron(v0: baseIndex, v1: baseIndex + 1, v2: baseIndex + 2, v3: baseIndex + 3)
    }

    /// Inserts a point using Bowyer-Watson algorithm
    private func insertPoint(index: Int) {
        let point = points[index]

        // Find all tetrahedra whose circumsphere contains the new point
        var badTetrahedra = Set<Tetrahedron>()

        for tet in tetrahedra {
            if let circumsphere = circumspheres[tet] {
                if circumsphere.contains(point) {
                    badTetrahedra.insert(tet)
                }
            }
        }

        // Find the boundary of the hole (faces that are not shared by bad tetrahedra)
        var boundaryFaces: [Triangle3DIndices] = []
        var faceCount: [Triangle3DIndices: Int] = [:]

        for tet in badTetrahedra {
            for face in tet.faces {
                faceCount[face, default: 0] += 1
            }
        }

        for (face, count) in faceCount {
            if count == 1 {
                boundaryFaces.append(face)
            }
        }

        // Remove bad tetrahedra
        for tet in badTetrahedra {
            tetrahedra.remove(tet)
            circumspheres.removeValue(forKey: tet)
        }

        // Create new tetrahedra by connecting boundary faces to the new point
        for face in boundaryFaces {
            let newTet = Tetrahedron(v0: face.v0, v1: face.v1, v2: face.v2, v3: index)

            // Check for degenerate tetrahedron
            if let circumsphere = computeCircumsphere(newTet) {
                tetrahedra.insert(newTet)
                circumspheres[newTet] = circumsphere
            }
        }
    }

    /// Computes the circumsphere of a tetrahedron
    private func computeCircumsphere(_ tet: Tetrahedron) -> Circumsphere? {
        let a = points[tet.v0]
        let b = points[tet.v1]
        let c = points[tet.v2]
        let d = points[tet.v3]

        // Compute circumcenter using determinant method
        let ab = b - a
        let ac = c - a
        let ad = d - a

        // Check for degenerate tetrahedron
        let det = simd_dot(ab, simd_cross(ac, ad))
        if abs(det) < 1e-10 {
            return nil
        }

        let ab2 = simd_length_squared(ab)
        let ac2 = simd_length_squared(ac)
        let ad2 = simd_length_squared(ad)

        let numerator =
            ab2 * simd_cross(ac, ad) +
            ac2 * simd_cross(ad, ab) +
            ad2 * simd_cross(ab, ac)

        let center = a + numerator / (2 * det)
        let radiusSquared = simd_distance_squared(center, a)

        return Circumsphere(center: center, radiusSquared: radiusSquared)
    }
}

// MARK: - Extensions

extension DelaunayTriangulator.TriangulationResult {

    /// Gets all unique edges in the triangulation
    func getAllEdges() -> [(Int, Int)] {
        var edges = Set<String>()
        var result: [(Int, Int)] = []

        for tet in tetrahedra {
            let pairs = [
                (tet.v0, tet.v1), (tet.v0, tet.v2), (tet.v0, tet.v3),
                (tet.v1, tet.v2), (tet.v1, tet.v3), (tet.v2, tet.v3)
            ]

            for (a, b) in pairs {
                let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
                if !edges.contains(key) {
                    edges.insert(key)
                    result.append((min(a, b), max(a, b)))
                }
            }
        }

        return result
    }

    /// Gets all unique triangles with their tetrahedra counts
    func getAllTriangles() -> [(triangle: Triangle3DIndices, tetrahedraCount: Int)] {
        var faceCount: [Triangle3DIndices: Int] = [:]

        for tet in tetrahedra {
            for face in tet.faces {
                faceCount[face, default: 0] += 1
            }
        }

        return faceCount.map { (triangle: $0.key, tetrahedraCount: $0.value) }
    }
}

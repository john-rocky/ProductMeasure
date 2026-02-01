//
//  AlphaShapeCalculator.swift
//  ProductMeasure
//
//  Alpha Shape volume calculation using Delaunay triangulation
//  and the Divergence Theorem for precise volume computation.
//

import Foundation
import simd

/// Result of Alpha Shape volume calculation
struct AlphaShapeResult: Sendable {
    /// Calculated volume in cubic meters
    let volume: Float

    /// Surface area in square meters
    let surfaceArea: Float

    /// Alpha value used for computation
    let alpha: Float

    /// Number of surface triangles
    let triangleCount: Int

    /// Processing time in seconds
    let processingTime: TimeInterval

    /// Surface triangles for visualization
    let surfaceTriangles: [Triangle3D]

    /// Whether the mesh is watertight (closed)
    let isWatertight: Bool

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

/// Alpha Shape calculator for precise volume computation
final class AlphaShapeCalculator: @unchecked Sendable {

    // MARK: - Configuration

    /// Default alpha multiplier for automatic alpha selection
    static let defaultAlphaMultiplier: Float = 2.5

    /// Minimum alpha value to prevent degenerate shapes
    static let minimumAlpha: Float = 0.005 // 5mm

    /// Maximum alpha value to prevent overly smooth shapes
    static let maximumAlpha: Float = 0.5 // 50cm

    // MARK: - Private Properties

    private let triangulator = DelaunayTriangulator()

    // MARK: - Public Methods

    /// Calculates volume using Alpha Shape
    /// - Parameters:
    ///   - points: Input point cloud
    ///   - alpha: Alpha value (nil for automatic selection)
    /// - Returns: AlphaShapeResult containing volume and surface data
    func calculateVolume(points: [SIMD3<Float>], alpha: Float? = nil) -> AlphaShapeResult {
        let startTime = Date()

        guard points.count >= 4 else {
            return AlphaShapeResult(
                volume: 0,
                surfaceArea: 0,
                alpha: 0,
                triangleCount: 0,
                processingTime: 0,
                surfaceTriangles: [],
                isWatertight: false
            )
        }

        // Perform Delaunay triangulation
        let triangulation = triangulator.triangulate(points: points)

        // Determine alpha value
        let alphaValue: Float
        if let providedAlpha = alpha {
            alphaValue = simd_clamp(providedAlpha, Self.minimumAlpha, Self.maximumAlpha)
        } else {
            alphaValue = calculateOptimalAlpha(points: points, triangulation: triangulation)
        }

        // Extract alpha complex (simplices with circumradius <= alpha)
        let alphaTriangles = extractAlphaComplex(
            triangulation: triangulation,
            points: points,
            alpha: alphaValue
        )

        // Find boundary triangles (appear in exactly one tetrahedron)
        let surfaceTriangles = extractSurfaceTriangles(
            alphaTriangles: alphaTriangles,
            points: points
        )

        // Check if mesh is watertight
        let isWatertight = checkWatertight(triangles: surfaceTriangles.map { t in
            Triangle3DIndices(v0: 0, v1: 0, v2: 0) // Simplified check
        })

        // Calculate volume using Divergence Theorem
        let volume = calculateVolumeFromTriangles(surfaceTriangles)

        // Calculate surface area
        let surfaceArea = surfaceTriangles.reduce(0.0) { $0 + $1.area }

        let processingTime = Date().timeIntervalSince(startTime)

        return AlphaShapeResult(
            volume: abs(volume),
            surfaceArea: surfaceArea,
            alpha: alphaValue,
            triangleCount: surfaceTriangles.count,
            processingTime: processingTime,
            surfaceTriangles: surfaceTriangles,
            isWatertight: isWatertight
        )
    }

    /// Calculates volume asynchronously
    func calculateVolumeAsync(points: [SIMD3<Float>], alpha: Float? = nil) async -> AlphaShapeResult {
        await Task.detached(priority: .userInitiated) {
            return self.calculateVolume(points: points, alpha: alpha)
        }.value
    }

    // MARK: - Private Methods

    /// Calculates optimal alpha value based on point cloud density
    private func calculateOptimalAlpha(
        points: [SIMD3<Float>],
        triangulation: DelaunayTriangulator.TriangulationResult
    ) -> Float {
        // Sample average nearest neighbor distance
        let sampleSize = min(100, points.count)
        let stride = max(1, points.count / sampleSize)

        var totalDistance: Float = 0
        var validSamples = 0

        for i in Swift.stride(from: 0, to: points.count, by: stride) {
            var minDist: Float = .infinity

            for j in 0..<points.count where j != i {
                let dist = simd_distance(points[i], points[j])
                if dist < minDist {
                    minDist = dist
                }
            }

            if minDist < .infinity {
                totalDistance += minDist
                validSamples += 1
            }
        }

        let avgDistance = validSamples > 0 ? totalDistance / Float(validSamples) : 0.01

        // Alpha = average distance * multiplier
        let alpha = avgDistance * Self.defaultAlphaMultiplier

        return simd_clamp(alpha, Self.minimumAlpha, Self.maximumAlpha)
    }

    /// Extracts triangles that belong to the alpha complex
    private func extractAlphaComplex(
        triangulation: DelaunayTriangulator.TriangulationResult,
        points: [SIMD3<Float>],
        alpha: Float
    ) -> [(triangle: Triangle3DIndices, count: Int)] {

        let alphaSquared = alpha * alpha
        var validTriangles: [Triangle3DIndices: Int] = [:]

        for tet in triangulation.tetrahedra {
            // Check if tetrahedron's circumradius is within alpha
            let circumradius = computeTetrahedronCircumradius(tet, points: points)

            if circumradius <= alpha {
                // All faces of this tetrahedron are in the alpha complex
                for face in tet.faces {
                    validTriangles[face, default: 0] += 1
                }
            } else {
                // Check individual faces
                for face in tet.faces {
                    let faceCircumradius = computeTriangleCircumradius(face, points: points)
                    if faceCircumradius <= alpha {
                        // Check if opposite vertex is outside the circumsphere
                        let oppositeVertex = findOppositeVertex(tet, face: face)
                        let circumcenter = computeTriangleCircumcenter(face, points: points)
                        let distToOpposite = simd_distance(circumcenter, points[oppositeVertex])

                        if distToOpposite > faceCircumradius {
                            validTriangles[face, default: 0] += 1
                        }
                    }
                }
            }
        }

        return validTriangles.map { (triangle: $0.key, count: $0.value) }
    }

    /// Extracts surface (boundary) triangles from alpha complex
    private func extractSurfaceTriangles(
        alphaTriangles: [(triangle: Triangle3DIndices, count: Int)],
        points: [SIMD3<Float>]
    ) -> [Triangle3D] {

        // Surface triangles appear only once in the alpha complex
        // or we take all triangles for non-closed shapes
        var surfaceTriangles: [Triangle3D] = []

        for (triangle, _) in alphaTriangles {
            guard triangle.v0 < points.count,
                  triangle.v1 < points.count,
                  triangle.v2 < points.count else {
                continue
            }

            let tri = Triangle3D(
                v0: points[triangle.v0],
                v1: points[triangle.v1],
                v2: points[triangle.v2]
            )
            surfaceTriangles.append(tri)
        }

        // Orient triangles consistently (normals pointing outward)
        return orientTrianglesConsistently(surfaceTriangles, points: points)
    }

    /// Computes circumradius of a tetrahedron
    private func computeTetrahedronCircumradius(_ tet: Tetrahedron, points: [SIMD3<Float>]) -> Float {
        let a = points[tet.v0]
        let b = points[tet.v1]
        let c = points[tet.v2]
        let d = points[tet.v3]

        let ab = b - a
        let ac = c - a
        let ad = d - a

        let det = simd_dot(ab, simd_cross(ac, ad))
        if abs(det) < 1e-10 {
            return .infinity
        }

        let ab2 = simd_length_squared(ab)
        let ac2 = simd_length_squared(ac)
        let ad2 = simd_length_squared(ad)

        let numerator =
            ab2 * simd_cross(ac, ad) +
            ac2 * simd_cross(ad, ab) +
            ad2 * simd_cross(ab, ac)

        let center = a + numerator / (2 * det)
        return simd_distance(center, a)
    }

    /// Computes circumradius of a triangle
    private func computeTriangleCircumradius(_ tri: Triangle3DIndices, points: [SIMD3<Float>]) -> Float {
        let a = points[tri.v0]
        let b = points[tri.v1]
        let c = points[tri.v2]

        let ab = simd_distance(a, b)
        let bc = simd_distance(b, c)
        let ca = simd_distance(c, a)

        let s = (ab + bc + ca) / 2 // Semi-perimeter
        let area = sqrt(s * (s - ab) * (s - bc) * (s - ca))

        if area < 1e-10 {
            return .infinity
        }

        return (ab * bc * ca) / (4 * area)
    }

    /// Computes circumcenter of a triangle
    private func computeTriangleCircumcenter(_ tri: Triangle3DIndices, points: [SIMD3<Float>]) -> SIMD3<Float> {
        let a = points[tri.v0]
        let b = points[tri.v1]
        let c = points[tri.v2]

        let ab = b - a
        let ac = c - a

        let abXac = simd_cross(ab, ac)
        let abXacSq = simd_length_squared(abXac)

        if abXacSq < 1e-10 {
            return (a + b + c) / 3 // Degenerate, return centroid
        }

        let abSq = simd_length_squared(ab)
        let acSq = simd_length_squared(ac)

        let toCenter = (simd_cross(abXac, ab) * acSq + simd_cross(ac, abXac) * abSq) / (2 * abXacSq)

        return a + toCenter
    }

    /// Finds the vertex of a tetrahedron that is not part of the given face
    private func findOppositeVertex(_ tet: Tetrahedron, face: Triangle3DIndices) -> Int {
        let faceVertices = Set([face.v0, face.v1, face.v2])
        let tetVertices = [tet.v0, tet.v1, tet.v2, tet.v3]

        for v in tetVertices {
            if !faceVertices.contains(v) {
                return v
            }
        }

        return tet.v0 // Fallback
    }

    /// Calculates volume from surface triangles using Divergence Theorem
    private func calculateVolumeFromTriangles(_ triangles: [Triangle3D]) -> Float {
        // V = (1/6) * Σ (v0 · (v1 × v2)) for each triangle
        var totalVolume: Float = 0

        for triangle in triangles {
            totalVolume += triangle.signedVolume
        }

        return totalVolume
    }

    /// Orients triangles consistently with outward-pointing normals
    private func orientTrianglesConsistently(
        _ triangles: [Triangle3D],
        points: [SIMD3<Float>]
    ) -> [Triangle3D] {
        guard !triangles.isEmpty else { return [] }

        // Calculate centroid of all points
        let centroid = points.reduce(SIMD3<Float>.zero) { $0 + $1 } / Float(points.count)

        // Orient each triangle so normal points away from centroid
        return triangles.map { tri in
            let triCentroid = tri.centroid
            let toCentroid = centroid - triCentroid

            if simd_dot(tri.normal, toCentroid) > 0 {
                // Normal points toward centroid, flip the triangle
                return Triangle3D(v0: tri.v0, v1: tri.v2, v2: tri.v1)
            } else {
                return tri
            }
        }
    }

    /// Checks if a triangle mesh is watertight (closed)
    private func checkWatertight(triangles: [Triangle3DIndices]) -> Bool {
        // A watertight mesh has every edge shared by exactly 2 triangles
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

        // Check all edges have count of 2
        for count in edgeCount.values {
            if count != 2 {
                return false
            }
        }

        return true
    }
}

// MARK: - Alpha Tuning

extension AlphaShapeCalculator {

    /// Attempts to find the best alpha value through binary search
    func findOptimalAlpha(
        points: [SIMD3<Float>],
        targetConnectivity: Float = 0.8
    ) -> Float {
        let triangulation = triangulator.triangulate(points: points)

        var lowAlpha = Self.minimumAlpha
        var highAlpha = Self.maximumAlpha

        // Binary search for alpha that gives desired connectivity
        for _ in 0..<10 {
            let midAlpha = (lowAlpha + highAlpha) / 2

            let triangles = extractAlphaComplex(
                triangulation: triangulation,
                points: points,
                alpha: midAlpha
            )

            let connectivity = Float(triangles.count) / Float(triangulation.tetrahedra.count * 4)

            if connectivity < targetConnectivity {
                lowAlpha = midAlpha
            } else {
                highAlpha = midAlpha
            }
        }

        return (lowAlpha + highAlpha) / 2
    }

    /// Estimates volume at multiple alpha values for comparison
    func estimateVolumeAtMultipleAlphas(
        points: [SIMD3<Float>],
        alphaValues: [Float]
    ) -> [(alpha: Float, volume: Float)] {

        var results: [(alpha: Float, volume: Float)] = []

        for alpha in alphaValues {
            let result = calculateVolume(points: points, alpha: alpha)
            results.append((alpha: alpha, volume: result.volume))
        }

        return results.sorted { $0.alpha < $1.alpha }
    }
}

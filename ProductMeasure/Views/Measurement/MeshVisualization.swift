//
//  MeshVisualization.swift
//  ProductMeasure
//
//  3D visualization of mesh surfaces from Alpha Shape and Ball Pivoting
//  reconstruction for AR display.
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing reconstructed mesh surfaces
class MeshVisualization {

    // MARK: - Properties

    private(set) var entity: Entity
    private var meshEntity: ModelEntity?
    private var wireframeEntity: Entity?

    /// Whether the visualization is currently visible
    var isVisible: Bool = true {
        didSet {
            entity.isEnabled = isVisible
        }
    }

    /// Current visualization mode
    enum DisplayMode {
        case solid           // Solid surface with lighting
        case wireframe       // Wireframe only
        case solidWireframe  // Both solid and wireframe
        case transparent     // Semi-transparent surface
    }

    var displayMode: DisplayMode = .transparent {
        didSet {
            updateDisplayMode()
        }
    }

    // MARK: - Constants

    /// Default surface color (semi-transparent blue)
    private let surfaceColor = UIColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.4)

    /// Wireframe color
    private let wireframeColor = UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.8)

    /// Maximum triangles to display (performance limit)
    private let maxDisplayTriangles = 10000

    // MARK: - Initialization

    init() {
        self.entity = Entity()
        self.entity.name = "mesh_visualization"
    }

    // MARK: - Public Methods

    /// Update visualization with Alpha Shape result
    func update(with result: AlphaShapeResult) {
        clearMesh()

        let triangles = Array(result.surfaceTriangles.prefix(maxDisplayTriangles))
        guard !triangles.isEmpty else { return }

        createMeshEntity(from: triangles, color: surfaceColor)
        updateDisplayMode()

        print("[MeshViz] Created mesh with \(triangles.count) triangles from Alpha Shape")
    }

    /// Update visualization with Ball Pivoting result
    func update(with result: MeshResult) {
        clearMesh()

        let triangles = Array(result.triangles.prefix(maxDisplayTriangles))
        guard !triangles.isEmpty else { return }

        createMeshEntity(from: triangles, color: surfaceColor)
        updateDisplayMode()

        print("[MeshViz] Created mesh with \(triangles.count) triangles from Ball Pivoting")
    }

    /// Update visualization with raw triangles
    func update(with triangles: [Triangle3D], color: UIColor? = nil) {
        clearMesh()

        let displayTriangles = Array(triangles.prefix(maxDisplayTriangles))
        guard !displayTriangles.isEmpty else { return }

        createMeshEntity(from: displayTriangles, color: color ?? surfaceColor)
        updateDisplayMode()
    }

    /// Clear all mesh visualizations
    func clearMesh() {
        meshEntity?.removeFromParent()
        meshEntity = nil

        wireframeEntity?.removeFromParent()
        wireframeEntity = nil
    }

    /// Set the opacity of the mesh surface
    func setOpacity(_ opacity: Float) {
        guard let meshEntity = meshEntity else { return }

        let color = UIColor(
            red: 0.3,
            green: 0.5,
            blue: 0.9,
            alpha: CGFloat(opacity)
        )

        let material = UnlitMaterial(color: color)
        meshEntity.model?.materials = [material]
    }

    /// Animate mesh appearing with fade-in effect
    func animateAppear(duration: TimeInterval = 0.5) {
        entity.scale = SIMD3<Float>(repeating: 0.01)

        // Animate scale up
        var transform = entity.transform
        transform.scale = SIMD3<Float>(repeating: 1.0)

        entity.move(
            to: transform,
            relativeTo: entity.parent,
            duration: duration,
            timingFunction: .easeOut
        )
    }

    // MARK: - Private Methods

    /// Creates a mesh entity from triangles
    private func createMeshEntity(from triangles: [Triangle3D], color: UIColor) {
        // Build mesh descriptor
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(triangles.count * 3)
        normals.reserveCapacity(triangles.count * 3)
        indices.reserveCapacity(triangles.count * 3)

        for (idx, triangle) in triangles.enumerated() {
            let normal = triangle.unitNormal

            // Add vertices
            positions.append(triangle.v0)
            positions.append(triangle.v1)
            positions.append(triangle.v2)

            // Add normals (same normal for all vertices of flat-shaded triangle)
            normals.append(normal)
            normals.append(normal)
            normals.append(normal)

            // Add indices
            let baseIndex = UInt32(idx * 3)
            indices.append(baseIndex)
            indices.append(baseIndex + 1)
            indices.append(baseIndex + 2)
        }

        // Create mesh resource
        var descriptor = MeshDescriptor(name: "surface_mesh")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)

        guard let meshResource = try? MeshResource.generate(from: [descriptor]) else {
            print("[MeshViz] Failed to generate mesh resource")
            return
        }

        // Create material
        let material = UnlitMaterial(color: color)

        // Create entity
        let newMeshEntity = ModelEntity(mesh: meshResource, materials: [material])
        newMeshEntity.name = "surface_mesh_entity"

        entity.addChild(newMeshEntity)
        meshEntity = newMeshEntity

        // Create wireframe if needed
        if displayMode == .wireframe || displayMode == .solidWireframe {
            createWireframe(from: triangles)
        }
    }

    /// Creates wireframe visualization from triangles
    private func createWireframe(from triangles: [Triangle3D]) {
        let wireframeContainer = Entity()
        wireframeContainer.name = "wireframe_container"

        // Collect unique edges
        var edgeSet = Set<String>()
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []

        for triangle in triangles {
            let triangleEdges = [
                (triangle.v0, triangle.v1),
                (triangle.v1, triangle.v2),
                (triangle.v2, triangle.v0)
            ]

            for (start, end) in triangleEdges {
                // Create consistent key for edge
                let key: String
                if simd_length(start) < simd_length(end) {
                    key = "\(start.x),\(start.y),\(start.z)-\(end.x),\(end.y),\(end.z)"
                } else {
                    key = "\(end.x),\(end.y),\(end.z)-\(start.x),\(start.y),\(start.z)"
                }

                if !edgeSet.contains(key) {
                    edgeSet.insert(key)
                    edges.append((start, end))
                }
            }
        }

        // Limit edges for performance
        let displayEdges = Array(edges.prefix(20000))

        // Create line segments
        let lineThickness: Float = 0.001

        for (start, end) in displayEdges {
            let length = simd_distance(start, end)
            guard length > 0.0001 else { continue }

            // Create thin cylinder for edge
            let lineMesh = MeshResource.generateBox(
                size: SIMD3<Float>(lineThickness, lineThickness, length)
            )

            let lineMaterial = UnlitMaterial(color: wireframeColor)
            let lineEntity = ModelEntity(mesh: lineMesh, materials: [lineMaterial])

            // Position and orient
            let midpoint = (start + end) / 2
            let direction = simd_normalize(end - start)

            // Calculate rotation to align Z with edge direction
            let defaultDir = SIMD3<Float>(0, 0, 1)
            let rotation = simd_quatf(from: defaultDir, to: direction)

            lineEntity.position = midpoint
            lineEntity.orientation = rotation

            wireframeContainer.addChild(lineEntity)
        }

        entity.addChild(wireframeContainer)
        wireframeEntity = wireframeContainer

        print("[MeshViz] Created wireframe with \(displayEdges.count) edges")
    }

    /// Updates visibility based on display mode
    private func updateDisplayMode() {
        switch displayMode {
        case .solid:
            meshEntity?.isEnabled = true
            wireframeEntity?.isEnabled = false
            setOpacity(0.8)

        case .wireframe:
            meshEntity?.isEnabled = false
            wireframeEntity?.isEnabled = true

        case .solidWireframe:
            meshEntity?.isEnabled = true
            wireframeEntity?.isEnabled = true
            setOpacity(0.4)

        case .transparent:
            meshEntity?.isEnabled = true
            wireframeEntity?.isEnabled = false
            setOpacity(0.35)
        }
    }
}

// MARK: - Comparison Visualization

extension MeshVisualization {

    /// Displays volume comparison between different calculation methods
    struct VolumeComparison {
        let voxelVolume: Float?
        let alphaShapeVolume: Float?
        let meshVolume: Float?

        var description: String {
            var parts: [String] = []

            if let v = voxelVolume {
                parts.append("Voxel: \(formatVolume(v))")
            }
            if let a = alphaShapeVolume {
                parts.append("Alpha: \(formatVolume(a))")
            }
            if let m = meshVolume {
                parts.append("Mesh: \(formatVolume(m))")
            }

            return parts.joined(separator: " | ")
        }

        private func formatVolume(_ m3: Float) -> String {
            let cm3 = m3 * 1e6
            if cm3 >= 1000 {
                return String(format: "%.1f L", cm3 / 1000)
            } else {
                return String(format: "%.0f cm\u{00B3}", cm3)
            }
        }
    }

    /// Creates a side-by-side comparison visualization
    func showComparison(
        voxelResult: VoxelVolumeResult?,
        alphaResult: AlphaShapeResult?,
        meshResult: MeshResult?
    ) -> VolumeComparison {
        VolumeComparison(
            voxelVolume: voxelResult?.volume,
            alphaShapeVolume: alphaResult?.volume,
            meshVolume: meshResult?.volume
        )
    }
}

// MARK: - Point Cloud Visualization

extension MeshVisualization {

    /// Visualizes the input point cloud as small spheres
    func showPointCloud(_ points: [SIMD3<Float>], color: UIColor = .white, pointSize: Float = 0.003) {
        let container = Entity()
        container.name = "point_cloud"

        let pointMesh = MeshResource.generateSphere(radius: pointSize)
        let pointMaterial = UnlitMaterial(color: color)

        // Limit points for performance
        let displayPoints = Array(points.prefix(5000))

        for point in displayPoints {
            let pointEntity = ModelEntity(mesh: pointMesh, materials: [pointMaterial])
            pointEntity.position = point
            container.addChild(pointEntity)
        }

        entity.addChild(container)
    }

    /// Removes point cloud visualization
    func hidePointCloud() {
        if let pointCloud = entity.children.first(where: { $0.name == "point_cloud" }) {
            pointCloud.removeFromParent()
        }
    }
}

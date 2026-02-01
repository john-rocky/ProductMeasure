//
//  VoxelVisualization.swift
//  ProductMeasure
//
//  3D visualization of voxel grid for volume calculation
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing voxels
class VoxelVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var voxelEntities: [ModelEntity] = []

    /// Whether the visualization is currently visible
    var isVisible: Bool = true {
        didSet {
            entity.isEnabled = isVisible
        }
    }

    // MARK: - Constants

    /// Semi-transparent green for voxel cubes
    private let voxelColor = UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.35)

    /// Slight inset to create visual gap between voxels
    private let voxelInsetFactor: Float = 0.85

    // MARK: - Initialization

    init() {
        self.entity = Entity()
        self.entity.name = "voxel_visualization"
    }

    // MARK: - Public Methods

    /// Update visualization with new voxel data
    func update(with result: VoxelVolumeResult) {
        // Clear existing voxels
        clearVoxels()

        guard !result.surfaceVoxels.isEmpty else { return }

        let voxelSize = result.voxelSize
        let displaySize = voxelSize * voxelInsetFactor

        // Create shared mesh and material for performance
        let voxelMesh = MeshResource.generateBox(size: displaySize)
        let material = UnlitMaterial(color: voxelColor)

        // Batch create voxel entities
        for voxelIndex in result.surfaceVoxels {
            // Convert voxel index to world position
            let worldPosition = voxelIndexToWorldPosition(
                index: voxelIndex,
                gridOrigin: result.gridOrigin,
                voxelSize: voxelSize
            )

            let voxelEntity = ModelEntity(mesh: voxelMesh, materials: [material])
            voxelEntity.position = worldPosition
            voxelEntity.name = "voxel_\(voxelIndex.x)_\(voxelIndex.y)_\(voxelIndex.z)"

            entity.addChild(voxelEntity)
            voxelEntities.append(voxelEntity)
        }

        print("[VoxelViz] Created \(voxelEntities.count) voxel entities")
    }

    /// Clear all voxel visualizations
    func clearVoxels() {
        for voxelEntity in voxelEntities {
            voxelEntity.removeFromParent()
        }
        voxelEntities.removeAll()
    }

    /// Animate voxels appearing (fade in)
    func animateAppear(duration: TimeInterval = 0.5) {
        // Start with scale 0
        for voxelEntity in voxelEntities {
            voxelEntity.scale = .zero
        }

        // Animate to full scale with staggered delay
        let staggerDelay: TimeInterval = 0.001
        for (index, voxelEntity) in voxelEntities.enumerated() {
            let delay = Double(index) * staggerDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                voxelEntity.scale = SIMD3<Float>(repeating: 1.0)
            }
        }
    }

    /// Set opacity of all voxels
    func setOpacity(_ opacity: Float) {
        let color = UIColor(
            red: 0.2,
            green: 0.8,
            blue: 0.4,
            alpha: CGFloat(opacity * 0.35)
        )
        let material = UnlitMaterial(color: color)

        for voxelEntity in voxelEntities {
            voxelEntity.model?.materials = [material]
        }
    }

    // MARK: - Private Methods

    /// Convert voxel index to world position (center of voxel)
    private func voxelIndexToWorldPosition(
        index: VoxelIndex,
        gridOrigin: SIMD3<Float>,
        voxelSize: Float
    ) -> SIMD3<Float> {
        // Voxel center = grid origin + (index + 0.5) * voxelSize
        return SIMD3<Float>(
            gridOrigin.x + (Float(index.x) + 0.5) * voxelSize,
            gridOrigin.y + (Float(index.y) + 0.5) * voxelSize,
            gridOrigin.z + (Float(index.z) + 0.5) * voxelSize
        )
    }
}

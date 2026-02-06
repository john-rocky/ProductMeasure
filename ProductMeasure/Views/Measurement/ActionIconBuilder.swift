//
//  ActionIconBuilder.swift
//  ProductMeasure
//

import RealityKit
import UIKit

/// Action types for 3D pill-shaped action icons
enum ActionType: String, CaseIterable {
    case save = "action_save"
    case edit = "action_edit"
    case discard = "action_discard"
    case done = "action_done"
    case fit = "action_fit"
    case cancel = "action_cancel"
    case reEdit = "action_reedit"
    case delete = "action_delete"
}

/// Configuration for a single action icon
struct ActionIconConfig {
    let type: ActionType
    let label: String
    let color: UIColor
}

/// Utility for building 3D pill-shaped action icon rows
enum ActionIconBuilder {
    // MARK: - Presets

    /// Actions for active box in normal mode: Discard, Edit, Save
    static let activeNormalActions: [ActionIconConfig] = [
        ActionIconConfig(type: .discard, label: "X", color: UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)),
        ActionIconConfig(type: .edit, label: "Ed", color: UIColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1.0)),
        ActionIconConfig(type: .save, label: "OK", color: UIColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)),
    ]

    /// Actions for active box in editing mode: Cancel, Fit, Done
    static let activeEditActions: [ActionIconConfig] = [
        ActionIconConfig(type: .cancel, label: "X", color: UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)),
        ActionIconConfig(type: .fit, label: "Fit", color: UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)),
        ActionIconConfig(type: .done, label: "OK", color: UIColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)),
    ]

    /// Actions for completed box: Re-edit, Delete
    static let completedActions: [ActionIconConfig] = [
        ActionIconConfig(type: .reEdit, label: "Ed", color: UIColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1.0)),
        ActionIconConfig(type: .delete, label: "X", color: UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)),
    ]

    // MARK: - Constants

    private static let pillWidth: Float = 0.012   // 12mm
    private static let pillHeight: Float = 0.008   // 8mm
    private static let pillDepth: Float = 0.002    // 2mm depth
    private static let pillSpacing: Float = 0.004  // 4mm between pills
    private static let fontSize: CGFloat = 0.005   // 5pt text
    private static let collisionScale: Float = 1.5 // Hit area enlargement

    // MARK: - Public Methods

    /// Create a horizontal row of action icon pills
    /// - Parameter actions: Array of action configs to display
    /// - Returns: Entity containing the row of pills
    static func createActionRow(actions: [ActionIconConfig]) -> Entity {
        let rowEntity = Entity()
        rowEntity.name = "action_row"

        let totalWidth = Float(actions.count) * pillWidth + Float(actions.count - 1) * pillSpacing
        let startX = -totalWidth / 2 + pillWidth / 2

        for (index, action) in actions.enumerated() {
            let pillEntity = createPill(config: action)
            let xPos = startX + Float(index) * (pillWidth + pillSpacing)
            pillEntity.position = SIMD3<Float>(xPos, 0, 0)
            rowEntity.addChild(pillEntity)
        }

        return rowEntity
    }

    /// Parse an entity name to determine the action type
    /// - Parameter entityName: The name of the hit entity
    /// - Returns: ActionType if the entity is an action icon
    static func parseActionType(entityName: String) -> ActionType? {
        return ActionType(rawValue: entityName)
    }

    /// Check if an entity name belongs to an action icon
    static func isActionEntity(_ name: String) -> Bool {
        return name.hasPrefix("action_")
    }

    // MARK: - Private Methods

    private static func createPill(config: ActionIconConfig) -> Entity {
        let pillParent = Entity()
        pillParent.name = config.type.rawValue

        // Pill background (colored rounded box)
        let cornerRadius = min(pillWidth, pillHeight) * 0.4
        let bgMesh = MeshResource.generateBox(
            size: [pillWidth, pillHeight, pillDepth],
            cornerRadius: cornerRadius
        )
        var bgMaterial = UnlitMaterial(color: config.color)
        bgMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMaterial])
        bgEntity.name = config.type.rawValue
        pillParent.addChild(bgEntity)

        // Text label (white, centered)
        let textMesh = MeshResource.generateText(
            config.label,
            extrusionDepth: 0.0005,
            font: .systemFont(ofSize: fontSize, weight: .bold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let textMaterial = UnlitMaterial(color: .white)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])

        // Center text on pill
        let textBounds = textMesh.bounds.extents
        textEntity.position = SIMD3<Float>(
            -textBounds.x / 2,
            -textBounds.y / 2,
            pillDepth / 2 + 0.0003
        )
        textEntity.name = config.type.rawValue
        pillParent.addChild(textEntity)

        // Collision component (enlarged hit area)
        let collisionShape = ShapeResource.generateBox(
            size: [pillWidth * collisionScale, pillHeight * collisionScale, pillDepth * 3]
        )
        pillParent.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        return pillParent
    }
}

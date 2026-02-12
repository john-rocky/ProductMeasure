//
//  LabelBillboard.swift
//  ProductMeasure
//

import RealityKit
import UIKit
import simd

/// AR billboard that displays parsed label data floating above the real label in 3D space.
/// Styled with neon blue (0x00BFFF) cyberpunk aesthetic, modeled after BoxVisualization billboard.
class LabelBillboard {

    private(set) var entity: Entity

    // Text line entities for staggered reveal animation
    private var revealEntities: [Entity] = []

    // Action icon row
    private var actionIconRow: Entity?

    // Colors (neon blue theme)
    private let accentColor = UIColor(hex: 0x00BFFF)
    private let bgColor = PMTheme.uiBillboardBg
    private let textColor = PMTheme.uiBillboardText
    private let borderColor = UIColor(hex: 0x00BFFF).withAlphaComponent(0.40)

    // Font sizes
    private let headerFontSize: CGFloat = 0.012
    private let primaryFontSize: CGFloat = 0.012
    private let bodyFontSize: CGFloat = 0.010
    private let sectionFontSize: CGFloat = 0.007

    init(labelData: LabelData, worldPosition: SIMD3<Float>, surfaceNormal: SIMD3<Float>) {
        self.entity = Entity()
        entity.position = worldPosition
        buildBillboard(labelData: labelData)
    }

    // MARK: - Build

    private func buildBillboard(labelData: LabelData) {
        let containerEntity = Entity()
        containerEntity.name = "label_billboard_container"

        // Layout constants
        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let labelValueGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        // Cyber colors (neon blue)
        let labelColor = accentColor.withAlphaComponent(0.55)
        let valueColor = textColor
        let sectionTextColor = accentColor.withAlphaComponent(0.70)
        let separatorColor = accentColor.withAlphaComponent(0.25)

        // -- Text mesh helper --
        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        // -- Build section data --
        struct DataLine { let label: String; let value: String }
        struct Section { let title: String; let lines: [DataLine] }

        let primaryFields = labelData.primaryDisplayFields
        let secondaryFields = labelData.secondaryDisplayFields

        var sections: [Section] = []
        if !primaryFields.isEmpty {
            sections.append(Section(title: "PRIMARY", lines: primaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }
        if !secondaryFields.isEmpty {
            sections.append(Section(title: "DETAILS", lines: secondaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }

        // Fallback if no structured fields
        if sections.isEmpty {
            let rawLines = labelData.rawText.components(separatedBy: "\n").prefix(6)
            sections.append(Section(title: "RAW TEXT", lines: rawLines.enumerated().map {
                DataLine(label: "L\($0.offset + 1)", value: String($0.element.prefix(24)))
            }))
        }

        // -- Pre-generate all text entities --
        let headerResult = textMesh("LABEL", size: headerFontSize, weight: .bold, color: accentColor)

        var sectionHeaders: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        var sectionLines: [[(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))]] = []
        var maxLabelWidth: Float = 0
        var maxContentWidth: Float = headerResult.size.x

        for section in sections {
            let header = textMesh(section.title, size: sectionFontSize, weight: .bold, color: sectionTextColor)
            sectionHeaders.append(header)
            maxContentWidth = max(maxContentWidth, header.size.x)

            let fontSize = section.title == "PRIMARY" ? primaryFontSize : bodyFontSize
            var lines: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
            for dl in section.lines {
                let l = textMesh(dl.label, size: fontSize, weight: .semibold, color: labelColor)
                let v = textMesh(dl.value, size: fontSize, weight: .medium, color: valueColor)
                maxLabelWidth = max(maxLabelWidth, l.size.x)
                lines.append((l, v))
            }
            sectionLines.append(lines)
        }

        // Recalculate max width with label+gap+value
        for sl in sectionLines {
            for pair in sl {
                maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
            }
        }

        // -- Calculate total content height --
        var totalContentHeight: Float = headerResult.size.y
        for (si, sl) in sectionLines.enumerated() {
            totalContentHeight += sectionTopGap
            totalContentHeight += separatorThick + separatorMargin
            totalContentHeight += sectionHeaders[si].size.y
            for pair in sl {
                totalContentHeight += lineGap
                totalContentHeight += max(pair.label.size.y, pair.value.size.y)
            }
        }

        // -- Layout dimensions --
        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        // -- Structural entities --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding
        let valueLeftX = textLeftX + maxLabelWidth + labelValueGap

        // Outer glow
        let glowPad: Float = 0.003
        let glowMesh = MeshResource.generateBox(
            size: [totalWidth + glowPad * 2, totalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var glowMat = UnlitMaterial(color: accentColor.withAlphaComponent(0.06))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let glowEntity = ModelEntity(mesh: glowMesh, materials: [glowMat])
        glowEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.002)

        // Dark glass background
        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: bgColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMat])
        bgEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)

        // Accent bar + glow
        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: accentColor)])
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)

        let accentGlowW: Float = 0.006
        let agMesh = MeshResource.generateBox(size: [accentGlowW, accentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var agMat = UnlitMaterial(color: accentColor.withAlphaComponent(0.10))
        agMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let accentGlowEntity = ModelEntity(mesh: agMesh, materials: [agMat])
        accentGlowEntity.position = SIMD3<Float>(accentX, totalHeight / 2, -0.0005)

        // Top + bottom borders
        let borderW = totalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [borderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: borderColor)
            mat.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return ModelEntity(mesh: mesh, materials: [mat])
        }
        let topBorder = makeBorder(opacity: 0.50)
        topBorder.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        let bottomBorder = makeBorder(opacity: 0.30)
        bottomBorder.position = SIMD3<Float>(0, 0.0003, 0.0005)

        // Add structural entities
        containerEntity.addChild(glowEntity)
        containerEntity.addChild(bgEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(accentGlowEntity)
        containerEntity.addChild(topBorder)
        containerEntity.addChild(bottomBorder)

        // -- Position text top-to-bottom --
        var cursor = padding + totalContentHeight

        // Header: "LABEL"
        cursor -= headerResult.size.y
        headerResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(headerResult.entity)

        // Sections
        for (si, sl) in sectionLines.enumerated() {
            cursor -= sectionTopGap

            // Separator line
            let sepW = maxContentWidth
            let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
            var sepMat = UnlitMaterial(color: separatorColor)
            sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
            sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
            containerEntity.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            // Section header
            cursor -= sectionHeaders[si].size.y
            sectionHeaders[si].entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(sectionHeaders[si].entity)

            // Data lines
            for pair in sl {
                cursor -= lineGap
                let h = max(pair.label.size.y, pair.value.size.y)
                cursor -= h

                // Wrap each line in a container for staggered reveal
                let lineContainer = Entity()
                pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
                lineContainer.addChild(pair.label.entity)
                lineContainer.addChild(pair.value.entity)
                lineContainer.scale = .zero  // Hidden initially for reveal
                containerEntity.addChild(lineContainer)
                revealEntities.append(lineContainer)
            }
        }

        // Action icon row below billboard
        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.labelBillboardActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        containerEntity.addChild(row)
        actionIconRow = row

        entity.addChild(containerEntity)

        // Start hidden (scale zero) for reveal animation
        containerEntity.scale = .zero
    }

    // MARK: - Orientation

    /// Rotate billboard to face camera (Y-axis only), same as BoxVisualization
    func updateOrientation(cameraPosition: SIMD3<Float>) {
        let billboardPos = entity.position(relativeTo: nil)
        let toCamera = cameraPosition - billboardPos
        let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

        if simd_length(toCameraHorizontal) > 0.01 {
            let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
            entity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    // MARK: - Reveal Animation

    /// Staggered reveal: billboard grows in, then text lines appear one by one
    func startRevealAnimation(completion: @escaping () -> Void) {
        guard let container = entity.children.first else {
            completion()
            return
        }

        // Phase 1: Grow billboard container from zero to full scale (0.3s)
        let growDuration: Double = 0.3
        let growStart = Date()

        let growTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(growStart)
            let t = Float(min(elapsed / growDuration, 1.0))
            let eased = 1.0 - pow(1.0 - t, 3)  // easeOutCubic
            container.scale = SIMD3<Float>(repeating: eased)

            if t >= 1.0 {
                timer.invalidate()
                container.scale = .one

                // Phase 2: Staggered text line reveal
                self.revealTextLines(completion: completion)
            }
        }
        RunLoop.main.add(growTimer, forMode: .common)
    }

    private func revealTextLines(completion: @escaping () -> Void) {
        let stagger = PMTheme.labelBillboardRevealStagger
        let lineDuration: Double = 0.15

        for (index, lineEntity) in revealEntities.enumerated() {
            let delay = Double(index) * stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let startTime = Date()
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
                    let elapsed = Date().timeIntervalSince(startTime)
                    let t = Float(min(elapsed / lineDuration, 1.0))
                    let eased = 1.0 - pow(1.0 - t, 3)
                    lineEntity.scale = SIMD3<Float>(repeating: eased)

                    if t >= 1.0 {
                        timer.invalidate()
                        lineEntity.scale = .one
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        // Call completion after all lines have revealed
        let totalDelay = Double(revealEntities.count) * stagger + lineDuration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
            completion()
        }
    }

    // MARK: - Dismiss

    /// Shrink billboard to zero and call completion
    func dismiss(completion: @escaping () -> Void) {
        let duration: Double = 0.3
        let startTime = Date()
        let startScale = entity.scale

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))
            let eased = 1.0 - pow(1.0 - t, 3)

            self.entity.scale = startScale * (1.0 - eased)

            if t >= 1.0 {
                timer.invalidate()
                self.entity.isEnabled = false
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Visibility

    func setVisible(_ visible: Bool) {
        entity.isEnabled = visible
    }
}

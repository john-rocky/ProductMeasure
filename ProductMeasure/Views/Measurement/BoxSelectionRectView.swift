//
//  BoxSelectionRectView.swift
//  ProductMeasure
//

import UIKit

/// UIKit view that draws box selection visuals (dim overlay, selection rect, status label).
/// Has `isUserInteractionEnabled = false` so it never captures touches.
class BoxSelectionRectView: UIView {

    /// The current selection rectangle in the parent view's coordinate space.
    var selectionRect: CGRect? {
        didSet { setNeedsDisplay() }
    }

    /// Whether the current rectangle meets the minimum size requirement.
    var isRectValid: Bool = false {
        didSet { updateStatusLabel() }
    }

    // Minimum selection size (points)
    static let minimumSize: CGFloat = 50

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.isHidden = true
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        addSubview(statusLabel)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let selRect = selectionRect else {
            return
        }

        // Dim overlay (black 0.3) with cutout for selection
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)
        ctx.clear(selRect)

        // Selection rectangle fill
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
        ctx.fill(selRect)

        // Selection rectangle border
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(selRect)

        // Position status label below the rect
        statusLabel.sizeToFit()
        let labelWidth = statusLabel.intrinsicContentSize.width + 16
        let labelHeight: CGFloat = 24
        statusLabel.frame = CGRect(
            x: selRect.midX - labelWidth / 2,
            y: selRect.maxY + 8,
            width: labelWidth,
            height: labelHeight
        )
        statusLabel.isHidden = false
    }

    private func updateStatusLabel() {
        if isRectValid {
            statusLabel.text = "Release to select"
            statusLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        } else {
            statusLabel.text = "Make it bigger"
            statusLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)
        }
    }

    /// Clear the selection visuals.
    func clearSelection() {
        selectionRect = nil
        isRectValid = false
        statusLabel.isHidden = true
        setNeedsDisplay()
    }
}

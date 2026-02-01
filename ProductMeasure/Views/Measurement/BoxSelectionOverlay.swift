//
//  BoxSelectionOverlay.swift
//  ProductMeasure
//

import SwiftUI

struct BoxSelectionOverlay: View {
    @Binding var selectionRect: CGRect?
    @Binding var isComplete: Bool

    @State private var dragStart: CGPoint?
    @State private var currentRect: CGRect?

    // Minimum size for valid selection (in points)
    private let minimumSize: CGFloat = 50

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }

                        if let start = dragStart {
                            let rect = CGRect(
                                x: min(start.x, value.location.x),
                                y: min(start.y, value.location.y),
                                width: abs(value.location.x - start.x),
                                height: abs(value.location.y - start.y)
                            )
                            currentRect = rect
                        }
                    }
                    .onEnded { _ in
                        if let rect = currentRect,
                           rect.width >= minimumSize && rect.height >= minimumSize {
                            selectionRect = rect
                            isComplete = true
                        }

                        // Reset state
                        dragStart = nil
                        currentRect = nil
                    }
            )
            .overlay {
                // Semi-transparent background when dragging
                if currentRect != nil {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Selection rectangle
                if let rect = currentRect {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .overlay(
                            Rectangle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)

                    // Size indicator
                    if rect.width >= minimumSize && rect.height >= minimumSize {
                        Text("Release to select")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.8))
                            .clipShape(Capsule())
                            .position(x: rect.midX, y: rect.maxY + 20)
                            .allowsHitTesting(false)
                    } else {
                        Text("Make it bigger")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.8))
                            .clipShape(Capsule())
                            .position(x: rect.midX, y: rect.maxY + 20)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    /// Reset the selection state
    func reset() {
        selectionRect = nil
        isComplete = false
        dragStart = nil
        currentRect = nil
    }
}

#Preview {
    BoxSelectionOverlay(
        selectionRect: .constant(nil),
        isComplete: .constant(false)
    )
    .background(Color.gray)
}

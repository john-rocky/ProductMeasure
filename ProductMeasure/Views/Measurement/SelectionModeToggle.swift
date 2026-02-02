//
//  SelectionModeToggle.swift
//  ProductMeasure
//

import SwiftUI

struct SelectionModeToggle: View {
    @Binding var selectionMode: SelectionMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SelectionMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectionMode = mode
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(mode.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(selectionMode == mode ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        selectionMode == mode
                            ? Color.blue.opacity(0.8)
                            : Color.clear
                    )
                    .clipShape(Capsule())
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        Color.gray
        SelectionModeToggle(selectionMode: .constant(.tap))
    }
}

// File: Packages/UI/Sources/UI/LiquidGlassTabBar.swift

import SwiftUI
import Core

struct LiquidGlassTabBar: View {
    @Binding var selectedCapability: ModelCapability
    let onCapabilityChange: (ModelCapability) -> Void

    var body: some View {
        HStack(spacing: 16) {
            ForEach(ModelCapability.allCases, id: \.self) { capability in
                Button {
                    if selectedCapability != capability {
                        onCapabilityChange(capability)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: capability.symbolName)
                            .font(.footnote)
                        Text(capability.displayName)
                            .font(.caption2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 50, minHeight: 32)
                    .background(
                        selectedCapability == capability ?
                        Color.accentColor.opacity(0.2) :
                        Color.clear
                    )
                    .cornerRadius(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedCapability == capability ? .accentColor : .primary)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
    }
}

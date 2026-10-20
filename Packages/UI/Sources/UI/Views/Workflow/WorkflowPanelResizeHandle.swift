import SwiftUI

/// Only the overlay's width changes. The canvas viewport and camera never use
/// this value, including while both sidebars overlap in a narrow window.
struct WorkflowPanelResizeHandle: View {
    @Binding var width: CGFloat
    let leading: Bool
    @State private var initialWidth: CGFloat?
    @Environment(\.dLanguageStore) private var language

    var body: some View {
        Capsule().fill(.secondary.opacity(0.25)).frame(width: 3, height: 38)
            .frame(width: 10).frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = width }
                    width = min(560, max(260, (initialWidth ?? width)
                        + value.translation.width * (leading ? 1 : -1)))
                }
                .onEnded { _ in initialWidth = nil })
            .accessibilityElement()
            .accessibilityLabel(workspaceText(language, "resizeSidebar", "调整边栏宽度", "Resize sidebar"))
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(560, width + 20)
                case .decrement: width = max(260, width - 20)
                @unknown default: break
                }
            }
    }
}

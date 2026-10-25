import SwiftUI

enum ChatComposerIdentity: Equatable {
    case empty, current(UUID), stale
    static func resolve(captured: UUID, empty: UUID, created: UUID?, selected: UUID?) -> Self {
        if captured == empty {
            if let created, selected == created { return .current(created) }
            return selected == nil ? .empty : .stale
        }
        return selected == captured ? .current(captured) : .stale
    }
}

struct ChatMessageAcceptance: Equatable {
    let owner: ObjectIdentifier
    let session: UUID?
    let loaded: Bool
    let visible: Bool
    let count: Int
    func acceptsArrival(after old: Self) -> Bool {
        owner == old.owner && session != nil && session == old.session && loaded && old.loaded && visible && old.visible && count > old.count
    }
}

/// The row occupies the reading track; only its content-sized child paints glass.
/// A finite proposal keeps code and tables within this message's own bounds.
struct ChatBubbleLayout: Layout {
    var user: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let track = proposal.width ?? 600
        let natural = child.sizeThatFits(.unspecified).width
        let width = min(track * (user ? 0.75 : 0.85), max(80, natural.isFinite ? natural : track))
        return .init(width: track, height: child.sizeThatFits(.init(width: width, height: nil)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let natural = child.sizeThatFits(.unspecified).width
        let width = min(bounds.width * (user ? 0.75 : 0.85), max(80, natural.isFinite ? natural : bounds.width))
        child.place(at: .init(x: user ? bounds.maxX - width : bounds.minX, y: bounds.minY),
                    proposal: .init(width: width, height: nil))
    }
}

/// Once for newly accepted IDs. Streaming bytes, old history and tab restoration
/// do not affect this key, and the existing reading markers keep their identity.
struct ChatMessageEntrance: ViewModifier {
    let accepted: Bool
    @State private var entered = false
    @State private var progress: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatDisplayPreferences) private var preferences
    func body(content: Content) -> some View {
        content.opacity(progress).offset(y: reduceMotion ? 0 : 8 * (1 - progress))
            .animation(reduceMotion || preferences.resolvedAppearance.lightweight || preferences.resolvedAppearance.motion == 0 ? nil : .easeOut(duration: 0.2), value: progress)
            .task(id: accepted) {
                guard accepted, !entered else { return }; entered = true
                guard !reduceMotion, !preferences.resolvedAppearance.lightweight, preferences.resolvedAppearance.motion > 0 else { return }
                var preparation = Transaction(animation: nil); preparation.disablesAnimations = true
                withTransaction(preparation) { progress = 0 }
                await Task.yield()
                guard !Task.isCancelled else { progress = 1; return }
                withAnimation(.easeOut(duration: 0.2)) { progress = 1 }
            }
    }
}

/// Hover controls are an overlay, so even an invisible toolbar cannot widen a
/// short message. The always-visible Actions menu retains every keyboard action.
struct ChatMessageChrome<Content: View, Actions: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var hovered = false
    @FocusState private var actionFocused: Bool
    var body: some View {
        content(hovered || actionFocused)
            .overlay(alignment: .topTrailing) {
                actions().frame(maxWidth: .infinity, alignment: .trailing).frame(height: 24)
                    .focusSection().focused($actionFocused)
                    .opacity(hovered || actionFocused ? 1 : 0)
                    .allowsHitTesting(hovered || actionFocused)
                    .padding(.horizontal, 14).padding(.top, 12)
            }
            .onHover { hovered = $0 }
    }
}

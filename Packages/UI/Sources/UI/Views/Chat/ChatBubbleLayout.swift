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

/// Measures the body separately: action width can never enlarge its glass.
struct ChatMessageStack: Layout {
    let user: Bool
    struct Geometry: Equatable {
        let bubble: CGSize
        let tools: CGSize
        let foot: CGSize
        var size: CGSize { .init(width: max(bubble.width, tools.width, foot.width), height: bubble.height + 6 + 28 + (foot.height > 0 ? 4 + foot.height : 0)) }
        func x(_ width: CGFloat) -> CGFloat { userAlignment ? size.width - width : 0 }
        var userAlignment = false
    }
    func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Geometry {
        guard subviews.count == 3 else { return .init(bubble: .zero, tools: .zero, foot: .zero) }
        let limit = proposal.width ?? 600
        let natural = subviews[0].sizeThatFits(.unspecified)
        let width = min(limit, max(1, natural.width.isFinite ? natural.width : limit))
        return .init(bubble: subviews[0].sizeThatFits(.init(width: width, height: nil)),
            tools: subviews[1].sizeThatFits(.init(width: limit, height: 28)),
            foot: subviews[2].sizeThatFits(.init(width: limit, height: nil)), userAlignment: user)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { measure(proposal, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = measure(proposal, subviews)
        guard subviews.count == 3 else { return }
        for (i, size, y) in [(0, g.bubble, CGFloat(0)), (1, g.tools, g.bubble.height + 6), (2, g.foot, g.bubble.height + 38)] {
            subviews[i].place(at: .init(x: bounds.minX + g.x(size.width), y: bounds.minY + y), proposal: .init(width: size.width, height: size.height))
        }
    }
}

struct ChatMessageIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMessageIconBody(configuration: configuration)
    }
    private struct ChatMessageIconBody: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.contentShape(Rectangle())
                .background(.primary.opacity(configuration.isPressed ? 0.12 : hovered && enabled ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

private struct ChatMessageToolOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var chatMessageToolOpacity: Double {
        get { self[ChatMessageToolOpacityKey.self] }
        set { self[ChatMessageToolOpacityKey.self] = newValue }
    }
}

/// A bounded hover region includes body, the six-point bridge and the permanently
/// allocated tool slot. No timers, reading-track-wide hit region or hidden editor.
struct ChatMessageChrome<Content: View, Actions: View, Footer: View>: View {
    let user: Bool
    let latestAnswer: Bool
    @ViewBuilder let content: (Binding<Bool>) -> Content
    @ViewBuilder let actions: (Binding<Bool>, Binding<Bool>) -> Actions
    @ViewBuilder let footer: () -> Footer
    @State private var hovered = false
    @State private var actionFocused = false
    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatDisplayPreferences) private var preferences
    private var active: Bool { hovered || actionFocused || menuOpen }
    var body: some View {
        ChatMessageStack(user: user) {
            content($menuOpen)
            actions($actionFocused, $menuOpen)
                .environment(\.chatMessageToolOpacity, active ? 1 : latestAnswer ? 0.5 : 0)
            VStack(alignment: user ? .trailing : .leading, spacing: 0) { footer() }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion || preferences.resolvedAppearance.lightweight || preferences.resolvedAppearance.motion == 0 ? nil : .easeOut(duration: 0.12), value: active)
    }
}

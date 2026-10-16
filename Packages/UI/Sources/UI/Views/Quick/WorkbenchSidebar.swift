import SwiftUI

/// Visibility belongs to the workbench, not a particular modality or document.
@MainActor @Observable final class WorkbenchSidebarState {
    var leading = true
    var trailing = false
    init(leading: Bool = true, trailing: Bool = false) { self.leading = leading; self.trailing = trailing }
}

private struct WorkbenchSidebarsKey: EnvironmentKey {
    static let defaultValue: WorkbenchSidebarState? = nil
}

extension EnvironmentValues {
    var workbenchSidebars: WorkbenchSidebarState? {
        get { self[WorkbenchSidebarsKey.self] }
        set { self[WorkbenchSidebarsKey.self] = newValue }
    }
}

enum WorkbenchSidebarLayout {
    static let leadingWidth: CGFloat = 288
    static let trailingWidth: CGFloat = 320
    static let buttonDiameter: CGFloat = 40
    static let buttonInset: CGFloat = 8
    static let gap: CGFloat = 12
    // Two panes, two gaps, outer insets and at least 468pt for the working area.
    static let minimumWindowWidth: CGFloat = 1080
    static func widths(available: CGFloat) -> WorkbenchPanelWidths {
        available < 1180 ? .init(leading: 256, trailing: 272) : .init(leading: 288, trailing: 320)
    }
    static func visible(available: CGFloat, leading: Bool, trailing: Bool, preferTrailing: Bool = false) -> (leading: Bool, trailing: Bool) {
        guard available < minimumWindowWidth else { return (leading, trailing) }
        let widths = widths(available: available)
        let budget = available - 32 - 2 * gap - 360
        let first = preferTrailing ? widths.trailing : widths.leading
        let firstRequested = preferTrailing ? trailing : leading
        let firstShown = firstRequested && budget >= first + 48
        let second = preferTrailing ? widths.leading : widths.trailing
        let secondRequested = preferTrailing ? leading : trailing
        let secondShown = secondRequested && budget >= (firstShown ? first : 48) + second
        return preferTrailing ? (secondShown, firstShown) : (firstShown, secondShown)
    }
    static func occupiedWidth(_ expanded: Bool, leading: Bool, available: CGFloat = 1280) -> CGFloat {
        let widths = widths(available: available)
        return (expanded ? (leading ? widths.leading : widths.trailing) : buttonDiameter + buttonInset) + gap
    }
}

struct WorkbenchPanelWidths: Equatable {
    var leading: CGFloat = 288
    var trailing: CGFloat = 320
}
private struct WorkbenchPanelWidthsKey: EnvironmentKey { static let defaultValue = WorkbenchPanelWidths() }
extension EnvironmentValues {
    var workbenchPanelWidths: WorkbenchPanelWidths {
        get { self[WorkbenchPanelWidthsKey.self] }
        set { self[WorkbenchPanelWidthsKey.self] = newValue }
    }
}

/// A fixed tool strip, not a second row of glass plates. Selection never owns
/// drafts, results, controller commands or the canvas run target.
struct WorkbenchSidebarTabs<Tab: Hashable>: View {
    let title: String
    @Binding var selection: Tab
    let choices: [(Tab, String)]
    var helpPrefix: String? = nil
    @FocusState private var focused: Tab?
    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.0) { item in
                Button { selection = item.0 } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(item.1, systemImage: Self.symbol(item.0)).fixedSize()
                        Image(systemName: Self.symbol(item.0))
                    }.font(.system(size: 12, weight: selection == item.0 ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .overlay(alignment: .bottom) {
                            if selection == item.0 { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                }.buttonStyle(.plain).focused($focused, equals: item.0)
                    .workbenchHelp(featureID(item.0)).accessibilityLabel(item.1)
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                    .onKeyPress(.leftArrow) { move(-1); return .handled }
                    .onKeyPress(.rightArrow) { move(1); return .handled }
            }
        }.frame(height: 36).workbenchPanel(cornerRadius: 0).workbenchSurface(.scrollEdge).accessibilityElement(children: .contain).accessibilityLabel(title).workbenchHelp(helpPrefix?.contains("RIGHT") == true ? "BAR-RIGHT" : "BAR-LEFT")
    }
    private func featureID(_ value: Tab) -> String {
        let name = String(describing: value)
        let suffix = ["configuration": "PROPERTIES", "node": "NODE", "conversations": "CHATS", "artifacts": "RESULTS" ][name] ?? name.uppercased()
        return helpPrefix.map { $0 + suffix } ?? "BAR-LEFT"
    }
    private static func symbol(_ value: Tab) -> String {
        switch String(describing: value) {
        case "settings", "configuration": "slider.horizontal.3"
        case "assets": "photo.on.rectangle"
        case "conversations": "bubble.left.and.bubble.right"
        case "tools": "wrench.and.screwdriver"
        case "nodes": "square.3.layers.3d"
        case "history": "clock"
        case "sources": "text.book.closed"
        case "overview": "list.bullet.rectangle"
        default: "doc.richtext"
        }
    }
    private func move(_ delta: Int) {
        guard let index = choices.firstIndex(where: { $0.0 == (focused ?? selection) }), !choices.isEmpty else { return }
        let next = choices[(index + delta + choices.count) % choices.count].0
        selection = next; focused = next
    }
}

/// Mount only visited pages; retain their native editor and reading identity.
struct WorkbenchSidebarPages<Tab: Hashable, Content: View>: View {
    let selection: Tab
    let choices: [Tab]
    let identifier: String
    @ViewBuilder var content: (Tab) -> Content
    @State private var visited: Set<Tab> = []
    @Environment(\.dLanguageStore) private var language
    @Environment(\.chatDisplayPreferences) private var preferences
    var body: some View {
        ZStack {
            ForEach(choices.filter { visited.contains($0) || selection == $0 }, id: \.self) { tab in
                RetainedContentHost(content: content(tab)
                    .environment(\.dLanguageStore, language)
                    .environment(\.chatDisplayPreferences, preferences).disabled(selection != tab),
                    visible: selection == tab, identifier: identifier + "-" + String(describing: tab))
                    .allowsHitTesting(selection == tab).accessibilityHidden(selection != tab)
            }
        }.onAppear { visited.insert(selection) }.onChange(of: selection) { _, value in visited.insert(value) }
    }
}

/// One stable outer button. Only the plate changes geometry; native content is
/// retained at full size and stops receiving input immediately on collapse.
struct WorkbenchSidebar<Content: View>: View {
    let leading: Bool
    let expanded: Bool
    let title: String
    let identifier: String
    let hostIdentifier: String
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var surfaceGroup = UUID().uuidString
    @State private var revealed: Bool
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.dLanguageStore) private var language
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.workbenchPanelWidths) private var widths
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revealDuration: Double? {
        WorkbenchEffectsPolicy(appearance: preferences.resolvedAppearance, reduceMotion: reduceMotion,
            reduceTransparency: false, increasedContrast: false).morphDuration
    }

    init(leading: Bool, expanded: Bool, title: String, identifier: String, hostIdentifier: String,
         toggle: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.leading = leading; self.expanded = expanded; self.title = title
        self.identifier = identifier; self.hostIdentifier = hostIdentifier
        self.toggle = toggle; self.content = content
        _revealed = State(initialValue: expanded)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = leading ? widths.leading : widths.trailing
            let alignment: Alignment = leading ? .topLeading : .topTrailing
            let visible = expanded && revealed
            let palette = preferences.resolvedAppearance.palette(for: scheme)
            ZStack(alignment: alignment) {
                WorkbenchSidebarPlate(progress: expanded ? 1 : 0, expandedWidth: width,
                    expandedHeight: geometry.size.height, leading: leading)
                    .workbenchMorph(value: expanded)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Text(title).font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
                        .padding(.leading, leading ? 60 : 12)
                        .padding(.trailing, leading ? 12 : 60)
                        .frame(height: 52)
                        .opacity(visible ? 1 : 0)
                        .transaction { $0.animation = nil }
                        .accessibilityHidden(!visible)
                    RetainedContentHost(content: content()
                        .foregroundStyle(palette.foregroundColor, palette.secondaryColor)
                        .tint(palette.accentColor)
                        .environment(\.chatDisplayPreferences, preferences)
                        .preferredColorScheme(preferences.preferredColorScheme)
                        .environment(\.dLanguageStore, language)
                        .disabled(!visible || !isEnabled), visible: visible && isEnabled, identifier: hostIdentifier)
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(visible && isEnabled)
                        .accessibilityHidden(!visible || !isEnabled)
                }
                .frame(width: width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(visible && isEnabled)

                Button(action: toggle) {
                    Image(systemName: leading ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 17, weight: .medium))
                }
                .buttonStyle(WorkbenchIconButtonStyle(diameter: 40, panel: true))
                .padding(.top, WorkbenchSidebarLayout.buttonInset)
                .padding(leading ? .leading : .trailing, WorkbenchSidebarLayout.buttonInset)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityValue(workflowText(language, expanded ? "sidebar.expanded" : "sidebar.collapsed",
                    fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true
                        ? (expanded ? "已展开" : "已收起") : (expanded ? "Expanded" : "Collapsed")))
                .accessibilityIdentifier(identifier).workbenchHelp(leading ? "LEFT-TOGGLE" : "RIGHT-TOGGLE")

            }
            .frame(width: width, height: geometry.size.height, alignment: alignment)
        }
        .frame(width: leading ? widths.leading : widths.trailing)
        .onChange(of: expanded) { _, open in if !open { revealed = false } }
        .environment(\.workbenchSurfaceGroup, "sidebar:" + surfaceGroup)
        .task(id: "\(identifier):\(expanded):\(isEnabled):\(revealDuration ?? 0)") {
            guard expanded && isEnabled else { revealed = false; return }
            guard !revealed else { return }
            if let revealDuration {
                // Same clock as the finite plate transition; no second fade or
                // settling delay. Task identity cancels stale reveal completions.
                do { try await Task.sleep(for: .seconds(revealDuration)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            revealed = true
        }
    }
}

/// Only the decorative plate interpolates. Clamp evaluated geometry, not the
/// endpoint values: a closing rebound in a tall window must never go negative.
struct WorkbenchSidebarPlate: View, Animatable {
    nonisolated var progress: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let leading: Bool
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    static func size(progress: CGFloat, width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: max(34, min(width + 12, 40 + (width - 40) * progress)),
               height: max(34, min(height + 6, 40 + (height - 40) * progress)))
    }
    static func origin(progress: CGFloat, size: CGSize, leading: Bool) -> CGPoint {
        let inset = WorkbenchSidebarLayout.buttonInset * (1 - min(1, max(0, progress)))
        return CGPoint(x: (inset + max(0, (40 - size.width) / 2)) * (leading ? 1 : -1),
                       y: inset + max(0, (40 - size.height) / 2))
    }
    var body: some View {
        let size = Self.size(progress: progress, width: expandedWidth, height: expandedHeight)
        Color.clear.frame(width: size.width, height: size.height)
            .workbenchGlassPlate(in: RoundedRectangle(cornerRadius: min(22, min(size.width, size.height) / 2), style: .continuous))
            // The expanded plate surrounds the fixed circular button. At rest
            // the collapsed plate is fully absorbed, including its extra shadow.
            .offset(x: Self.origin(progress: progress, size: size, leading: leading).x,
                    y: Self.origin(progress: progress, size: size, leading: leading).y)
            .opacity(min(1, max(0, progress * 6)))
    }
}

/// The shader receives only this app-owned label layer. It cannot sample the
/// window server, another view or the desktop. Real buttons remain above it.
struct WorkbenchCategoryLensTrack: View, Animatable {
    nonisolated var selection: CGFloat
    let titles: [String]
    nonisolated var engagement: CGFloat = 0
    var hovered: Int? = nil
    var pressed: Int? = nil
    var dragReceiver: WorkbenchCategoryDragReceiver? = nil
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(selection, engagement) }
        set { selection = newValue.first; engagement = newValue.second }
    }
    var body: some View {
        let decorated = !preferences.resolvedAppearance.lightweight && !reduceTransparency && contrast != .increased
        let lift = preferences.resolvedAppearance.lightweight || reduceMotion || preferences.resolvedAppearance.motion == 0
            ? 0 : min(1, max(0, engagement))
        let width = WorkbenchCategoryDragView.itemWidth * (1 + 0.06 * lift)
        let height = 36 * (1 + 0.08 * lift)
        // Keep the lifted lens inside the bar's existing 4pt breathing room.
        let x = min(256 - width + 3, max(-3, selection * WorkbenchCategoryDragView.stride
            - (width - WorkbenchCategoryDragView.itemWidth) / 2))
        let y = (36 - height) / 2
        let ink = preferences.resolvedAppearance.palette(for: scheme).foregroundColor
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                WorkbenchCategoryInk(title: titles[index], hovered: hovered == index, pressed: pressed == index)
                    .frame(maxWidth: .infinity).frame(height: 36)
            }
        }
        .frame(width: 256, height: 36)
        .modifier(WorkbenchCategoryRefraction(origin: x, enabled: decorated,
            verticalOrigin: y, size: CGSize(width: width, height: height)))
        .overlay(alignment: .topLeading) {
            Capsule()
                .strokeBorder(ink.opacity(decorated ? 0.22 : 1), lineWidth: decorated ? 0.6 : 1.5)
                .frame(width: width, height: height).offset(x: x, y: y)
        }
        .frame(width: 256, height: 36)
        .allowsHitTesting(false).accessibilityHidden(true)
        .overlay {
            if var receiver = dragReceiver {
                // The native hit region follows this exact interpolated optical
                // geometry, including a quick re-grab while the lens is settling.
                let _ = receiver.presentation = CGRect(x: x + 4, y: y + 4, width: width, height: height)
                let _ = receiver.presentationSelection = selection
                receiver.frame(width: 264, height: 44)
            }
        }
    }
}

/// Optical sampling is limited to the 256x36 category artwork, never a whole
/// page snapshot. Alpha stays transparent between glyphs; the real bar below
/// supplies its own color. Accessibility uses the same labels and a solid rim.
struct WorkbenchCategoryRefraction: ViewModifier {
    let origin: CGFloat
    let enabled: Bool
    var verticalOrigin: CGFloat = 0
    var size = CGSize(width: 62.5, height: 36)
    func body(content: Content) -> some View {
        content.layerEffect(ShaderLibrary.bundle(.module).workbenchCategoryRefraction(
            .float2(origin, verticalOrigin), .float2(size.width, size.height)),
            maxSampleOffset: CGSize(width: 8, height: 5), isEnabled: enabled)
    }
}

private struct WorkbenchCategoryInk: View {
    let title: String
    let hovered: Bool
    let pressed: Bool
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        let palette = preferences.resolvedAppearance.palette(for: scheme)
        Text(title).font(.body)
            .foregroundStyle(isEnabled && (hovered || pressed) ? palette.accentColor : palette.foregroundColor)
            .opacity(isEnabled && pressed ? 0.65 : 1)
            .workbenchMotion(value: hovered).workbenchMotion(value: pressed)
    }
}

// Optional geometry observation used by the real-host regression. No observer is
// installed in the application and no view/controller identity depends on it.
private struct WorkbenchLayoutObservationKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String, CGSize) -> Void)? = nil
}
extension EnvironmentValues {
    var workbenchLayoutObservation: (@MainActor @Sendable (String, CGSize) -> Void)? {
        get { self[WorkbenchLayoutObservationKey.self] }
        set { self[WorkbenchLayoutObservationKey.self] = newValue }
    }
}
private struct WorkbenchMeasureLayout: ViewModifier {
    let id: String
    @Environment(\.workbenchLayoutObservation) private var observe
    @ViewBuilder func body(content: Content) -> some View {
        if let observe { content.onGeometryChange(for: CGSize.self) { $0.size } action: { observe(id, $0) } }
        else { content }
    }
}
extension View {
    func workbenchMeasureLayout(_ id: String) -> some View { modifier(WorkbenchMeasureLayout(id: id)) }
}

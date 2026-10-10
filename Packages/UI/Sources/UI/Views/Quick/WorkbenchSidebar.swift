import SwiftUI

/// Visibility belongs to the workbench, not a particular modality or document.
@MainActor @Observable final class WorkbenchSidebarState {
    var leading = true
    var trailing = false
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
    static let leadingWidth: CGFloat = 260
    static let trailingWidth: CGFloat = 288
    static let buttonDiameter: CGFloat = 40
    static let buttonInset: CGFloat = 8
    static let gap: CGFloat = 16
    // Two panes, two gaps, outer insets and at least 468pt for the working area.
    static let minimumWindowWidth: CGFloat = 1080
    static func occupiedWidth(_ expanded: Bool, leading: Bool) -> CGFloat {
        (expanded ? (leading ? leadingWidth : trailingWidth) : buttonDiameter + buttonInset) + gap
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
    @State private var revealed: Bool
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.dLanguageStore) private var language
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
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
            let width = leading ? WorkbenchSidebarLayout.leadingWidth : WorkbenchSidebarLayout.trailingWidth
            let alignment: Alignment = leading ? .topLeading : .topTrailing
            let visible = expanded && revealed
            let palette = preferences.resolvedAppearance.palette(for: scheme)
            ZStack(alignment: alignment) {
                WorkbenchSidebarPlate(progress: expanded ? 1 : 0, expandedWidth: width,
                    expandedHeight: geometry.size.height, leading: leading)
                    .workbenchMorph(value: expanded)
                    .allowsHitTesting(false)

                VStack(spacing: 8) {
                    Text(title).font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
                        .padding(.leading, leading ? 60 : 12)
                        .padding(.trailing, leading ? 12 : 60)
                        .frame(height: 56)
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
                .accessibilityIdentifier(identifier)
                .keyboardShortcut(!leading && expanded ? .cancelAction : nil)
            }
            .frame(width: width, height: geometry.size.height, alignment: alignment)
        }
        .frame(width: leading ? WorkbenchSidebarLayout.leadingWidth : WorkbenchSidebarLayout.trailingWidth)
        .onChange(of: expanded) { _, open in if !open { revealed = false } }
        .task(id: expanded ? (revealDuration ?? 0) : -1) {
            guard expanded else { revealed = false; return }
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

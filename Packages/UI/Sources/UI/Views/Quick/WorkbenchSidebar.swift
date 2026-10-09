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
    static let gap: CGFloat = 16
    // Two panes, two gaps, outer insets and at least 468pt for the working area.
    static let minimumWindowWidth: CGFloat = 1080
    static func occupiedWidth(_ expanded: Bool, leading: Bool) -> CGFloat {
        (expanded ? (leading ? leadingWidth : trailingWidth) : buttonDiameter) + gap
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
            let shape = RoundedRectangle(cornerRadius: expanded ? 22 : 20,
                                         style: expanded ? .continuous : .circular)
            let visible = expanded && revealed
            let palette = preferences.resolvedAppearance.palette(for: scheme)
            ZStack(alignment: alignment) {
                Color.clear
                    .frame(width: expanded ? width : 40, height: expanded ? geometry.size.height : 40)
                    .workbenchGlassPlate(in: shape)
                    .workbenchMorph(value: expanded)
                    .allowsHitTesting(false)

                VStack(spacing: 8) {
                    Text(title).font(.headline).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
                        .padding(.leading, leading ? 52 : 12)
                        .padding(.trailing, leading ? 12 : 52)
                        .frame(height: 40)
                        .opacity(visible ? 1 : 0)
                        .workbenchMotion(value: visible)
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
                .buttonStyle(WorkbenchIconButtonStyle(diameter: 40))
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
        .task(id: expanded) {
            guard expanded else { revealed = false; return }
            guard !revealed else { return }
            let appearance = preferences.resolvedAppearance
            if !reduceMotion && !appearance.lightweight && appearance.motion > 0 {
                // Leave the native receiver hidden until the expanding plate has
                // settled. Task identity cancels stale completions on rapid toggles.
                do { try await Task.sleep(for: .seconds(0.5 + 0.4 * appearance.motion)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            revealed = true
        }
    }
}

struct WorkbenchCategoryLensTrack: View {
    let selection: CGFloat
    let titles: [String]
    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 2) {
                ForEach(titles.indices, id: \.self) { index in
                    Text(titles[index]).font(.body).frame(maxWidth: .infinity).frame(height: 36)
                }
            }
            WorkbenchCategoryLens(selection: selection, titles: titles)
                .workbenchMorph(value: selection)
        }.frame(width: 256, height: 36).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// One moving lens, with a locally magnified copy of the category labels. The
/// four actual buttons never move or scale, and remain the only input targets.
struct WorkbenchCategoryLens: View, Animatable {
    nonisolated var selection: CGFloat
    let titles: [String]
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    nonisolated var animatableData: CGFloat {
        get { selection }
        set { selection = newValue }
    }
    var body: some View {
        let width: CGFloat = (256 - 6) / 4
        let x = selection * (width + 2)
        let decorated = !preferences.resolvedAppearance.lightweight && !reduceTransparency && contrast != .increased
        Color.clear.frame(width: width, height: 36)
            .workbenchGlassPlate(in: Capsule())
            .overlay {
                if !decorated {
                    Capsule().strokeBorder(preferences.resolvedAppearance.palette(for: scheme).foregroundColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(titles.indices, id: \.self) { i in
                        Text(titles[i]).font(.body).frame(width: width, height: 36)
                    }
                }
                .frame(width: 256, height: 36)
                .scaleEffect(decorated ? 1.12 : 1, anchor: UnitPoint(x: (x + width / 2) / 256, y: 0.5))
                .offset(x: -x)
                .frame(width: width, height: 36, alignment: .leading)
                .clipShape(Capsule())
            }
            .offset(x: x)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

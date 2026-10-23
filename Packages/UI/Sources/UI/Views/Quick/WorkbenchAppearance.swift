import AppKit
import SwiftUI

/// Colors are stored as opaque sRGB values so saved choices are independent of the current system theme.
struct WorkbenchPalette: Codable, Equatable {
    var foreground: String
    var secondary: String
    var canvas: String
    var panel: String
    var accent: String

    static let defaultLight = WorkbenchPalette(
        foreground: "#162F29", secondary: "#455D54", canvas: "#EDF2EB",
        panel: "#FAFCF9", accent: "#24634F")
    static let defaultDark = WorkbenchPalette(
        foreground: "#E8F2EC", secondary: "#B8CCC0", canvas: "#111D1A",
        panel: "#1D2B25", accent: "#9AD3B8")

    static func isValidHex(_ value: String) -> Bool { RGB(hex: value) != nil }
    var isValid: Bool {
        [foreground, secondary, canvas, panel, accent].allSatisfy(Self.isValidHex)
    }

    var foregroundColor: Color { Color(rgb: foreground) }
    var secondaryColor: Color { Color(rgb: secondary) }
    var canvasColor: Color { Color(rgb: canvas) }
    var panelColor: Color { Color(rgb: panel) }
    var accentColor: Color { Color(rgb: accent) }

    /// Paint an opaque result, rather than asking a platform backdrop to choose
    /// a sampling surface. This blends canvas color only, not underlying media.
    func panelFill(canvasBlend: Double) -> Color {
        guard let panel = RGB(hex: panel), let canvas = RGB(hex: canvas),
              canvasBlend.isFinite, (0...1).contains(canvasBlend) else { return .black }
        let fill = panel.composited(over: canvas, opacity: 1 - canvasBlend)
        return Color(.sRGB, red: fill.red, green: fill.green, blue: fill.blue, opacity: 1)
    }

    /// WCAG contrast against the canvas, composited panel, and opaque panel fallback.
    /// Invalid hex is reported by `isValid`, rather than being treated as a passing contrast value.
    func contrastIssues(backgroundTransparency: Double) -> [String] {
        guard let foreground = RGB(hex: foreground), let secondary = RGB(hex: secondary),
              let canvas = RGB(hex: canvas), let panel = RGB(hex: panel),
              let accent = RGB(hex: accent), backgroundTransparency.isFinite,
              (0...1).contains(backgroundTransparency) else { return ["invalid color or transparency"] }
        let effectivePanel = panel.composited(over: canvas, opacity: 1 - backgroundTransparency)
        let backgrounds = [("canvas", canvas), ("panel", effectivePanel), ("opaque panel", panel)]
        let inks = [("foreground", foreground), ("secondary", secondary), ("accent", accent)]
        return backgrounds.flatMap { name, background in
            inks.compactMap { inkName, ink in
                ink.contrastRatio(with: background) < 4.5 ? "\(inkName) on \(name)" : nil
            }
        }
    }

    func hasSufficientContrast(backgroundTransparency: Double) -> Bool {
        contrastIssues(backgroundTransparency: backgroundTransparency).isEmpty
    }
}

struct WorkbenchAppearance: Codable, Equatable {
    var light = WorkbenchPalette.defaultLight
    var dark = WorkbenchPalette.defaultDark
    /// Saved key retained for compatibility. 0 is panel color, 1 is canvas color;
    /// the rendered plate stays opaque at every blend value.
    var backgroundTransparency = 0.12
    /// 0 disables decorative motion; 1 selects the full subtle transition.
    var motion = 0.5
    var lightweight = false
    var local: WorkbenchLocalAppearance? = nil
    var readability: WorkbenchReadabilitySettings? = nil
    var resolvedReadability: WorkbenchReadabilitySettings { readability ?? .init() }

    func palette(for colorScheme: ColorScheme) -> WorkbenchPalette {
        colorScheme == .dark ? dark : light
    }

    mutating func resetPalette(for colorScheme: ColorScheme) {
        if colorScheme == .dark { dark = .defaultDark }
        else { light = .defaultLight }
    }

    var isValid: Bool {
        light.isValid && dark.isValid && backgroundTransparency.isFinite && motion.isFinite
            && (0...1).contains(backgroundTransparency) && (0...1).contains(motion) && (local?.isValid ?? true) && (readability?.isValid ?? true)
    }
}

/// Decorative effects only. Saved appearance values and contrast calculations stay independent
/// of the current accessibility settings.
struct WorkbenchEffectsPolicy {
    let usesCanvasBlend: Bool
    let duration: Double?
    let morphDuration: Double?
    let morphCurve: UnitCurve
    let morphAnimation: Animation?

    init(appearance: WorkbenchAppearance, reduceMotion: Bool,
         reduceTransparency: Bool, increasedContrast: Bool) {
        usesCanvasBlend = !appearance.lightweight && !reduceTransparency && !increasedContrast
        duration = appearance.lightweight || reduceMotion || appearance.motion == 0
            ? nil : 0.1 + 0.25 * appearance.motion
        // Finite timing curve: acceleration, deceleration and a small return.
        // Unlike a spring's response, this duration is the entire transition.
        morphDuration = duration == nil ? nil : 0.18 + 0.04 * appearance.motion
        let curve = WorkbenchRebound.curve
        morphCurve = curve
        morphAnimation = morphDuration.map { Animation(WorkbenchRebound(duration: $0, strength: appearance.motion)) }
    }
}

/// Keep the accepted travel curve and finite clock. Amplify only its small
/// overshoot to the previous spring's peak, without reintroducing its long tail.
struct WorkbenchRebound: CustomAnimation {
    let duration: Double
    let strength: Double
    static var curve: UnitCurve {
        .bezier(startControlPoint: .init(x: 0.36, y: 0), endControlPoint: .init(x: 0.22, y: 1.12))
    }
    var peakOvershoot: Double {
        let damping = 0.82 - 0.12 * strength
        return exp(-damping * .pi / sqrt(1 - damping * damping))
    }
    func progress(at fraction: Double) -> Double {
        let base = Self.curve.value(at: min(1, max(0, fraction)))
        guard base > 1 else { return base }
        // Exact maximum of the original Bezier's y polynomial.
        let t = 6.72 / 7.08
        let originalPeak = 3 * (1 - t) * t * t * 1.12 + t * t * t - 1
        let phase = min(1, (base - 1) / originalPeak)
        // Zero correction slope at either end avoids a velocity kink when
        // crossing the target, while leaving all pre-target travel unchanged.
        return base + (peakOvershoot - originalPeak) * phase * phase * (3 - 2 * phase)
    }
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval,
                                      context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: progress(at: time / duration))
    }
}

/// Quiet shell over the shared app-owned background. Legacy records keep their
/// opaque blend; local material samples only prepared D background pixels.
private struct WorkbenchGlassPlate<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let decorated = !preferences.resolvedAppearance.lightweight && !reduceTransparency && contrast != .increased
        content.workbenchPanel(in: shape)
            .overlay {
                if decorated {
                    shape.strokeBorder(preferences.resolvedAppearance.palette(for: scheme)
                        .foregroundColor.opacity(0.12), lineWidth: 0.5)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct WorkbenchMorphModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let policy = WorkbenchEffectsPolicy(appearance: preferences.resolvedAppearance,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        content.animation(policy.morphAnimation, value: value)
    }
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        guard hex.count == 7, hex.first == "#",
              hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let bits = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = Double((bits >> 16) & 0xff) / 255
        green = Double((bits >> 8) & 0xff) / 255
        blue = Double(bits & 0xff) / 255
    }

    func composited(over background: RGB, opacity: Double) -> RGB {
        RGB(red: red * opacity + background.red * (1 - opacity),
            green: green * opacity + background.green * (1 - opacity),
            blue: blue * opacity + background.blue * (1 - opacity))
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    private var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: RGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

private extension Color {
    init(rgb hex: String) {
        guard let value = RGB(hex: hex) else { self = .clear; return }
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1)
    }
}

private struct WorkbenchPanelModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @State private var group = UUID().uuidString
    @Environment(\.workbenchSurfaceGroup) private var inheritedGroup
    @Environment(\.workbenchSurfaceRole) private var role
    @Environment(\.workbenchBackground) private var background
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let appearance = preferences.resolvedAppearance
        let palette = appearance.palette(for: colorScheme)
        let effects = WorkbenchEffectsPolicy(
            appearance: appearance, reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        let native = effects.usesCanvasBlend && appearance.local?.material == .glass
        content
            .environment(\.workbenchSurfaceGroup, inheritedGroup ?? group)
            .foregroundStyle(palette.foregroundColor)
            .background {
                Group {
                    if native { Color.clear }
                    else if let local = appearance.local {
                        WorkbenchLocalSurface(owner: background, palette: palette, strength: local.strength,
                            drawsGlass: effects.usesCanvasBlend && local.material == .glass,
                            surfaceGroup: inheritedGroup ?? group, surfaceRole: role,
                            readability: effects.usesCanvasBlend ? appearance.resolvedReadability : .init(),
                            contour: { rect, inset in shape.inset(by: inset).path(in: rect).cgPath })
                            .clipShape(shape)
                    } else {
                        shape.fill(palette.panelFill(canvasBlend:
                            effects.usesCanvasBlend ? appearance.backgroundTransparency : 0))
                    }
                }
                    .accessibilityHidden(true)
                    .overlay {
                        if !native {
                        // Thin curved rim, like the category lens. No light wash
                        // over the interior or any filtering of the content layer.
                        shape.strokeBorder(palette.foregroundColor.opacity(
                            effects.usesCanvasBlend && appearance.local?.material == .glass ? 0.24 : 0.08), lineWidth: 0.6)
                        if effects.usesCanvasBlend && appearance.local?.material == .glass {
                            shape.inset(by: 1).strokeBorder(palette.canvasColor.opacity(0.30), lineWidth: 0.6)
                        }
                    }
                    }
                    .shadow(color: !native && effects.usesCanvasBlend ? .black.opacity(0.10) : .clear,
                            radius: effects.usesCanvasBlend ? 8 : 0, y: effects.usesCanvasBlend ? 2 : 0)
                    .allowsHitTesting(false)
            }
            .glassEffect(native ? .regular.tint(palette.canvasColor.opacity((1 - (appearance.local?.strength ?? 0.55)) * 0.35)) : .identity, in: shape)
            .animation(effects.duration.map { .easeInOut(duration: $0) }, value: palette)
    }
}

private struct WorkbenchMotionModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let effects = WorkbenchEffectsPolicy(
            appearance: preferences.resolvedAppearance, reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
        content.symbolEffectsRemoved(effects.duration == nil)
            .animation(effects.duration.map { .easeInOut(duration: $0) }, value: value)
    }
}

extension View {
    func workbenchGlassPlate<S: InsettableShape>(in shape: S) -> some View {
        modifier(WorkbenchGlassPlate(shape: shape))
    }

    func workbenchMorph<Value: Equatable>(value: Value) -> some View {
        modifier(WorkbenchMorphModifier(value: value))
    }

    func workbenchPanel(cornerRadius: CGFloat = 12) -> some View {
        workbenchPanel(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func workbenchPanel<S: InsettableShape>(in shape: S) -> some View {
        modifier(WorkbenchPanelModifier(shape: shape))
    }

    func workbenchMotion<Value: Equatable>(value: Value) -> some View {
        modifier(WorkbenchMotionModifier(value: value))
    }
}

/// A presentation environment shared by SwiftUI and retained native hosts.
private struct WorkbenchThemeModifier: ViewModifier {
    var paintsCanvas = true
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var systemScheme
    func body(content: Content) -> some View {
        let palette = preferences.resolvedAppearance.palette(for: preferences.preferredColorScheme ?? systemScheme)
        content.foregroundStyle(palette.foregroundColor, palette.secondaryColor)
            .tint(palette.accentColor)
            .buttonStyle(WorkbenchGlassButtonStyle())
            .menuStyle(WorkbenchGlassMenuStyle())
            .textFieldStyle(WorkbenchGlassTextFieldStyle())
            .background { if paintsCanvas { palette.canvasColor } }
    }
}
extension View {
    func workbenchTheme(paintsCanvas: Bool = true) -> some View {
        modifier(WorkbenchThemeModifier(paintsCanvas: paintsCanvas))
    }
}

/// All D action buttons share the same local lens as panels. Accent and role
/// are ink/edge cues; the action, focus, keyboard shortcut and enabled state stay native.
struct WorkbenchGlassButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchGlassButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}
private struct WorkbenchGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    var compact = false
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var size
    var body: some View {
        let palette = preferences.resolvedAppearance.palette(for: preferences.preferredColorScheme ?? scheme)
        let ink = configuration.role == .destructive ? Color.red : prominent ? palette.accentColor : palette.foregroundColor
        configuration.label
            .padding(.horizontal, compact ? 0 : size == .mini || size == .small ? 7 : 12)
            .padding(.vertical, compact ? 0 : size == .mini || size == .small ? 3 : 6)
            .foregroundStyle(ink)
            .workbenchPanel(in: Capsule())
            .overlay { Capsule().strokeBorder(ink.opacity(prominent ? 0.5 : 0), lineWidth: 1).allowsHitTesting(false) }
            .modifier(WorkbenchButtonFeedback(shape: Capsule(), isPressed: configuration.isPressed, ink: ink))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
/// All finite lens selectors share local preview; business bindings only receive a
/// final choice. Native buttons retain keyboard and accessibility activation.
struct WorkbenchGlassSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    var featureIDs: [String]? = nil
    var identifiers: [String]? = nil
    var owner: AnyHashable? = nil
    var standard = false
    var direction: WorkbenchSegmentGeometry.Direction = .horizontal
    var unavailable: Set<Value> = []
    var minimumItemLength: CGFloat = 0
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchContentVisible) private var visible
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Value?
    @State private var identity = NSObject()
    @State private var preview: CGFloat?
    @State private var hovered: Int?
    @State private var pressed: Int?
    private var indices: Set<Int> { Set(choices.indices.filter { !unavailable.contains(choices[$0].0) }) }
    private var index: Int { choices.firstIndex(where: { $0.0 == selection }) ?? -1 }
    private var thickness: CGFloat { standard ? 44 : 32 }
    private var itemMinimum: CGFloat {
        if standard { return 66 }
        return max(minimumItemLength, (choices.map { ($0.1 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width }.max() ?? 0) + 24)
    }
    private var motion: Animation? {
        WorkbenchEffectsPolicy(appearance: preferences.resolvedAppearance, reduceMotion: reduceMotion,
            reduceTransparency: false, increasedContrast: false).morphAnimation
    }
    private func select(_ i: Int) {
        guard enabled && visible, indices.contains(i), choices[i].0 != selection else { return }
        selection = choices[i].0
    }
    private func clear() { preview = nil; hovered = nil; pressed = nil }
    var body: some View {
        GeometryReader { proxy in
            let length = direction == .horizontal ? proxy.size.width : proxy.size.height
            let geometry = WorkbenchSegmentGeometry(direction: direction, count: choices.count, length: length, thickness: thickness)
            ZStack(alignment: .topLeading) {
                Capsule().fill(.clear).frame(width: geometry.track.width, height: geometry.track.height)
                    .workbenchPanel(in: Capsule()).offset(x: geometry.track.minX, y: geometry.track.minY)
                    .allowsHitTesting(false)
                ForEach(Array(choices.enumerated()), id: \.element.0) { i, choice in
                    let rect = geometry.lens(CGFloat(i), engagement: 0)
                    Button { select(i) } label: { Text(choice.1).foregroundStyle(.clear) }
                        .buttonStyle(WorkbenchCategoryButtonStyle(height: rect.height, onPressChanged: { down in
                            if down { pressed = i } else if pressed == i { pressed = nil }
                        }))
                        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        .disabled(unavailable.contains(choice.0))
                        .focused($focus, equals: choice.0)
                        .onHover { inside in if inside && enabled { hovered = i } else if hovered == i { hovered = nil } }
                        .accessibilityAddTraits(selection == choice.0 ? .isSelected : [])
                        .accessibilityIdentifier(identifiers.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? "")
                        .workbenchHelp(featureIDs.flatMap { $0.indices.contains(i) ? $0[i] : nil })
                }
                if !choices.isEmpty {
                    WorkbenchCategoryLensTrack(selection: preview ?? CGFloat(max(0, index)), titles: choices.map(\.1),
                        engagement: preview != nil || pressed == index ? 1 : 0, hovered: hovered, pressed: pressed,
                        dragReceiver: WorkbenchCategoryDragReceiver(selection: index, owner: owner ?? AnyHashable(ObjectIdentifier(identity)),
                            enabled: enabled && visible, onPreview: { preview = $0 }, onCommit: select,
                            geometry: geometry, options: choices.map { AnyHashable($0.0) }, available: indices),
                        geometry: geometry, available: indices, showsSelection: index >= 0)
                        .animation(preview == nil ? motion : nil, value: preview ?? CGFloat(index))
                        .animation(reduceMotion || preferences.resolvedAppearance.motion == 0 ? nil : .easeOut(duration: 0.1), value: preview != nil || pressed == index)
                }
            }.frame(width: geometry.slotSize.width, height: geometry.slotSize.height)
                .onChange(of: geometry) { _, _ in clear() }
        }
        .frame(minWidth: direction == .horizontal ? itemMinimum * CGFloat(choices.count) : thickness + 8,
               idealWidth: direction == .horizontal ? itemMinimum * CGFloat(choices.count) : thickness + 8,
               maxWidth: direction == .horizontal ? .infinity : thickness + 8,
               minHeight: direction == .horizontal ? thickness + 8 : itemMinimum * CGFloat(choices.count),
               idealHeight: direction == .horizontal ? thickness + 8 : itemMinimum * CGFloat(choices.count),
               maxHeight: direction == .horizontal ? thickness + 8 : .infinity)
        .opacity(enabled ? 1 : 0.45)
        .onChange(of: visible) { _, value in if !value { clear() } }
        .onChange(of: enabled) { _, value in if !value { clear() } }
        .onChange(of: owner) { _, _ in clear() }
        .onChange(of: choices.map(\.0)) { _, _ in clear() }
        .onChange(of: unavailable) { _, _ in clear() }
        .onChange(of: selection) { _, _ in preview = nil }
        .onDisappear { clear() }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .onMoveCommand { command in
            guard enabled && visible, let current = choices.firstIndex(where: { $0.0 == (focus ?? selection) }) else { return }
            let delta: Int
            switch (direction, command) {
            case (.horizontal, .left), (.vertical, .up): delta = -1
            case (.horizontal, .right), (.vertical, .down): delta = 1
            default: return
            }
            var next = current + delta
            while choices.indices.contains(next) {
                if indices.contains(next) { select(next); focus = choices[next].0; return }
                next += delta
            }
        }
    }
}

private struct WorkbenchAppearanceStateKey: EnvironmentKey {
    static let defaultValue: ChatDisplayPreferencesState? = nil
}
extension EnvironmentValues {
    var workbenchAppearanceState: ChatDisplayPreferencesState? {
        get { self[WorkbenchAppearanceStateKey.self] }
        set { self[WorkbenchAppearanceStateKey.self] = newValue }
    }
}
private struct WorkbenchPresentedSurface: ViewModifier {
    @Environment(\.workbenchAppearanceState) private var state
    func body(content: Content) -> some View {
        if let state { content.workbenchPresentation(state: state) }
        else { content.workbenchTheme() }
    }
}

/// Sheets own a separate canvas coordinate space instead of converting against
/// the presenting window. Only the existing appearance preference owner is shared.
extension View {
    func workbenchPresentation() -> some View { modifier(WorkbenchPresentedSurface()) }
    func workbenchPresentation(state: ChatDisplayPreferencesState) -> some View {
        workbenchTheme(paintsCanvas: false)
            .modifier(WorkbenchCanvasModifier(state: state))
            .environment(\.chatDisplayPreferences, state.preferences)
            .preferredColorScheme(state.preferences.preferredColorScheme)
    }
}

struct WorkbenchGlassMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.borderlessButton)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .workbenchPanel(in: Capsule())
    }
}
struct WorkbenchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchGlassButtonBody(configuration: configuration, prominent: true)
    }
}

/// The complete visible plate belongs to the label. Its geometry never changes
/// while pressing or hovering, so feedback cannot move an edge out from under the pointer.
struct WorkbenchIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 28
    var panel = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: diameter, height: diameter)
            .workbenchPanel(in: Circle())
        .modifier(WorkbenchButtonFeedback(shape: Circle(), isPressed: configuration.isPressed))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Fixed capsule targets sit above the decorative moving lens.
struct WorkbenchCategoryButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    var onPressChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity).frame(height: height)
            .contentShape(.interaction, Capsule())
            .onChange(of: configuration.isPressed) { _, pressed in onPressChanged(isEnabled && pressed) }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct WorkbenchRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .workbenchPanel(cornerRadius: cornerRadius)
            .modifier(WorkbenchButtonFeedback(shape: RoundedRectangle(cornerRadius: cornerRadius),
                isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct WorkbenchButtonFeedback<S: InsettableShape>: ViewModifier {
    let shape: S
    let isPressed: Bool
    var ink: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(ink.opacity(isEnabled ? (isPressed ? 0.22 : hovered ? 0.10 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(ink.opacity(isEnabled && hovered ? 0.32 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(.interaction, shape)
            .onHover { hovered = $0 }
            .workbenchMotion(value: hovered)
            .workbenchMotion(value: isPressed)
    }
}


/// Keep the native field and its binding. Only the shell samples D's background;
/// the field editor, marked text, selection and Undo never enter the renderer.
struct WorkbenchGlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .modifier(WorkbenchInputSurface())
    }
}

private struct WorkbenchInputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).workbenchPanel(cornerRadius: 8)
    }
}

extension View {
    func workbenchInputSurface() -> some View { modifier(WorkbenchInputSurface()) }
}

/// Native text remains an unfiltered foreground over the same SwiftUI shell.
/// Appearance updates deliberately do not touch contents, selection or Undo.
@MainActor enum WorkbenchNativeTextAppearance {
    static func apply(_ scroll: NSScrollView, editor: NSTextView, color: NSColor) {
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        editor.drawsBackground = false
        if editor.textColor != color { editor.textColor = color }
        if editor.insertionPointColor != color { editor.insertionPointColor = color }
    }
}

@MainActor func layoutText(_ language: UILanguageStore?, _ key: String, arguments: [String: String] = [:]) -> String {
    workflowText(language, "layoutInteraction." + key, arguments: arguments)
}

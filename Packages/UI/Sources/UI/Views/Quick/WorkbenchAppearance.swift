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

    func palette(for colorScheme: ColorScheme) -> WorkbenchPalette {
        colorScheme == .dark ? dark : light
    }

    mutating func resetPalette(for colorScheme: ColorScheme) {
        if colorScheme == .dark { dark = .defaultDark }
        else { light = .defaultLight }
    }

    var isValid: Bool {
        light.isValid && dark.isValid && backgroundTransparency.isFinite && motion.isFinite
            && (0...1).contains(backgroundTransparency) && (0...1).contains(motion)
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

/// App-local glass appearance over the opaque canvas blend. No platform backdrop
/// sampler is introduced here. A quiet boundary defines the local lens; there
/// is no painted light source or full-surface reflection. This is not refraction.
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
        content
            .foregroundStyle(palette.foregroundColor)
            .background {
                shape.fill(palette.panelFill(canvasBlend:
                    effects.usesCanvasBlend ? appearance.backgroundTransparency : 0))
                    .overlay {
                        shape.strokeBorder(palette.foregroundColor.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: effects.usesCanvasBlend ? .black.opacity(0.10) : .clear,
                            radius: effects.usesCanvasBlend ? 8 : 0, y: effects.usesCanvasBlend ? 2 : 0)
                    .allowsHitTesting(false)
            }
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
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var systemScheme
    func body(content: Content) -> some View {
        let palette = preferences.resolvedAppearance.palette(for: preferences.preferredColorScheme ?? systemScheme)
        content.foregroundStyle(palette.foregroundColor, palette.secondaryColor)
            .tint(palette.accentColor).background(palette.canvasColor)
    }
}
extension View {
    func workbenchTheme() -> some View { modifier(WorkbenchThemeModifier()) }
}

/// Explicit foreground and fill keep primary actions readable in both palettes.
/// Native borderedProminent can reinterpret foregroundStyle as its control tint.
struct WorkbenchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = preferences.resolvedAppearance.palette(for: preferences.preferredColorScheme ?? systemScheme)
        configuration.label
            .foregroundStyle(palette.canvasColor)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(palette.accentColor, in: RoundedRectangle(cornerRadius: 10))
            .modifier(WorkbenchButtonFeedback(shape: RoundedRectangle(cornerRadius: 10),
                isPressed: configuration.isPressed, ink: palette.canvasColor))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The complete visible plate belongs to the label. Its geometry never changes
/// while pressing or hovering, so feedback cannot move an edge out from under the pointer.
struct WorkbenchIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 28
    var panel = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if panel {
                configuration.label.frame(width: diameter, height: diameter)
                    .workbenchPanel(in: Circle())
            } else {
                configuration.label.frame(width: diameter, height: diameter)
            }
        }
        .modifier(WorkbenchButtonFeedback(shape: Circle(), isPressed: configuration.isPressed))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Fixed capsule targets sit above the decorative moving lens.
struct WorkbenchCategoryButtonStyle: ButtonStyle {
    var onPressChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity).frame(height: 36)
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

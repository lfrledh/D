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
    /// 0 is opaque; 1 lets the canvas show through the panel background.
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
    let usesGlass: Bool
    let duration: Double?

    init(appearance: WorkbenchAppearance, reduceMotion: Bool,
         reduceTransparency: Bool, increasedContrast: Bool) {
        usesGlass = !appearance.lightweight && !reduceTransparency && !increasedContrast
        duration = appearance.lightweight || reduceMotion || appearance.motion == 0
            ? nil : 0.1 + 0.25 * appearance.motion
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

private struct WorkbenchPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .foregroundStyle(palette.foregroundColor)
            .background {
                if effects.usesGlass {
                    // Glass belongs to the background shape, never to the content or its text.
                    // The saved slider controls tint and backing opacity through public APIs.
                    shape.fill(palette.panelColor.opacity(1 - appearance.backgroundTransparency))
                        .glassEffect(
                            .regular.tint(palette.panelColor.opacity(1 - appearance.backgroundTransparency)),
                            in: shape)
                } else {
                    shape.fill(palette.panelColor)
                }
            }
            .shadow(color: effects.usesGlass ? .black.opacity(0.10) : .clear,
                    radius: effects.usesGlass ? 8 : 0, y: effects.usesGlass ? 2 : 0)
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
    func workbenchPanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(WorkbenchPanelModifier(cornerRadius: cornerRadius))
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

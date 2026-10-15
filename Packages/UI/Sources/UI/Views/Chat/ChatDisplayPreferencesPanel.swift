import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatDisplayPreferencesPanel: View {
    let state: ChatDisplayPreferencesState
    @Environment(\.dLanguageStore) private var language
    @State private var glassStrength: Double?
    @State private var choosingWallpaper = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var wallpaperPanel: NSOpenPanel?
    @State private var selectionTicket = UUID()
    @State private var editingScheme: ColorScheme = .light
    @State private var hexDrafts: [String: String] = [:]

    private enum PaletteField: String, CaseIterable {
        case foreground, secondary, canvas, panel, accent

        var title: (String, String) {
            switch self {
            case .foreground: return ("Primary text", "主要文字")
            case .secondary: return ("Secondary text", "次要文字")
            case .canvas: return ("Canvas background", "画布背景")
            case .panel: return ("Panel background", "面板背景")
            case .accent: return ("Accent and links", "强调色与链接")
            }
        }

        func value(in palette: WorkbenchPalette) -> String {
            switch self {
            case .foreground: palette.foreground
            case .secondary: palette.secondary
            case .canvas: palette.canvas
            case .panel: palette.panel
            case .accent: palette.accent
            }
        }

        func set(_ value: String, in palette: inout WorkbenchPalette) {
            switch self {
            case .foreground: palette.foreground = value
            case .secondary: palette.secondary = value
            case .canvas: palette.canvas = value
            case .panel: palette.panel = value
            case .accent: palette.accent = value
            }
        }
    }

    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }

    private func label(_ key: String, _ en: String, _ zh: String) -> String {
        workflowText(language, "refinement.appearance." + key, fallback: wording(en, zh))
    }

    private func issueLabel(_ issue: String) -> String {
        if issue == "invalid color or transparency" {
            return label("contrast.invalid", "Invalid color or transparency", "颜色或透明度无效")
        }
        let parts = issue.components(separatedBy: " on ")
        guard parts.count == 2 else { return issue }
        let ink: String
        switch parts[0] {
        case "foreground": ink = label("contrast.foreground", "primary text", "主要文字")
        case "secondary": ink = label("contrast.secondary", "secondary text", "次要文字")
        case "accent": ink = label("contrast.accent", "accent", "强调色")
        default: return issue
        }
        let background: String
        switch parts[1] {
        case "canvas": background = label("contrast.canvas", "canvas", "画布")
        case "panel": background = label("contrast.panel", "panel", "面板")
        case "opaque panel": background = label("contrast.opaquePanel", "opaque panel fallback", "不透明面板回退")
        default: return issue
        }
        return workflowText(language, "refinement.appearance.contrast.pair",
                            fallback: wording("{ink} on {background}", "{ink}位于{background}上"),
                            arguments: ["ink": ink, "background": background])
    }

    @discardableResult
    private func change(_ edit: (inout ChatDisplayPreferences) -> Void) -> Bool {
        var candidate = state.preferences
        edit(&candidate)
        return state.update(candidate)
    }

    private var selectedPalette: WorkbenchPalette {
        state.preferences.resolvedAppearance.palette(for: editingScheme)
    }

    private func draftKey(_ field: PaletteField) -> String {
        "\(editingScheme == .dark ? "dark" : "light").\(field.rawValue)"
    }

    private func editHex(_ field: PaletteField, value: String) {
        let key = draftKey(field)
        hexDrafts[key] = value
        guard WorkbenchPalette.isValidHex(value) else { return }
        let normalized = value.uppercased()
        if change({ preferences in
            var appearance = preferences.resolvedAppearance
            if editingScheme == .dark {
                field.set(normalized, in: &appearance.dark)
            } else {
                field.set(normalized, in: &appearance.light)
            }
            preferences.appearance = appearance
        }) {
            hexDrafts.removeValue(forKey: key)
        }
    }

    private func paletteField(_ field: PaletteField) -> some View {
        let key = draftKey(field)
        let draft = hexDrafts[key]
        let title = label("palette." + field.rawValue, field.title.0, field.title.1)
        return VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: Binding(
                get: { hexDrafts[key] ?? field.value(in: selectedPalette) },
                set: { editHex(field, value: $0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .accessibilityIdentifier("workbench-\(key)")
            if let draft, !WorkbenchPalette.isValidHex(draft) {
                Text(label("palette.invalid", "Use #RRGGBB (six hexadecimal digits). The saved color is unchanged.",
                           "请输入 #RRGGBB（六位十六进制）。已保存颜色不会改变。"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var appearancePreview: some View {
        let palette = selectedPalette
        return VStack(alignment: .leading, spacing: 8) {
            Text(label("preview.title", "Preview", "预览")).font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text(label("preview.heading", "A new idea", "新的灵感"))
                    .font(.headline).foregroundStyle(palette.foregroundColor)
                Text(label("preview.body", "Your work stays in your project.", "作品保存在你的项目中。"))
                    .font(.subheadline).foregroundStyle(palette.secondaryColor)
                Text(label("preview.link", "View details", "查看详情"))
                    .font(.subheadline).foregroundStyle(palette.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .workbenchPanel(cornerRadius: 12)
            .environment(\.chatDisplayPreferences, state.preferences)
            .environment(\.colorScheme, editingScheme)
        }
        .padding(12)
        .background(palette.canvasColor, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench-appearance-preview")
    }

    private func changeLocal(_ edit: (inout WorkbenchLocalAppearance) -> Void) {
        change { candidate in
            var appearance = candidate.resolvedAppearance
            var local = appearance.local ?? WorkbenchLocalAppearance()
            edit(&local); appearance.local = local; candidate.appearance = appearance
        }
    }

    private func chooseWallpaper() {
        guard !choosingWallpaper else { return }
        choosingWallpaper = true
        let ticket = UUID(); selectionTicket = ticket
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = wording("Choose a static image for D’s canvas. Your original stays unchanged.", "为 D 的画布选择一张静态图片，原图保持不变。")
        wallpaperPanel = panel
        selectionTask = Task { @MainActor in
            defer { if selectionTicket == ticket { choosingWallpaper = false; wallpaperPanel = nil; selectionTask = nil } }
            guard await panel.begin() == .OK, let url = panel.url,
                  selectionTicket == ticket, !Task.isCancelled else { return }
            await state.importWallpaper(url)
        }
    }

    private var canvasSettings: some View {
        Section(wording("Canvas and panels", "画布与面板")) {
            LabeledContent(wording("Canvas background", "画布背景"),
                value: state.preferences.appearance?.local?.wallpaper == nil
                    ? wording("Solid color", "纯色") : wording("Local image", "本地图像"))
            Text(wording("The canvas defaults to a solid color. You can choose your own PNG or JPEG image.", "画布默认使用纯色，也可以选择自己的 PNG 或 JPEG 背景图片。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(wording("Choose background image…", "选择背景图片…"), action: chooseWallpaper)
                    .disabled(choosingWallpaper || state.wallpaperPreparing || state.appearanceDirectory == nil)
                Button(wording("Restore solid color", "恢复纯色")) { state.restoreSolidCanvas() }
            }
            if state.wallpaperPreparing { ProgressView().controlSize(.small) }
            if state.wallpaperIssue {
                Text(wording("The canvas image could not be prepared or read. Your previous choice is kept; a solid background is used when unavailable.", "画布图片未能准备或读取。原选择保留；无法读取时使用纯色背景。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(wording("Panel material", "面板材质"), selection: Binding(
                get: { state.preferences.appearance?.local?.material ?? .solid },
                set: { value in changeLocal { $0.material = value } })) {
                    Text(wording("App-local glass", "应用内玻璃")).tag(WorkbenchLocalAppearance.Material.glass)
                    Text(wording("Solid", "实色")).tag(WorkbenchLocalAppearance.Material.solid)
                }
            if state.preferences.appearance?.local == nil {
                Text(wording("Your previous canvas color blend is preserved until you choose a new material.", "选择新材质前，保留原来的画布底色混合效果。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { glassStrength ?? state.preferences.appearance?.local?.strength ?? 0.55 },
                set: { glassStrength = $0 }), in: 0...1, onEditingChanged: { editing in
                    if !editing, let value = glassStrength { changeLocal { $0.strength = value }; glassStrength = nil }
                }) { Text(wording("Glass transparency", "玻璃透明度")) }
                .disabled(state.preferences.appearance?.local?.material != .glass)
            Button(wording("Reset transparency", "恢复默认透明度")) { glassStrength = nil; changeLocal { $0.strength = 0.55 } }
            Text(wording("Panels sample only D’s canvas, never your desktop. Images are bounded sRGB appearance copies; original artwork and previews are unchanged.", "面板只映出 D 的画布，不透出系统桌面。背景使用有界 sRGB 外观副本，原作品和预览保持不变。"))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(state.hasInvalidStoredRecord)
    }

    var body: some View {
        Form {
            if state.hasInvalidStoredRecord {
                Text(label("invalidRecord", "Saved chat display settings are invalid. The original record is preserved. Reset it to edit these settings.",
                           "已保存的聊天显示设置无效。原始记录已保留。重置后才能编辑这些设置。"))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chat-display-invalid-record")
                Button(label("resetSettings", "Reset display settings", "重置显示设置")) { state.reset() }
                    .accessibilityIdentifier("chat-display-reset")
            }

            Section {
            Picker(label("theme", "Appearance", "外观"), selection: Binding(
                get: { state.preferences.theme }, set: { value in change { $0.theme = value } })) {
                    Text(label("system", "System", "跟随系统")).tag(ChatDisplayPreferences.Theme.system)
                    Text(label("light", "Light", "浅色")).tag(ChatDisplayPreferences.Theme.light)
                    Text(label("dark", "Dark", "深色")).tag(ChatDisplayPreferences.Theme.dark)
                }
                .accessibilityIdentifier("chat-display-theme")

            Stepper(value: Binding(get: { state.preferences.textPointSize },
                                   set: { value in change { $0.textPointSize = value } }), in: 12...28) {
                Text("\(label("textSize", "Text size", "文字大小")): \(state.preferences.textPointSize) pt")
            }
            .accessibilityIdentifier("chat-display-text-size")

            Stepper(value: Binding(get: { state.preferences.transcriptWidth },
                                   set: { value in change { $0.transcriptWidth = value } }), in: 480...1100, step: 20) {
                Text("\(label("transcriptWidth", "Transcript width", "记录宽度")): \(state.preferences.transcriptWidth) pt")
            }
            .accessibilityIdentifier("chat-display-transcript-width")

            Toggle(label("wrapCode", "Wrap code lines", "代码自动换行"), isOn: Binding(
                get: { state.preferences.wrapsCode }, set: { value in change { $0.wrapsCode = value } }))
                .accessibilityIdentifier("chat-display-code-wrap")

            }
            .disabled(state.hasInvalidStoredRecord)

            Section(label("colors", "Workbench colors", "工作台配色")) {
                Picker(label("editingPalette", "Editing palette", "编辑配色"), selection: $editingScheme) {
                    Text(label("light", "Light", "浅色")).tag(ColorScheme.light)
                    Text(label("dark", "Dark", "深色")).tag(ColorScheme.dark)
                }
                .accessibilityIdentifier("workbench-palette-selection")
                ForEach(PaletteField.allCases, id: \.self) { field in
                    paletteField(field)
                }
                let issues = selectedPalette.contrastIssues(
                    backgroundTransparency: state.preferences.resolvedAppearance.backgroundTransparency)
                if !issues.isEmpty {
                    Text(label("contrast.low", "Low contrast: ", "对比度较低：") +
                         issues.map(issueLabel).joined(separator: label("contrast.separator", ", ", "、")))
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("workbench-low-contrast")
                }
                appearancePreview
                Button(label("resetPalette", "Reset selected palette", "重置当前配色")) {
                    let scheme = editingScheme
                    if change({ preferences in
                        var appearance = preferences.resolvedAppearance
                        appearance.resetPalette(for: scheme)
                        preferences.appearance = appearance
                    }) {
                        hexDrafts = hexDrafts.filter { !$0.key.hasPrefix(scheme == .dark ? "dark." : "light.") }
                    }
                }
                .accessibilityIdentifier("workbench-palette-reset")
            }
            .disabled(state.hasInvalidStoredRecord)

            canvasSettings

            Section(label("effects", "Effects", "视觉效果")) {
                if state.preferences.appearance?.local == nil {
                VStack(alignment: .leading) {
                    Text("\(label("backgroundTransparency", "Canvas color blend", "画布底色占比")): \(Int(state.preferences.resolvedAppearance.backgroundTransparency * 100))%")
                    Slider(value: Binding(
                        get: { state.preferences.resolvedAppearance.backgroundTransparency },
                        set: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance
                            appearance.backgroundTransparency = value
                            preferences.appearance = appearance
                        } }), in: 0...1)
                        .accessibilityLabel(label("backgroundTransparency", "Canvas color blend", "画布底色占比"))
                        .accessibilityValue("\(Int(state.preferences.resolvedAppearance.backgroundTransparency * 100))%")
                        .accessibilityIdentifier("workbench-background-transparency")
                        .help(label("backgroundBlendHint", "0% panel color; 100% canvas color.", "0% 为面板色，100% 为画布色。"))
                }
                }
                VStack(alignment: .leading) {
                    Text("\(label("motion", "Decorative motion", "装饰性动态")): \(Int(state.preferences.resolvedAppearance.motion * 100))%")
                    Slider(value: Binding(
                        get: { state.preferences.resolvedAppearance.motion },
                        set: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance
                            appearance.motion = value
                            preferences.appearance = appearance
                        } }), in: 0...1)
                        .accessibilityLabel(label("motion", "Decorative motion", "装饰性动态"))
                        .accessibilityValue("\(Int(state.preferences.resolvedAppearance.motion * 100))%")
                        .accessibilityIdentifier("workbench-motion")
                }
                Toggle(label("lightweight", "Lightweight appearance", "轻量外观"), isOn: Binding(
                    get: { state.preferences.resolvedAppearance.lightweight },
                    set: { value in change { preferences in
                        var appearance = preferences.resolvedAppearance
                        appearance.lightweight = value
                        preferences.appearance = appearance
                    } }))
                    .accessibilityIdentifier("workbench-lightweight")
                Text(label("performanceNote",
                           "Panels blend with the canvas color; they do not blur content behind them. Accessibility settings are respected. Lightweight mode uses panel color and removes decorative motion.",
                           "面板与画布底色融合，不模糊下方内容，并遵循辅助功能设置。轻量模式使用面板原色并关闭装饰性动态。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(state.hasInvalidStoredRecord)
        }
        .onAppear { if state.preferences.theme == .dark { editingScheme = .dark } }
        .onDisappear {
            selectionTicket = UUID(); selectionTask?.cancel(); selectionTask = nil
            wallpaperPanel?.cancel(nil); wallpaperPanel = nil; choosingWallpaper = false
            state.cancelWallpaperPreparation()
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatDisplayPreferencesPanel: View {
    let state: ChatDisplayPreferencesState
    @Environment(\.dLanguageStore) private var language
    @State private var previewGroup = UUID().uuidString
    @State private var glassStrength: Double?
    @State private var enhancement: Double?
    @State private var motionDraft: Double?
    @State private var blendDraft: Double?
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

    private func paletteColor(_ hex: String) -> Color {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return .clear }
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }

    private func paletteField(_ field: PaletteField) -> some View {
        let key = draftKey(field)
        let draft = hexDrafts[key]
        let title = label("palette." + field.rawValue, field.title.0, field.title.1)
        return VStack(alignment: .leading, spacing: 3) {
            ColorPicker(title, selection: Binding(get: { paletteColor(field.value(in: selectedPalette)) }, set: { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                editHex(field, value: String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())))
            }), supportsOpacity: false)
            TextField(title, text: Binding(
                get: { hexDrafts[key] ?? field.value(in: selectedPalette) },
                set: { editHex(field, value: $0) }))
                .textFieldStyle(WorkbenchGlassTextFieldStyle())
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
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    Text(label("preview.node", "Example node", "示例节点")).padding(12)
                        .frame(width: 140, height: 76).workbenchPanel(cornerRadius: 12)
                        .workbenchSurface(.node, group: previewGroup + ":back")
                    Text(label("preview.result", "Example result", "示例结果")).padding(12)
                        .frame(width: 140, height: 76).workbenchPanel(cornerRadius: 12)
                        .workbenchSurface(.node, group: previewGroup + ":front").offset(x: 26, y: 26)
                }.frame(width: 170, height: 110)
                VStack(spacing: 0) {
                    HStack {
                        Text(label("preview.tools", "Preview tools", "预览工具"))
                        Spacer()
                        WorkbenchMenu(label("preview.menu", "Preview menu", "预览菜单")) {
                            WorkbenchMenuAction(label("preview.fake", "Example action", "示例操作")) { }
                            WorkbenchSubmenu(label("preview.submenu", "Example submenu", "示例子菜单")) {
                                WorkbenchMenuAction(label("preview.fake", "Example action", "示例操作")) { }
                            }
                        }
                    }.padding(8).workbenchPanel(cornerRadius: 0).workbenchSurface(.scrollEdge)
                    WorkbenchScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(1...12, id: \.self) { index in
                                Text(label("preview.row", "Example", "示例") + " " + String(index)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(8)
                    }.frame(height: 70)
                }.environment(\.workbenchSurfaceGroup, previewGroup + ":scroll")
            }
            .environment(\.chatDisplayPreferences, previewPreferences)
            .environment(\.colorScheme, editingScheme)
        }
        .padding(12)
        .background(palette.canvasColor, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench-appearance-preview")
    }

    private var previewPreferences: ChatDisplayPreferences {
        var candidate = state.preferences
        var appearance = candidate.resolvedAppearance
        if let glassStrength { var local = appearance.local ?? .init(); local.strength = glassStrength; appearance.local = local }
        if let enhancement { var settings = appearance.resolvedReadability; settings.amount = enhancement; appearance.readability = settings }
        if let motionDraft { appearance.motion = motionDraft }
        if let blendDraft { appearance.backgroundTransparency = blendDraft }
        candidate.appearance = appearance
        return candidate
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
                Button(wording("Choose background image…", "选择背景图片…"), action: chooseWallpaper).workbenchHelp("SETTINGS-WALLPAPER")
                    .disabled(choosingWallpaper || state.wallpaperPreparing || state.appearanceDirectory == nil)
                Button(wording("Restore solid color", "恢复纯色")) { state.restoreSolidCanvas() }.workbenchHelp("SETTINGS-SOLID")
            }
            if state.wallpaperPreparing { ProgressView().controlSize(.small) }
            if state.wallpaperIssue {
                Text(wording("The canvas image could not be prepared or read. Your previous choice is kept; a solid background is used when unavailable.", "画布图片未能准备或读取。原选择保留；无法读取时使用纯色背景。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            WorkbenchPicker(wording("Panel material", "面板材质"), selection: Binding(
                get: { state.preferences.appearance?.local?.material ?? .solid },
                set: { value in changeLocal { $0.material = value } })) {
                    WorkbenchChoice(wording("App-local glass", "应用内玻璃"), value:WorkbenchLocalAppearance.Material.glass)
                    WorkbenchChoice(wording("Solid", "实色"), value:WorkbenchLocalAppearance.Material.solid)
                }.workbenchHelp("SETTINGS-MATERIAL")
            if state.preferences.appearance?.local == nil {
                Text(wording("Your previous canvas color blend is preserved until you choose a new material.", "选择新材质前，保留原来的画布底色混合效果。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(consistencyText(language, "SETTINGS-TRANSPARENCY"))
            WorkbenchValueSlider(value: state.preferences.resolvedAppearance.local?.strength ?? 0.55,
                label: consistencyText(language, "SETTINGS-TRANSPARENCY"), preview: { glassStrength = $0 },
                commit: { value in changeLocal { $0.strength = value } }).workbenchHelp("SETTINGS-TRANSPARENCY").frame(height: 24)
                .disabled(state.preferences.appearance?.local?.material != .glass)
            Button(wording("Reset transparency", "恢复默认透明度")) { glassStrength = nil; changeLocal { $0.strength = 0.55 } }
            Toggle(consistencyText(language, "SETTINGS-READABILITY"), isOn: Binding(
                get: { state.preferences.resolvedAppearance.resolvedReadability.enabled },
                set: { enabled in change { candidate in
                    var appearance = candidate.resolvedAppearance
                    var settings = appearance.resolvedReadability; settings.enabled = enabled
                    appearance.readability = settings; candidate.appearance = appearance
                } })).workbenchHelp("SETTINGS-READABILITY")
            Text(consistencyText(language, "copy.readabilityHelp")).font(.caption).foregroundStyle(.secondary)
            Text(consistencyText(language, "SETTINGS-AMOUNT"))
            WorkbenchValueSlider(value: state.preferences.resolvedAppearance.resolvedReadability.amount,
                label: consistencyText(language, "SETTINGS-AMOUNT"), preview: { enhancement = $0 },
                commit: { value in change { candidate in
                    var appearance = candidate.resolvedAppearance
                    var settings = appearance.resolvedReadability; settings.amount = value
                    appearance.readability = settings; candidate.appearance = appearance
                } }).workbenchHelp("SETTINGS-AMOUNT").frame(height: 24)
                .disabled(!state.preferences.resolvedAppearance.resolvedReadability.enabled)
            appearancePreview.environment(\.chatDisplayPreferences, previewPreferences)
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
            WorkbenchPicker(label("theme", "Appearance", "外观"), selection: Binding(
                get: { state.preferences.theme }, set: { value in change { $0.theme = value } })) {
                    WorkbenchChoice(label("system", "System", "跟随系统"), value:ChatDisplayPreferences.Theme.system)
                    WorkbenchChoice(label("light", "Light", "浅色"), value:ChatDisplayPreferences.Theme.light)
                    WorkbenchChoice(label("dark", "Dark", "深色"), value:ChatDisplayPreferences.Theme.dark)
                }
                .accessibilityIdentifier("chat-display-theme").workbenchHelp("SETTINGS-THEME")

            }.disabled(state.hasInvalidStoredRecord)

            canvasSettings

            Section(label("effects", "Effects", "视觉效果")) {
                if state.preferences.appearance?.local == nil {
                VStack(alignment: .leading) {
                    Text("\(label("backgroundTransparency", "Canvas color blend", "画布底色占比")): \(Int(state.preferences.resolvedAppearance.backgroundTransparency * 100))%")
                    WorkbenchValueSlider(value: state.preferences.resolvedAppearance.backgroundTransparency,
                        label: label("backgroundTransparency", "Canvas color blend", "画布底色占比"), preview: { blendDraft = $0 },
                        commit: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance; appearance.backgroundTransparency = value; preferences.appearance = appearance
                        } }).frame(height: 24)
                        .accessibilityLabel(label("backgroundTransparency", "Canvas color blend", "画布底色占比"))
                        .accessibilityValue("\(Int(state.preferences.resolvedAppearance.backgroundTransparency * 100))%")
                        .accessibilityIdentifier("workbench-background-transparency")
                        .help(label("backgroundBlendHint", "0% panel color; 100% canvas color.", "0% 为面板色，100% 为画布色。"))
                }
                }
                VStack(alignment: .leading) {
                    Text("\(label("motion", "Decorative motion", "装饰性动态")): \(Int(state.preferences.resolvedAppearance.motion * 100))%")
                    WorkbenchValueSlider(value: state.preferences.resolvedAppearance.motion,
                        label: label("motion", "Decorative motion", "装饰性动态"), preview: { motionDraft = $0 },
                        commit: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance; appearance.motion = value; preferences.appearance = appearance
                        } }).frame(height: 24)
                        .accessibilityLabel(label("motion", "Decorative motion", "装饰性动态"))
                        .accessibilityValue("\(Int(state.preferences.resolvedAppearance.motion * 100))%")
                        .accessibilityIdentifier("workbench-motion").workbenchHelp("SETTINGS-MOTION")
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
                           "Glass samples only D’s background. Lightweight appearance uses solid panels and removes decorative motion.",
                           "玻璃只采样 D 的背景。轻量外观使用实色面板并关闭装饰性动态。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(state.hasInvalidStoredRecord)
            Section(consistencyText(language, "copy.textDisplay")) {
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

            }.disabled(state.hasInvalidStoredRecord)
            DisclosureGroup(consistencyText(language, "copy.advancedColors")) {
            Section(label("colors", "Workbench colors", "工作台配色")) {
                WorkbenchPicker(label("editingPalette", "Editing palette", "编辑配色"), selection: $editingScheme) {
                    WorkbenchChoice(label("light", "Light", "浅色"), value:ColorScheme.light)
                    WorkbenchChoice(label("dark", "Dark", "深色"), value:ColorScheme.dark)
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

            }
        }
        .onAppear { if state.preferences.theme == .dark { editingScheme = .dark } }
        .onDisappear {
            selectionTicket = UUID(); selectionTask?.cancel(); selectionTask = nil
            wallpaperPanel?.cancel(nil); wallpaperPanel = nil; choosingWallpaper = false
            state.cancelWallpaperPreparation()
        }
    }
}

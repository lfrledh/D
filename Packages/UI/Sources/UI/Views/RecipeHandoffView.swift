import AppKit
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

/// One finite handoff sheet; does not open projects, run models or interpret imported instructions.
struct RecipeHandoffButton: View {
    @Bindable var model: WorkbenchModel
    @State private var presented = false
    @State private var projectID: UUID?
    @State private var assetID: UUID?

    var body: some View {
        Button {
            projectID = model.manifest?.id
            assetID = model.selectedAssetID
            model.beginEditing()
            presented = true
        } label: { Label("PNG 配方交接", systemImage: "doc.text.magnifyingglass") }
        .accessibilityIdentifier("png-recipe-handoff")
        .disabled(model.isChangingProject || model.isBusy || model.hasPendingEditor)
        .sheet(isPresented: $presented, onDismiss: { model.endEditing() }) {
            RecipeHandoffView(model: model, expectedProjectID: projectID, assetID: assetID)
        }
    }
}

private struct RecipeHandoffView: View {
    let model: WorkbenchModel
    let expectedProjectID: UUID?
    let assetID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var privateArchive = false
    @State private var prepared: Data?
    @State private var inspection: PNGRecipeInspection?
    @State private var imported = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PNG 配方交接").font(.title2.bold())
            Text("保存带配方的新副本，或离线读取一份 PNG。外部声明仅供参考，不会自动执行或下载模型。")
                .foregroundStyle(.secondary)
            HStack {
                Button("读取 PNG…") { Task { await readPNG() } }
                    .accessibilityIdentifier("read-recipe-png")
                if assetID != nil {
                    Button("从所选作品准备") { Task { await prepare() } }
                        .accessibilityIdentifier("prepare-recipe-png")
                    Toggle("私有归档（包含提示词）", isOn: $privateArchive)
                        .onChange(of: privateArchive) { _, _ in prepared = nil; inspection = nil; imported = false }
                }
            }.disabled(busy)
            if let recipe = inspection?.recipe {
                Text(imported ? "外部文件声明：未经认证" : "导出快照：未经签名认证").font(.headline)
                Text("资产 ID：\(recipe.assetID.uuidString)\n资产版本：\(recipe.assetVersion.uuidString)\n运行 ID：\(recipe.runID.uuidString)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(imported ? "来源字段保持外部声明；不会因此信任模型或文件内链接。" : "资产版本是此次导出新建的快照标识，不是旧项目曾记录的历史版本。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(json(recipe)).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 220).background(.background, in: RoundedRectangle(cornerRadius: 8))
                Text("只有已知提示词和 seed 可恢复为新草稿。其余参数和模型不自动恢复；后续生成须由你明确启动，并使用工作台当前支持的设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("尚无可用配方", systemImage: "doc.questionmark",
                    description: Text("选择所选作品准备导出，或读取一份带 D 配方的 PNG。"))
                    .frame(minHeight: 220)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if imported {
                    Button("作为新草稿") { Task { await createDraft() } }
                        .disabled(busy || !canCreateDraft).accessibilityIdentifier("recipe-new-draft")
                } else {
                    Button("另存 PNG 副本…") { Task { await savePNG() } }
                        .disabled(busy || prepared == nil).accessibilityIdentifier("save-recipe-png")
                }
                Button("完成") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 740, height: 620)
        .interactiveDismissDisabled(busy)
    }

    private var canCreateDraft: Bool {
        guard let recipe = inspection?.recipe, case .value = recipe.prompt,
              expectedProjectID == model.manifest?.id else { return false }
        return true
    }
    private func json(_ recipe: GenerationRecipe) -> String {
        guard let data = try? GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive),
              let value = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "配方无法显示" }
        return text
    }
    private func errorText(_ error: Error) -> String {
        if let error = error as? PNGRecipeError {
            switch error {
            case .privacyConflict: return "图片还带有本工具无法保证隐私的其他元数据。公开导出已拒绝；原件保留。可明确选择私有归档。"
            case .sizeLimitExceeded: return "PNG 或配方超过此版本的读取限制。原件保留。"
            case .unsupportedPNG, .unsupportedRecipe: return "此 PNG 或配方编码尚不支持。没有安装或执行外部内容。"
            case .duplicateRecipe: return "PNG 中有冲突的多份配方，已拒绝读取。"
            case .invalidPNG, .invalidRecipe: return "图片或配方损坏、版本不支持，或摘要／尺寸不一致。原件保留。"
            }
        }
        return error.localizedDescription
    }
    private func prepare() async {
        guard !busy, let assetID, expectedProjectID == model.manifest?.id else { return }
        busy = true; defer { busy = false }
        prepared = nil; inspection = nil; imported = false; message = nil
        do {
            let data = try await model.projectSession.prepareRecipePNG(assetID: assetID,
                disclosure: privateArchive ? .privateArchive : .publicShare)
            guard expectedProjectID == model.manifest?.id else { return }
            inspection = try PNGRecipeCodec.inspect(data); prepared = data
            message = privateArchive ? "将包含提示词。请检查上方实际字段，再另存副本。" : "公开配方已隐藏提示词和结构化输入来源；不会遮盖图像本身。"
        } catch { message = errorText(error) }
    }
    private func savePNG() async {
        guard !busy, let data = prepared else { return }
        busy = true; defer { busy = false }
        let panel = NSSavePanel(); panel.title = "另存带配方的 PNG 副本"
        panel.nameFieldStringValue = "D-recipe-\(UUID().uuidString.prefix(8)).png"
        panel.allowedContentTypes = [.png]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            try await Task.detached { try ProjectStore.publishRecipePNG(data, to: url) }.value
            message = "新副本已保存。原图片和已有同名文件不会被覆盖。"
        } catch { message = errorText(error) }
    }
    private func readPNG() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let panel = NSOpenPanel(); panel.title = "读取 PNG 配方"
        panel.allowedContentTypes = [.png]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        prepared = nil; inspection = nil; imported = true; message = nil
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let (_, result) = try await Task.detached { try ProjectStore.readRecipePNG(at: url) }.value
            inspection = result
            if result.recipe == nil { message = "图片可读取，但没有 D 配方。" }
            else if !canCreateDraft { message = "配方提示词缺失、隐藏或不可用，不能据此恢复新草稿。可查看其余来源字段。" }
            else { message = "已离线读回。原文件保持不变；可以明确创建新草稿。" }
        } catch { message = errorText(error) }
    }
    private func createDraft() async {
        guard !busy, canCreateDraft, let recipe = inspection?.recipe, let expectedProjectID else { return }
        busy = true; defer { busy = false }
        if await model.projectSession.createRecipeDocument(recipe, expectedProjectID: expectedProjectID) {
            message = "已保存独立新草稿，原创作未覆盖。"; dismiss()
        } else { message = model.errorMessage ?? "项目已改变，未应用外部配方。" }
    }
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct LanguageSettingsView: View {
    private let store: UILanguageStore
    @State private var isImporting = false
    @State private var errorMessage: String?

    public init(store: UILanguageStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                Picker(store.text("language.selection", fallback: "显示语言"), selection: selectionBinding) {
                    ForEach(store.availableLanguages) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }
                .accessibilityIdentifier("language-selection")

                LabeledContent(store.text("language.effective", fallback: "当前显示")) {
                    Text(effectiveDisplayName)
                }
            } header: {
                Text(store.text("language.section.display", fallback: "显示"))
            } footer: {
                Text(store.text(
                    "language.display.footer",
                    fallback: "显示语言不会改变模型、参数值、用户内容或执行数据。"
                ))
            }

            Section {
                Button(store.text("language.import.action", fallback: "导入 JSON 语言包…"),
                       systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .accessibilityIdentifier("language-import")

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("language-error")
                }
                ForEach(Array(store.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label(diagnostic, systemImage: "info.circle")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } header: {
                Text(store.text("language.section.packs", fallback: "语言包"))
            } footer: {
                Text(store.text(
                    "language.import.footer",
                    fallback: "仅导入纯 JSON 显示文字；语言包不能运行代码或访问网络。"
                ))
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try LanguagePackFileReader.read(from: url)
                let locale = try store.importPack(data: data)
                try store.select(locale)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .accessibilityIdentifier("language-settings")
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { store.selection },
            set: { identifier in
                do {
                    try store.select(identifier)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var effectiveDisplayName: String {
        store.availableLanguages.first { $0.id == store.effectiveLanguageIdentifier }?.displayName
            ?? store.effectiveLanguageIdentifier
    }
}

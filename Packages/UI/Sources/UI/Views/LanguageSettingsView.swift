import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct LanguageSettingsView: View {
    private let store: UILanguageStore
    @State private var isImporting = false
    @State private var importIssue: LanguageSettingsIssue?

    public init(store: UILanguageStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                WorkbenchPicker(store.text("language.selection", fallback: "显示语言"), selection: selectionBinding) {
                    WorkbenchChoiceForEach(store.availableLanguages) { language in
                        WorkbenchChoice(language.displayName, value:language.id)
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
                Button(store.text("language.import.action", fallback: "导入并使用语言包…"),
                       systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .accessibilityIdentifier("language-import")

                if let importIssue {
                    Label(importIssue.summary(store), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("language-error")
                    DisclosureGroup(store.text("error.original", fallback: "Original diagnostic")) {
                        Text(importIssue.diagnostic).textSelection(.enabled)
                    }
                }
                ForEach(Array(store.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label(diagnostic.summary(store), systemImage: "info.circle")
                        .font(.caption)
                        .textSelection(.enabled)
                    if !diagnostic.technicalDetails.isEmpty {
                        DisclosureGroup(store.text("error.original", fallback: "Original diagnostic")) {
                            Text(diagnostic.technicalDetails).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text(store.text("language.section.packs", fallback: "语言包"))
            } footer: {
                Text(store.text(
                    "language.import.footer",
                    fallback: "选择 JSON 格式的语言包。导入成功后，界面会立即切换为该语言。语言包只提供界面文字，不能运行代码或访问网络。"
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
                importIssue = nil
            } catch {
                importIssue = LanguageSettingsIssue(error)
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
                } catch {
                    importIssue = LanguageSettingsIssue(error)
                }
            }
        )
    }

    private var effectiveDisplayName: String {
        store.availableLanguages.first { $0.id == store.effectiveLanguageIdentifier }?.displayName
            ?? store.effectiveLanguageIdentifier
    }
}

/// Keeps the typed cause and arguments across display-language changes.
struct LanguageSettingsIssue {
    let diagnostic: String
    let key: String
    let arguments: [String: String]
    init(_ error: any Error) {
        diagnostic = error.localizedDescription
        var argument: String?
        let suffix: String
        switch error {
        case let value as LanguagePackValidationError:
            switch value {
            case .tooLarge: suffix = "tooLarge"
            case .invalidUTF8: suffix = "invalidUTF8"
            case .invalidJSON: suffix = "invalidJSON"
            case .unsupportedVersion(let value): suffix = "unsupportedVersion"; argument = String(value)
            case .invalidLocale: suffix = "invalidLocale"
            case .invalidDisplayName: suffix = "invalidDisplayName"
            case .tooManyEntries: suffix = "tooManyEntries"
            case .invalidKey(let value): suffix = "invalidKey"; argument = value
            case .valueTooLong(let value): suffix = "valueTooLong"; argument = value
            case .invalidPlaceholder(let value): suffix = "invalidPlaceholder"; argument = value
            case .placeholderMismatch(let value): suffix = "placeholderMismatch"; argument = value
            case .invalidLocalFile: suffix = "invalidLocalFile"
            case .nonLocalFile: suffix = "nonLocalFile"
            case .changedWhileReading: suffix = "changedWhileReading"
            }
        case let value as UILanguageError:
            switch value {
            case .unavailableLanguage(let value): suffix = "unavailableLanguage"; argument = value
            case .builtInLocale(let value): suffix = "builtInLocale"; argument = value
            case .reservedLocale(let value): suffix = "reservedLocale"; argument = value
            case .duplicateLocale(let value): suffix = "duplicateLocale"; argument = value
            case .persistenceFailed: suffix = "persistenceFailed"
            }
        default: suffix = "fileReadFailed"
        }
        key = "language.error." + suffix
        arguments = argument.map { ["value": $0] } ?? [:]
    }
    @MainActor func summary(_ store: UILanguageStore) -> String { store.text(key, fallback: diagnostic, arguments: arguments) }
}

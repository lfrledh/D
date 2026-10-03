import DWorkbench
import Foundation
import Observation
import SwiftUI

enum ChatArtifactEditorError: LocalizedError, Equatable {
    case returnedContentMismatch
    case missingPublishedOutput
    case csv(String)
    case mermaidUnavailable

    var errorDescription: String? {
        switch self {
        case .returnedContentMismatch: "The saved artifact did not match the submitted version."
        case .missingPublishedOutput: "The saved artifact has no published output asset."
        case .csv(let detail): "CSV preview: \(detail)"
        case .mermaidUnavailable: "Mermaid preview is unavailable: no local renderer was provided."
        }
    }
}

struct ChatArtifactPreview: Equatable {
    let kind: ChatArtifactContent.Kind
    let text: String
    let webDocument: String?
    let javaScriptEnabled: Bool
}

private func sameUTF8(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

@MainActor
@Observable
final class ChatArtifactEditorState {
    private(set) var baseline: ChatArtifactContent
    private(set) var draft: ChatArtifactContent
    private(set) var isSaving = false
    private(set) var isPreviewing = false
    private(set) var preview: ChatArtifactPreview?
    private(set) var previewNeedsRefresh = false
    private(set) var javaScriptEnabled = false
    var issue: String?
    var previewIssue: String?
    var asksToDiscard = false
    private var editGeneration: UInt64 = 0

    init(content: ChatArtifactContent) {
        baseline = content
        draft = content
    }

    var isDirty: Bool {
        !sameUTF8(draft.title, baseline.title) || draft.kind != baseline.kind
            || !sameUTF8(draft.text, baseline.text)
    }

    var canSave: Bool { !isSaving && (isDirty || baseline.output == nil) }

    func updateTitle(_ value: String) {
        guard !sameUTF8(draft.title, value) else { return }
        draft.title = value
        editGeneration &+= 1
    }

    func updateKind(_ value: ChatArtifactContent.Kind) {
        guard draft.kind != value else { return }
        draft.kind = value
        javaScriptEnabled = false
        preview = nil
        previewIssue = nil
        previewNeedsRefresh = true
        editGeneration &+= 1
    }

    func updateText(_ value: String) {
        guard !sameUTF8(draft.text, value) else { return }
        draft.text = value
        // A previously enabled script never follows a changed source automatically.
        javaScriptEnabled = false
        preview = nil
        previewIssue = nil
        previewNeedsRefresh = true
        editGeneration &+= 1
    }

    func setJavaScriptEnabled(_ enabled: Bool) {
        guard draft.kind == .html || draft.kind == .svg else { return }
        guard javaScriptEnabled != enabled else { return }
        javaScriptEnabled = enabled
        preview = nil
        previewIssue = nil
        previewNeedsRefresh = true
    }

    func togglePreview(mermaidDocument: ((String) throws -> String)?) {
        isPreviewing.toggle()
        if isPreviewing {
            refreshPreview(mermaidDocument: mermaidDocument)
        } else {
            javaScriptEnabled = false
            preview = nil
            previewIssue = nil
        }
    }

    func refreshPreview(mermaidDocument: ((String) throws -> String)?) {
        do {
            try draft.validate()
            let webDocument: String?
            let scripts: Bool
            switch draft.kind {
            case .plainText, .markdown, .code:
                webDocument = nil
                scripts = false
            case .csv:
                webDocument = try ChatArtifactCSVPreview.document(draft.text)
                scripts = false
            case .html, .svg:
                webDocument = draft.text
                scripts = javaScriptEnabled
            case .mermaid:
                guard let mermaidDocument else { throw ChatArtifactEditorError.mermaidUnavailable }
                webDocument = try mermaidDocument(draft.text)
                scripts = true
            }
            if let webDocument, webDocument.utf8.count > ChatArtifactContent.maximumSourceBytes {
                throw ChatArtifactContent.ValidationError.sourceTooLarge
            }
            preview = ChatArtifactPreview(kind: draft.kind, text: draft.text,
                                          webDocument: webDocument, javaScriptEnabled: scripts)
            previewNeedsRefresh = false
            previewIssue = nil
        } catch {
            preview = nil
            previewIssue = error.localizedDescription
        }
    }

    func requestClose(_ close: () -> Void) {
        guard !isSaving else { return }
        if isDirty { asksToDiscard = true } else { close() }
    }

    func discardAndClose(_ close: () -> Void) {
        guard !isSaving else { return }
        asksToDiscard = false
        close()
    }

    func save(using onSave: @MainActor (ChatArtifactContent) async throws -> ChatArtifactContent) async {
        guard canSave else { return }
        isSaving = true
        issue = nil
        let submittedGeneration = editGeneration
        do {
            // Existing published content gets a new version. An unpublished artifact
            // keeps its initial revision until its first successful publication.
            var submitted = baseline
            submitted.title = draft.title
            submitted.kind = draft.kind
            submitted.text = draft.text
            try submitted.validate()
            if baseline.output != nil { submitted = try submitted.revised() }
            let saved = try await onSave(submitted)
            try saved.validate()
            guard saved.output != nil else { throw ChatArtifactEditorError.missingPublishedOutput }
            guard saved.id == submitted.id, saved.sessionID == submitted.sessionID,
                  saved.revision == submitted.revision, saved.source == submitted.source,
                  sameUTF8(saved.title, submitted.title), saved.kind == submitted.kind,
                  sameUTF8(saved.text, submitted.text) else {
                throw ChatArtifactEditorError.returnedContentMismatch
            }
            baseline = saved
            if editGeneration == submittedGeneration {
                draft = saved
            } else {
                // Keep edits made during the await, but take the returned identity,
                // revision and published asset as the next edit's baseline.
                var current = saved
                current.title = draft.title
                current.kind = draft.kind
                current.text = draft.text
                draft = current
            }
        } catch {
            issue = error.localizedDescription
        }
        isSaving = false
    }
}

/// Native editor for a single reusable chat artifact. The owner supplies persistence.
@MainActor
struct ChatArtifactEditor: View {
    let mermaidDocument: ((String) throws -> String)?
    let onSave: @MainActor (ChatArtifactContent) async throws -> ChatArtifactContent
    let onClose: @MainActor () -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var state: ChatArtifactEditorState

    init(content: ChatArtifactContent,
         mermaidDocument: ((String) throws -> String)? = nil,
         onSave: @MainActor @escaping (ChatArtifactContent) async throws -> ChatArtifactContent,
         onClose: @MainActor @escaping () -> Void) {
        self.mermaidDocument = mermaidDocument
        self.onSave = onSave
        self.onClose = onClose
        _state = State(initialValue: ChatArtifactEditorState(content: content))
    }

    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }

    private func kindName(_ kind: ChatArtifactContent.Kind) -> String {
        switch kind {
        case .plainText: wording("Plain text", "纯文本")
        case .markdown: "Markdown"
        case .code: wording("Code", "代码")
        case .csv: "CSV"
        case .html: "HTML"
        case .svg: "SVG"
        case .mermaid: "Mermaid"
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(wording("Artifact", "成果")).font(.title2)
                Spacer()
                Text(wording("Revision \(state.baseline.revision)", "版本 \(state.baseline.revision)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField(wording("Title", "标题"), text: Binding(
                get: { state.draft.title }, set: { state.updateTitle($0) }))
                .accessibilityIdentifier("chat-artifact-title")
            Picker(wording("Format", "格式"), selection: Binding(
                get: { state.draft.kind }, set: { state.updateKind($0) })) {
                ForEach(ChatArtifactContent.Kind.allCases, id: \.self) { kind in
                    Text(kindName(kind)).tag(kind)
                }
            }.accessibilityIdentifier("chat-artifact-kind")
            HStack {
                Text(wording("Source", "源内容"))
                Spacer()
                Text("\(state.draft.text.utf8.count) / \(ChatArtifactContent.maximumSourceBytes) UTF-8")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextSourcesQuestionEditor(value: state.draft.text, editEpoch: 0, isEditable: true,
                accessibilityIdentifier: "chat-artifact-source", onEdit: { state.updateText($0) })
                .frame(height: 240)
            HStack {
                Toggle(wording("Preview", "预览"), isOn: Binding(
                    get: { state.isPreviewing },
                    set: { _ in state.togglePreview(mermaidDocument: mermaidDocument) }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("chat-artifact-preview-toggle")
                if state.isPreviewing {
                    Button(wording("Refresh preview", "刷新预览")) {
                        state.refreshPreview(mermaidDocument: mermaidDocument)
                    }.accessibilityIdentifier("chat-artifact-preview-refresh")
                    if state.previewNeedsRefresh {
                        Text(wording("Source changed; refresh to preview.", "源内容已更改；刷新后预览。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if state.isPreviewing && (state.draft.kind == .html || state.draft.kind == .svg) {
                Toggle(wording("Allow local JavaScript for this preview", "允许本次预览运行本地 JavaScript"),
                       isOn: Binding(get: { state.javaScriptEnabled },
                                     set: { state.setJavaScriptEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("chat-artifact-javascript")
            }
            if state.isPreviewing && (state.draft.kind == .html || state.draft.kind == .svg || state.draft.kind == .mermaid) {
                Text(wording("Local preview only. Network and file access are not allowed. Mermaid uses the supplied local renderer and runs its JavaScript on explicit preview.",
                             "仅限本地预览；不允许网络与文件访问。Mermaid 使用提供的本地渲染器，并在明确预览时运行其 JavaScript。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.isPreviewing {
                if let preview = state.preview {
                    previewView(preview)
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .accessibilityIdentifier("chat-artifact-preview")
                }
                if let error = state.previewIssue {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("chat-artifact-preview-error")
                }
            }
            if let issue = state.issue {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("chat-artifact-save-error")
            }
            HStack {
                Spacer()
                Button(wording("Close", "关闭")) { state.requestClose(onClose) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isSaving)
                    .accessibilityIdentifier("chat-artifact-close")
                Button(wording("Save new version", "保存新版本")) {
                    Task { await state.save(using: onSave) }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.canSave)
                .accessibilityIdentifier("chat-artifact-save")
            }
        }
        .padding(16)
        }
        .frame(minWidth: 640, minHeight: 560)
        .interactiveDismissDisabled(state.isDirty || state.isSaving)
        .confirmationDialog(wording("Discard unsaved edits?", "放弃未保存的修改？"),
                            isPresented: $state.asksToDiscard) {
            Button(wording("Discard edits", "放弃修改"), role: .destructive) {
                state.discardAndClose(onClose)
            }
            Button(wording("Keep editing", "继续编辑"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func previewView(_ preview: ChatArtifactPreview) -> some View {
        switch preview.kind {
        case .plainText, .code:
            ScrollView { Text(preview.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8) }
        case .markdown:
            ScrollView {
                ChatMarkdownView(messageID: state.baseline.id, text: preview.text,
                                 rawText: preview.text, isStreaming: false)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        case .csv, .html, .svg, .mermaid:
            if let document = preview.webDocument {
                ChatArtifactWebPreview(source: document, javaScriptEnabled: preview.javaScriptEnabled,
                    bundledLibrary: preview.kind == .mermaid ? .mermaid : nil) { error in
                    state.previewIssue = String(describing: error)
                }
            }
        }
    }
}

/// Strict CSV parsing for a bounded, inert HTML table. No rows are silently omitted.
@MainActor
enum ChatArtifactCSVPreview {
    private enum FieldState { case start, unquoted, quoted, closed }
    static let maximumRows = 200
    static let maximumColumns = 64

    static func document(_ source: String) throws -> String {
        guard source.utf8.count <= ChatArtifactContent.maximumSourceBytes else {
            throw ChatArtifactEditorError.csv("Source exceeds 1 MiB of UTF-8.")
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var state: FieldState = .start
        var endedWithSeparator = false

        func finishField() throws {
            row.append(field)
            guard row.count <= maximumColumns else {
                throw ChatArtifactEditorError.csv("More than \(maximumColumns) columns.")
            }
            field = ""
            state = .start
        }
        func finishRow() throws {
            try finishField()
            rows.append(row)
            guard rows.count <= maximumRows else {
                throw ChatArtifactEditorError.csv("More than \(maximumRows) rows.")
            }
            row = []
        }
        var skipLF = false
        for scalar in source.unicodeScalars {
            if skipLF {
                skipLF = false
                if scalar == "\n" { continue }
            }
            let separator = scalar == "\n" || scalar == "\r"
            switch state {
            case .start:
                if scalar == "\"" { state = .quoted; endedWithSeparator = false }
                else if scalar == "," { try finishField(); endedWithSeparator = false }
                else if separator { try finishRow(); endedWithSeparator = true; skipLF = scalar == "\r" }
                else { field.append(String(scalar)); state = .unquoted; endedWithSeparator = false }
            case .unquoted:
                if scalar == "\"" { throw ChatArtifactEditorError.csv("Unexpected quote in an unquoted field.") }
                else if scalar == "," { try finishField(); endedWithSeparator = false }
                else if separator { try finishRow(); endedWithSeparator = true; skipLF = scalar == "\r" }
                else { field.append(String(scalar)); endedWithSeparator = false }
            case .quoted:
                if scalar == "\"" { state = .closed }
                else { field.append(String(scalar)) }
                endedWithSeparator = false
            case .closed:
                if scalar == "\"" { field.append("\""); state = .quoted; endedWithSeparator = false }
                else if scalar == "," { try finishField(); endedWithSeparator = false }
                else if separator { try finishRow(); endedWithSeparator = true; skipLF = scalar == "\r" }
                else { throw ChatArtifactEditorError.csv("Unexpected character after a quoted field.") }
            }
        }
        if state == .quoted { throw ChatArtifactEditorError.csv("Unclosed quoted field.") }
        if !source.isEmpty && !endedWithSeparator { try finishRow() }

        var html = "<style>table{border-collapse:collapse;width:100%}td{border:1px solid #888;padding:4px;white-space:pre-wrap;vertical-align:top}</style><table>"
        for row in rows {
            html += "<tr>"
            for cell in row { html += "<td>\(escape(cell))</td>" }
            html += "</tr>"
            guard html.utf8.count <= ChatArtifactContent.maximumSourceBytes else {
                throw ChatArtifactEditorError.csv("Escaped table exceeds 1 MiB.")
            }
        }
        html += "</table>"
        guard html.utf8.count <= ChatArtifactContent.maximumSourceBytes else {
            throw ChatArtifactEditorError.csv("Escaped table exceeds 1 MiB.")
        }
        return html
    }

    private static func escape(_ source: String) -> String {
        var escaped = ""
        for scalar in source.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(String(scalar))
            }
        }
        return escaped
    }
}

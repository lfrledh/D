import AppKit
import DWorkbench
import Foundation
import SwiftUI

/// Operations are supplied by the owning project session. This view never reads a
/// source file, opens a panel, saves a project, or starts a model itself.
public struct TextSourcesViewActions {
    public let importSource: () -> Void
    public let removeSource: (UUID) -> Void
    public let useExcerpt: (UUID, NSRange?) -> Void
    public let changeQuestion: (String) -> Void
    public let ask: () -> Void
    public let cancel: () -> Void
    public let accept: (UUID) -> Void
    public let reject: (UUID) -> Void
    public let undo: () -> Void
    public let save: () -> Void

    public init(importSource: @escaping () -> Void, removeSource: @escaping (UUID) -> Void,
                useExcerpt: @escaping (UUID, NSRange?) -> Void,
                changeQuestion: @escaping (String) -> Void, ask: @escaping () -> Void,
                cancel: @escaping () -> Void, accept: @escaping (UUID) -> Void,
                reject: @escaping (UUID) -> Void, undo: @escaping () -> Void,
                save: @escaping () -> Void) {
        self.importSource = importSource
        self.removeSource = removeSource
        self.useExcerpt = useExcerpt
        self.changeQuestion = changeQuestion
        self.ask = ask
        self.cancel = cancel
        self.accept = accept
        self.reject = reject
        self.undo = undo
        self.save = save
    }
}

/// Keeps a native text selection tied to the exact source revision that displayed it.
/// A selection from an older source can therefore never be sent to a replacement source.
struct TextSourcesSelectionState: Equatable {
    private(set) var sourceID: UUID?
    private(set) var sourceRevision: UUID?
    private(set) var range = NSRange(location: NSNotFound, length: 0)

    mutating func select(_ source: TextSourceSnapshot?) {
        guard sourceID != source?.id || sourceRevision != source?.revision else { return }
        sourceID = source?.id
        sourceRevision = source?.revision
        range = NSRange(location: NSNotFound, length: 0)
    }

    mutating func record(_ range: NSRange, for source: TextSourceSnapshot) {
        guard sourceID == source.id, sourceRevision == source.revision,
              (try? TextSourceExcerpt(source: source, range: range)) != nil else {
            self.range = NSRange(location: NSNotFound, length: 0)
            return
        }
        self.range = range
    }

    func excerptRange(for source: TextSourceSnapshot) -> NSRange? {
        guard sourceID == source.id, sourceRevision == source.revision,
              (try? TextSourceExcerpt(source: source, range: range)) != nil else { return nil }
        return range
    }
}

/// A selectable, non-editable AppKit view. It only reports a valid selection.
private struct TextSourcesReadOnlyTextView: NSViewRepresentable {
    let source: TextSourceSnapshot
    let selection: NSRange?
    let onSelection: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        context.coordinator.update(source: source, selection: selection, textView: textView, onSelection: onSelection)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(source: source, selection: selection, textView: textView, onSelection: onSelection)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var sourceID: UUID?
        private var sourceRevision: UUID?
        private var suppress = false
        private var onSelection: ((NSRange) -> Void)?

        func update(source: TextSourceSnapshot, selection: NSRange?, textView: NSTextView,
                    onSelection: @escaping (NSRange) -> Void) {
            self.onSelection = onSelection
            let changedSource = sourceID != source.id || sourceRevision != source.revision
            if changedSource {
                suppress = true
                textView.string = (try? source.validatedText()) ?? ""
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                suppress = false
                sourceID = source.id
                sourceRevision = source.revision
            }
            if let selection, (try? TextSourceExcerpt(source: source, range: selection)) != nil {
                suppress = true
                textView.setSelectedRange(selection)
                suppress = false
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppress, let textView = notification.object as? NSTextView else { return }
            onSelection?(textView.selectedRange())
        }
    }
}

/// Independent read-only source and answer panel for the existing text workbench.
@MainActor
public struct TextSourcesView: View {
    private let notebook: TextSourcesNotebook
    private let partialAnswer: String
    private let isRunning: Bool
    private let isCancelling: Bool
    private let isSaving: Bool
    private let canAsk: Bool
    private let canUndo: Bool
    private let errorMessage: String?
    private let canAccept: (TextSourceAnswerRecord) -> Bool
    private let citationSummary: (TextSourceAnswerRecord) -> String
    private let actions: TextSourcesViewActions
    @State private var selectedSourceID: UUID?
    @State private var selection = TextSourcesSelectionState()
    @State private var question: String

    public init(notebook: TextSourcesNotebook, partialAnswer: String, isRunning: Bool,
                isCancelling: Bool, isSaving: Bool, canAsk: Bool, canUndo: Bool,
                errorMessage: String?, canAccept: @escaping (TextSourceAnswerRecord) -> Bool,
                citationSummary: @escaping (TextSourceAnswerRecord) -> String,
                actions: TextSourcesViewActions) {
        self.notebook = notebook
        self.partialAnswer = partialAnswer
        self.isRunning = isRunning
        self.isCancelling = isCancelling
        self.isSaving = isSaving
        self.canAsk = canAsk
        self.canUndo = canUndo
        self.errorMessage = errorMessage
        self.canAccept = canAccept
        self.citationSummary = citationSummary
        self.actions = actions
        _question = State(initialValue: notebook.question)
    }

    public var body: some View {
        GeometryReader { viewport in
            let isNarrow = viewport.size.width < 760
            let panels = isNarrow ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            VStack(spacing: 0) {
                toolbar(compact: viewport.size.width < 620)
                Divider()
                panels {
                    sourcesPanel.frame(minWidth: 0, maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
                    Divider()
                    answersPanel.frame(minWidth: 0, maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Any persisted notebook revision can replace sources. Reset the local native
        // selection rather than allowing an old range to target a new source/version.
        .onChange(of: notebook.revision) { _, _ in
            if !question.utf8.elementsEqual(notebook.question.utf8) { question = notebook.question }
            selection.select(nil)
            selectedSourceID = nil
        }
    }

    private func toolbar(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("资料问答").font(.headline)
                Text("引用标记仅核对本次提交的资料位置，不验证事实。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button(action: actions.undo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.glass).disabled(!canUndo || isSaving).accessibilityIdentifier("text-sources-undo")
                Button(action: actions.save) { Label(isSaving ? "正在保存" : "保存", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.glass).disabled(isSaving).accessibilityIdentifier("text-sources-save")
            }.fixedSize(horizontal: true, vertical: false)
        }
        .padding(12).background(.bar)
    }

    private var sourcesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("资料").font(.headline)
                    Spacer()
                    Button(action: actions.importSource) { Label("导入资料", systemImage: "plus") }
                        .buttonStyle(.glass).disabled(isSaving).accessibilityIdentifier("text-sources-import")
                }
                if notebook.sources.isEmpty {
                    ContentUnavailableView("尚无资料", systemImage: "doc.text", description: Text("导入本地文字资料后可以提问。"))
                } else {
                    Picker("当前资料", selection: $selectedSourceID) {
                        Text("选择资料").tag(Optional<UUID>.none)
                        ForEach(notebook.sources) { source in Text(source.displayName).tag(Optional(source.id)) }
                    }
                    .onChange(of: selectedSourceID) { _, id in selection.select(notebook.sources.first { $0.id == id }) }
                    if let source = selectedSource {
                        sourceDetail(source)
                    }
                }
            }.padding(16)
        }
        .accessibilityIdentifier("text-sources-panel")
    }

    @ViewBuilder private func sourceDetail(_ source: TextSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.displayName).font(.subheadline.weight(.semibold))
            Text("原始资料只读；可选择一段文字作为本次提交的资料。")
                .font(.caption).foregroundStyle(.secondary)
            TextSourcesReadOnlyTextView(source: source, selection: selection.excerptRange(for: source)) { range in
                selection.record(range, for: source)
            }
            .frame(minHeight: 220, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
            .accessibilityIdentifier("text-sources-source-text")
            HStack {
                Button("使用全文") { actions.useExcerpt(source.id, nil) }
                    .buttonStyle(.glass).disabled(isSaving)
                    .accessibilityIdentifier("text-sources-use-full")
                Button("使用选中片段") { actions.useExcerpt(source.id, selection.excerptRange(for: source)) }
                    .buttonStyle(.glass).disabled(isSaving || selection.excerptRange(for: source) == nil)
                    .accessibilityIdentifier("text-sources-use-selection")
                Spacer()
                Button(role: .destructive, action: { actions.removeSource(source.id) }) { Label("移除资料", systemImage: "trash") }
                    .buttonStyle(.glass).disabled(isSaving).accessibilityIdentifier("text-sources-remove")
            }
        }
    }

    private var selectedSource: TextSourceSnapshot? {
        notebook.sources.first { $0.id == selectedSourceID }
    }

    private var answersPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("问题与回答").font(.headline)
                TextEditor(text: Binding(get: { question }, set: { value in
                    question = value
                    actions.changeQuestion(value)
                }))
                .font(.body).frame(minHeight: 90).disabled(isSaving)
                .accessibilityIdentifier("text-sources-question")
                HStack {
                    Button(action: actions.ask) { Label("生成", systemImage: "sparkles") }
                        .buttonStyle(.glass).disabled(!canAsk || isRunning || isSaving)
                        .accessibilityIdentifier("text-sources-ask")
                    Button(action: actions.cancel) { Label("取消", systemImage: "xmark") }
                        .buttonStyle(.glass).disabled(!isRunning || isCancelling)
                        .accessibilityIdentifier("text-sources-cancel")
                    Spacer()
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("text-sources-error")
                }
                if !partialAnswer.isEmpty {
                    answerBlock(title: "正在生成", answer: partialAnswer, summary: "结果尚未完成，不能采用。")
                }
                ForEach(notebook.records) { record in recordBlock(record) }
            }.padding(16)
        }
        .accessibilityIdentifier("text-sources-answers-panel")
    }

    private func answerBlock(title: String, answer: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(answer).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func recordBlock(_ record: TextSourceAnswerRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.disposition.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(record.answer).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(citationSummary(record)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            submittedExcerpts(record.submission.excerpts)
            HStack {
                Button("采用") { actions.accept(record.id) }
                    .buttonStyle(.glass).disabled(!canAccept(record) || isRunning || isSaving)
                    .accessibilityIdentifier("text-sources-accept-\(record.id.uuidString)")
                Button("拒绝") { actions.reject(record.id) }
                    .buttonStyle(.glass).disabled(isSaving)
                    .accessibilityIdentifier("text-sources-reject-\(record.id.uuidString)")
            }
        }
        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func submittedExcerpts(_ excerpts: [TextSourceExcerpt]) -> some View {
        if !excerpts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("本次提交的资料片段").font(.caption.weight(.semibold))
                ForEach(excerpts) { excerpt in Text(excerpt.text).font(.caption).textSelection(.enabled) }
            }
        }
    }
}

import DWorkbench
import Foundation
import SwiftUI

/// Presentation for a text draft. Business operations remain owned by the caller.
@MainActor
public struct TextWorkbenchView: View {
    @Bindable private var session: TextDraftSession
    private let selection: NSRange
    @Binding private var instruction: String
    private let modelStatus: String
    private let canGenerate: Bool
    private let canAccept: Bool
    private let canUndo: Bool
    private let isSaving: Bool
    private let saveStatus: String
    private let onEdit: (String) -> Void
    private let onSelection: (NSRange) -> Void
    private let onGenerate: () -> Void
    private let onCancel: () -> Void
    private let onAccept: () -> Void
    private let onReject: () -> Void
    private let onUndo: () -> Void
    private let onSave: () -> Void
    private let onChooseModel: () -> Void

    public init(session: TextDraftSession, selection: NSRange, instruction: Binding<String>, modelStatus: String,
                canGenerate: Bool, canAccept: Bool, canUndo: Bool, isSaving: Bool, saveStatus: String,
                onEdit: @escaping (String) -> Void, onSelection: @escaping (NSRange) -> Void,
                onGenerate: @escaping () -> Void, onCancel: @escaping () -> Void,
                onAccept: @escaping () -> Void, onReject: @escaping () -> Void,
                onUndo: @escaping () -> Void, onSave: @escaping () -> Void,
                onChooseModel: @escaping () -> Void) {
        self.session = session
        self.selection = selection
        _instruction = instruction
        self.modelStatus = modelStatus
        self.canGenerate = canGenerate
        self.canAccept = canAccept
        self.canUndo = canUndo
        self.isSaving = isSaving
        self.saveStatus = saveStatus
        self.onEdit = onEdit
        self.onSelection = onSelection
        self.onGenerate = onGenerate
        self.onCancel = onCancel
        self.onAccept = onAccept
        self.onReject = onReject
        self.onUndo = onUndo
        self.onSave = onSave
        self.onChooseModel = onChooseModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                editorPanel
                    .frame(minWidth: 360, minHeight: 360)
                comparisonPanel
                    .frame(minWidth: 300, minHeight: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("文字草稿").font(.headline)
                Text(modelStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("text-model-status")
            }
            Spacer()
            Button(action: onChooseModel) { Label("选择模型", systemImage: "cube.transparent") }
                .buttonStyle(.glass)
                .accessibilityIdentifier("text-model-select")
            Button(action: onUndo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                .disabled(!canUndo).accessibilityIdentifier("text-undo")
            Button(action: onSave) { Label(isSaving ? "正在保存" : "保存", systemImage: "square.and.arrow.down") }
                .disabled(isSaving).accessibilityIdentifier("text-save")
        }
        .padding(12)
        .background(.bar)
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("原稿").font(.headline)
            TextSelectionEditor(document: session.document, selection: selection, onEdit: onEdit, onSelection: onSelection)
                .accessibilityIdentifier("text-draft-editor")
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
            Text("选中文字后描述修改意图").font(.caption).foregroundStyle(.secondary)
            TextField("修改要求", text: $instruction, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("text-instruction")
            HStack {
                Button(action: onGenerate) { Label("改写", systemImage: "sparkles") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canGenerate || session.isRunning)
                    .accessibilityIdentifier("text-rewrite")
                Button(action: onCancel) { Label("取消", systemImage: "xmark") }
                    .disabled(!session.isRunning || session.isCancelling)
                    .accessibilityIdentifier("text-cancel")
                Spacer()
                Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("text-save-status")
            }
        }
        .padding(16)
    }

    private var comparisonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选段与候选").font(.headline)
            GroupBox("原选段") {
                Text(selectedText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            GroupBox("替换候选") {
                candidateContent.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .accessibilityIdentifier("text-candidate-output")
            }
            if session.candidate != nil && !canAccept {
                Label("原稿或选区已改变，不能接受此候选。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("接受", action: onAccept).disabled(!canAccept).accessibilityIdentifier("text-accept")
                Button("拒绝", action: onReject).disabled(session.candidate == nil).accessibilityIdentifier("text-reject")
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    private var selectedText: String {
        guard (try? TextRewriteSelection(document: session.document, range: selection)) != nil,
              let range = Range(selection, in: session.document.text) else {
            return "请在原稿中选择要改写的文字。"
        }
        return String(session.document.text[range])
    }

    @ViewBuilder private var candidateContent: some View {
        if session.isRunning {
            if session.partialText.isEmpty {
                Label("正在生成候选…", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            } else {
                Text(session.partialText)
            }
        } else if let candidate = session.candidate {
            Text(candidate.replacement)
        } else {
            Text("尚无候选。改写结果会在此处显示，原稿不会被自动替换。")
                .foregroundStyle(.secondary)
        }
    }
}

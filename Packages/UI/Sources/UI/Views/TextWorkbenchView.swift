import DInference
import DWorkbench
import Foundation
import SwiftUI

public enum TextWorkbenchPresentation: Sendable { case complete, editor, parameters }

/// Presentation for a text draft. Business operations remain owned by the caller.
@MainActor
public struct TextWorkbenchView: View {
    private var presentation: TextWorkbenchPresentation = .complete
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
    private var generationCapability: TextExecutionCapability?
    private var generationRecommendation: ExecutionRecommendations?
    private var generationConfigurationError: String?
    private var onGenerationSettingsChange: ((TextGenerationSettings) -> Void)?

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

    public func presenting(_ presentation: TextWorkbenchPresentation) -> Self {
        var copy = self; copy.presentation = presentation; return copy
    }

    public func generationControls(capability: TextExecutionCapability?, recommendation: ExecutionRecommendations?, configurationError: String?, onChange: @escaping (TextGenerationSettings) -> Void) -> Self {
        var copy = self
        copy.generationCapability = capability
        copy.generationRecommendation = recommendation
        copy.generationConfigurationError = configurationError
        copy.onGenerationSettingsChange = onChange
        return copy
    }

    public var body: some View {
      if presentation == .parameters {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("改写参数").font(.headline)
                Text(modelStatus).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("text-model-status")
                Button("选择文字模型…", action: onChooseModel).accessibilityIdentifier("text-model-select")
                rewriteControls
            }.padding(16)
        }
      } else {
        GeometryReader { viewport in
            // AnyLayout changes arrangement without replacing the native IME editor.
            let panels = viewport.size.width < 760
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 0))
            VStack(spacing: 0) {
                toolbar(compact: viewport.size.width < 680)
                Divider()
                panels {
                    editorPanel
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    Divider()
                    comparisonPanel
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
      }
    }

    private func toolbar(compact: Bool) -> some View {
        let arrangement = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        return arrangement {
            VStack(alignment: .leading, spacing: 2) {
                Text("文字草稿").font(.headline)
                if presentation == .complete {
                    Text(modelStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("text-model-status")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if presentation == .complete {
                    Button(action: onChooseModel) { Label("选择模型", systemImage: "cube.transparent") }
                        .buttonStyle(.glass).accessibilityIdentifier("text-model-select")
                }
                Button(action: onUndo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .disabled(!canUndo).accessibilityIdentifier("text-undo")
                Button(action: onSave) { Label(isSaving ? "正在保存" : "保存", systemImage: "square.and.arrow.down") }
                    .disabled(isSaving).accessibilityIdentifier("text-save")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(12)
        .background(.bar)
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("原稿").font(.headline)
            TextSelectionEditor(document: session.document, selection: selection, onEdit: onEdit, onSelection: onSelection)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .accessibilityIdentifier("text-draft-editor")
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
            if presentation == .complete { rewriteControls }
            else { Text(saveStatus).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("text-save-status") }

        }
        .padding(16)
    }

    private var rewriteControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            generationSettingsControls
            Text("选中文字后描述修改意图").font(.caption).foregroundStyle(.secondary)
            TextField("修改要求", text: $instruction, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("text-instruction")
            HStack {
                Button(action: generate) { Label("改写", systemImage: "sparkles") }
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
    }

    @ViewBuilder private var generationSettingsControls: some View {
        if let capability = generationCapability {
            VStack(alignment: .leading, spacing: 8) {
                Text("生成额度").font(.subheadline.weight(.semibold))
                Text("输入 token 上限").font(.caption).foregroundStyle(.secondary)
                TextField("输入 token 上限", value: promptTokenLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("输入 token 上限")
                    .accessibilityIdentifier("text-input-limit")
                Text("输出 token 上限").font(.caption).foregroundStyle(.secondary)
                TextField("输出 token 上限", value: outputTokenLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("输出 token 上限")
                    .accessibilityIdentifier("text-output-limit")
                Text("Token 不是字数；输入包括改写包装和模板。真实超限会报错，原文不会被截断。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("当前能力支持：输入最多 \(capability.maximumPromptTokens) token，输出最多 \(capability.maximumOutputTokens) token。")
                    .font(.caption).foregroundStyle(.secondary)
                if let recommendation = generationRecommendation {
                    Text("这是依据当前内存的未实测起始建议：输入 \(recommendation.maximumPromptTokens)，输出 \(recommendation.maximumOutputTokens)；不代表已验证能力或保证当前准入，也不会改变当前设置。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if capability.maximumPromptTokens >= 2048, capability.maximumOutputTokens >= 256 {
                    Button("重设为短文本预设（2048 / 256）") {
                        publishGenerationSettings(.init(maximumPromptTokens: 2048, maximumOutputTokens: 256,
                            profile: capability.profile))
                    }
                    .controlSize(.small)
                }
                if let error = generationConfigurationError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("text-settings-error")
                }
            }
            .accessibilityIdentifier("text-parameter-section")
        }
    }

    private var promptTokenLimit: Binding<Int> {
        Binding(get: { session.document.generationSettings.maximumPromptTokens }, set: { value in
            publishGenerationSettings(Self.settings(session.document.generationSettings, maximumPromptTokens: value))
        })
    }

    private var outputTokenLimit: Binding<Int> {
        Binding(get: { session.document.generationSettings.maximumOutputTokens }, set: { value in
            publishGenerationSettings(Self.settings(session.document.generationSettings, maximumOutputTokens: value))
        })
    }

    static func settings(_ current: TextGenerationSettings, maximumPromptTokens: Int? = nil,
                         maximumOutputTokens: Int? = nil) -> TextGenerationSettings {
        .init(maximumPromptTokens: maximumPromptTokens ?? current.maximumPromptTokens,
              maximumOutputTokens: maximumOutputTokens ?? current.maximumOutputTokens,
              profile: current.profile)
    }

    private func publishGenerationSettings(_ settings: TextGenerationSettings) {
        Self.publish(settings, to: onGenerationSettingsChange)
    }

    static func publish(_ settings: TextGenerationSettings,
                        to onChange: ((TextGenerationSettings) -> Void)?) {
        onChange?(settings)
    }

    private var comparisonPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选段与候选").font(.headline)
            GroupBox(comparisonSourceLabel) {
                ScrollView {
                    Text(comparisonSourceText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 44, maxHeight: 90)
            }
            GroupBox("替换候选") {
                ScrollView {
                    candidateContent.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier("text-candidate-output")
            }
            .layoutPriority(1)
            if session.candidate != nil && !canAccept {
                Label("原稿或选区已改变，不能接受此候选。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("接受", action: onAccept).disabled(!canAccept).accessibilityIdentifier("text-accept")
                Button("拒绝", action: onReject).disabled(session.candidate == nil).accessibilityIdentifier("text-reject")
            }
        }
        .padding(16)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    private var currentSelectedText: String {
        guard (try? TextRewriteSelection(document: session.document, range: selection)) != nil,
              let range = Range(selection, in: session.document.text) else {
            return "请在原稿中选择要改写的文字。"
        }
        return String(session.document.text[range])
    }

    private var comparisonSourceText: String {
        if let candidate = session.candidate { return candidate.selection.selectedText }
        return session.isRunning ? (session.runningSelection?.selectedText ?? "生成中的原选段已固定。") : currentSelectedText
    }

    private var comparisonSourceLabel: String {
        if session.candidate != nil { return "候选的原选段" }
        return session.isRunning ? "生成中的原选段" : "原选段"
    }

    private func generate() {
        onGenerate()
    }

    @ViewBuilder private var candidateContent: some View {
        if session.isRunning {
            if session.partialText.isEmpty {
                Label("正在生成候选…", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("正在生成候选…", systemImage: "ellipsis")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(session.partialText)
                }
            }
        } else if let candidate = session.candidate {
            Text(candidate.replacement)
        } else {
            Text("尚无候选。改写结果会在此处显示，原稿不会被自动替换。")
                .foregroundStyle(.secondary)
        }
    }
}

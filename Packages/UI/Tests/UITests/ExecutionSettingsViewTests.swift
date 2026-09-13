import AppKit
import DInference
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite("Execution settings views")
@MainActor
struct ExecutionSettingsViewTests {
    @Test
    func textSettingProjectionPreservesUntouchedValuesAndProfile() {
        let unknown = ExecutionProfileReference(identifier: "saved-profile", revision: 99)
        let saved = TextGenerationSettings(maximumPromptTokens: 333, maximumOutputTokens: 444, profile: unknown)
        let changed = TextWorkbenchView.settings(saved, maximumPromptTokens: 555)
        var delivered: TextGenerationSettings?
        TextWorkbenchView.publish(changed, to: { delivered = $0 })
        #expect(changed.maximumPromptTokens == 555)
        #expect(changed.maximumOutputTokens == 444)
        #expect(changed.profile == unknown)
        #expect(delivered == changed)
    }

    @Test
    func audioSummaryStatesOnlyDeclaredProfileAndOperations() {
        let capability = AudioExecutionCapability(
            profile: .init(identifier: "sa3-small", revision: 1),
            contract: .init(operationID: "audio.generate", inputRoles: [.prompt], outputRole: .audio,
                            controlFidelity: .approximate),
            maximumDurationSeconds: 16, sampleRate: 44_100, channelCount: 2,
            operations: [.generate, .variation, .inpaint], noteControlFidelity: .approximate)
        let summary = AudioCreationView.capabilitySummaryText(capability)
        #expect(summary.contains("已部署配置（sa3-small）"))
        #expect(summary.contains("生成、参考变体、局部重绘"))
        #expect(!summary.contains("Stable Audio Medium"))
    }

    @Test
    func narrowTextParametersKeepBothNumericFieldsInsideTheHostingView() throws {
        let document = try TextDraftDocument(text: "中文 e\u{301} 👩‍💻")
        let session = TextDraftSession(document: document, engine: ParameterLayoutEngine(), backendID: "layout.fixture")
        let capability = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        let view = TextWorkbenchView(session: session, selection: .init(location: 0, length: 1),
            instruction: .constant("简洁改写"), modelStatus: "已准备好", canGenerate: true,
            canAccept: false, canUndo: false, isSaving: false, saveStatus: "正文已保存",
            onEdit: { _ in }, onSelection: { _ in }, onGenerate: {}, onCancel: {}, onAccept: {},
            onReject: {}, onUndo: {}, onSave: {}, onChooseModel: {})
            .presenting(.parameters)
            .generationControls(capability: capability, recommendation: nil, configurationError: nil, onChange: { _ in })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 540)
        host.layoutSubtreeIfNeeded()
        let fields = descendants(of: host).compactMap { $0 as? NSTextField }
        #expect(fields.count >= 2)
        for field in fields.prefix(2) {
            let rectangle = field.convert(field.bounds, to: host)
            #expect(rectangle.minX >= -1 && rectangle.maxX <= host.bounds.maxX + 1)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private actor ParameterLayoutEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}

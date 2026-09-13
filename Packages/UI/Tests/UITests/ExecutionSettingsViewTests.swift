import AppKit
import DInference
import DWorkbench
import Foundation
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

    @Test(arguments: ["", "abc", "999999999999999999999999999999999999999999999999999999999999"])
    func invalidRawNumericTextReportsAnEditingErrorWithoutASettingsCallback(raw: String) {
        let error = TextWorkbenchView.numericEditingError(raw, label: "输入 token 上限")
        var deliveredError: String?
        var settingsChanges = 0
        TextWorkbenchView.reportEditingError(error, to: { deliveredError = $0 })
        let settingsCallback: (TextGenerationSettings) -> Void = { _ in settingsChanges += 1 }
        if error == nil {
            TextWorkbenchView.publish(.legacy, to: settingsCallback)
        }
        #expect(error != nil)
        #expect(deliveredError == error)
        #expect(settingsChanges == 0)
    }

    @Test
    func manualImageEditKeepsUnknownProfileButMayAdvanceVerified512() {
        let scalable = ImageExecutionCapability.scalableKlein4B
        let unknown = ExecutionProfileReference(identifier: "saved-image-profile", revision: 99)
        #expect(GenerationInspector.profileForManualDimensionEdit(unknown, capability: scalable) == unknown)
        #expect(GenerationInspector.profileForManualDimensionEdit(ImageExecutionCapability.verified512.profile,
            capability: scalable) == scalable.profile)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let fields = descendants(of: host).compactMap { $0 as? NSTextField }
        for identifier in ["text-input-limit", "text-output-limit"] {
            let field = try #require(fields.first {
                $0.isEditable && $0.accessibilityIdentifier() == identifier
            })
            let rectangle = field.convert(field.bounds, to: host)
            #expect(rectangle.width > 0 && rectangle.height > 0)
            #expect(rectangle.minX >= -1 && rectangle.maxX <= host.bounds.maxX + 1)
        }
        let scrollView = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height > scrollView.bounds.height)
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

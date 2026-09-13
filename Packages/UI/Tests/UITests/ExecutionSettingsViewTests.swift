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
    func invalidRawNumericTextReportsItsParsingError(raw: String) {
        let error = TextWorkbenchView.numericEditingError(raw, label: "输入 token 上限")
        var deliveredError: String?
        TextWorkbenchView.reportEditingError(error, to: { deliveredError = $0 })
        #expect(error != nil)
        #expect(deliveredError == error)
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
    func narrowTextParametersKeepBothNumericFieldsInsideTheHostingView() async throws {
        let document = try TextDraftDocument(text: "中文 e\u{301} 👩‍💻")
        let session = TextDraftSession(document: document, engine: ParameterLayoutEngine(), backendID: "layout.fixture")
        let capability = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        var rectangles: [String: CGRect] = [:]
        let view = TextWorkbenchView(session: session, selection: .init(location: 0, length: 1),
            instruction: .constant("简洁改写"), modelStatus: "已准备好", canGenerate: true,
            canAccept: false, canUndo: false, isSaving: false, saveStatus: "正文已保存",
            onEdit: { _ in }, onSelection: { _ in }, onGenerate: {}, onCancel: {}, onAccept: {},
            onReject: {}, onUndo: {}, onSave: {}, onChooseModel: {})
            .presenting(.parameters)
            .generationControls(capability: capability, recommendation: nil, configurationError: nil, onChange: { _ in })
            .observingParameterLayout(scrollToOutput: true) { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let deadline = Date().addingTimeInterval(0.3)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        for identifier in ["text-input-limit", "text-output-limit"] {
            let rectangle = try #require(rectangles[identifier], "Missing actual TextField geometry")
            #expect(rectangle.width > 80 && rectangle.height > 10)
            #expect(rectangle.minX >= -1 && rectangle.maxX <= host.bounds.maxX + 1)
        }
        // Scroll the actual SwiftUI viewport; no NSScrollView implementation assumption.
        let output = try #require(rectangles["text-output-limit"])
        print("TEXT_LAYOUT initial output=\(output) host=\(host.bounds)")
        #expect(output.minY >= -1 && output.maxY <= host.bounds.maxY + 1)
        // Resize the existing viewport, rather than reconstructing the editor.
        for size in [NSSize(width: 280, height: 140), NSSize(width: 400, height: 240)] {
            window.setContentSize(size)
            host.frame.size = size
            let resizeDeadline = Date().addingTimeInterval(0.3)
            repeat {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < resizeDeadline
            let resized = try #require(rectangles["text-output-limit"])
            print("TEXT_LAYOUT resized output=\(resized) host=\(host.bounds)")
            #expect(resized.minX >= -1 && resized.maxX <= host.bounds.maxX + 1)
            #expect(resized.minY >= -1 && resized.maxY <= host.bounds.maxY + 1,
                    "Output field \(resized) must remain reachable in resized viewport \(host.bounds)")
        }
    }

}

private actor ParameterLayoutEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}

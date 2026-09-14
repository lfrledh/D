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

    @Test func lateParameterTargetIsReachableAfterModelCapabilityArrives() async throws {
        let state = DelayedParameterState()
        let document = try TextDraftDocument(text: "迟到参数 👩‍💻")
        let session = TextDraftSession(document: document, engine: ParameterLayoutEngine(), backendID: "layout.fixture")
        let layout = ParameterLayoutObservation()
        let view = TextWorkbenchView(session: session, selection: .init(location: 0, length: 1),
            instruction: .constant("简洁改写"), modelStatus: "等待模型能力", canGenerate: true,
            canAccept: false, canUndo: false, isSaving: false, saveStatus: "正文已保存",
            onEdit: { _ in }, onSelection: { _ in }, onGenerate: {}, onCancel: {}, onAccept: {},
            onReject: {}, onUndo: {}, onSave: {}, onChooseModel: {})
            .presenting(.parameters).questionParameters(true)
            .observingParameterLayout(scrollProxy: { layout.proxy = $0 }, layout.record)
        let host = NSHostingView(rootView: DelayedParameterView(state: state, content: view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        try await layout.wait(host) {
            state.appeared && layout.proxy != nil && layout.viewport == host.bounds.size
        }
        #expect(layout.rectangles["text-output-limit"] == nil)
        state.capability = .init(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        try await layout.ready(host, after: 0)
        // Negative control: target arrival is not proof of scroll completion.
        // Without an actual scroll request this narrow viewport clips the target.
        let unscrolled = try #require(layout.rectangles["text-output-limit"])
        #expect(unscrolled.maxY > host.bounds.maxY + 1)
        try await layout.scrollOutput(host)
        let output = try #require(layout.rectangles["text-output-limit"])
        print("TEXT_LAYOUT late target=\(output) viewport=\(host.bounds)")
        #expect(output.width > 80 && output.height > 10)
        #expect(output.minX >= -1 && output.maxX <= host.bounds.maxX + 1)
        #expect(output.minY >= -1 && output.maxY <= host.bounds.maxY + 1)
    }

    @Test(arguments: [false, true])
    func narrowTextParametersKeepBothNumericFieldsInsideTheHostingView(questionMode: Bool) async throws {
        let document = try TextDraftDocument(text: "中文 e\u{301} 👩‍💻")
        let session = TextDraftSession(document: document, engine: ParameterLayoutEngine(), backendID: "layout.fixture")
        let capability = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        let layout = ParameterLayoutObservation()
        let view = TextWorkbenchView(session: session, selection: .init(location: 0, length: 1),
            instruction: .constant("简洁改写"), modelStatus: "已准备好", canGenerate: true,
            canAccept: false, canUndo: false, isSaving: false, saveStatus: "正文已保存",
            onEdit: { _ in }, onSelection: { _ in }, onGenerate: {}, onCancel: {}, onAccept: {},
            onReject: {}, onUndo: {}, onSave: {}, onChooseModel: {})
            .presenting(.parameters)
            .questionParameters(questionMode)
            .generationControls(capability: capability, recommendation: nil, configurationError: nil, onChange: { _ in })
            .observingParameterLayout(scrollProxy: { layout.proxy = $0 }, layout.record)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        try await layout.ready(host, after: 0)
        try await layout.scrollOutput(host)
        for identifier in ["text-input-limit", "text-output-limit"] {
            let rectangle = try #require(layout.rectangles[identifier], "Missing actual TextField geometry")
            #expect(rectangle.width > 80 && rectangle.height > 10)
            #expect(rectangle.minX >= -1 && rectangle.maxX <= host.bounds.maxX + 1)
        }
        // Scroll the actual SwiftUI viewport; no NSScrollView implementation assumption.
        let output = try #require(layout.rectangles["text-output-limit"])
        print("TEXT_LAYOUT initial output=\(output) host=\(host.bounds)")
        #expect(output.minY >= -1 && output.maxY <= host.bounds.maxY + 1)
        // Resize the existing viewport, rather than reconstructing the editor.
        for size in [NSSize(width: 280, height: 140), NSSize(width: 400, height: 240)] {
            let previousObservation = layout.outputRevision
            window.setContentSize(size)
            host.frame.size = size
            try await layout.ready(host, after: previousObservation)
            try await layout.scrollOutput(host)
            let resized = try #require(layout.rectangles["text-output-limit"])
            print("TEXT_LAYOUT resized output=\(resized) host=\(host.bounds)")
            #expect(resized.minX >= -1 && resized.maxX <= host.bounds.maxX + 1)
            #expect(resized.minY >= -1 && resized.maxY <= host.bounds.maxY + 1,
                    "Output field \(resized) must remain reachable in resized viewport \(host.bounds)")
        }
    }

}

/// Per-host observations; parallel tests cannot acknowledge each other's scrolls.
@MainActor
private final class ParameterLayoutObservation {
    var proxy: ScrollViewProxy?
    var rectangles: [String: CGRect] = [:]
    var outputRevision = 0
    var viewport: CGSize? { rectangles["text-parameter-viewport"]?.size }

    func record(_ identifier: String, _ rectangle: CGRect) {
        rectangles[identifier] = rectangle
        if identifier == "text-output-limit" { outputRevision += 1 }
    }

    func ready(_ host: NSView, after revision: Int) async throws {
        try await wait(host) {
            self.proxy != nil && self.viewport == host.bounds.size && self.outputRevision > revision &&
            ["text-input-limit", "text-output-limit"].allSatisfy {
                guard let frame = self.rectangles[$0] else { return false }
                return frame.width > 0 && frame.height > 0
            }
        }
    }

    func scrollOutput(_ host: NSView) async throws {
        let reader = try #require(proxy)
        let revision = outputRevision
        let wasVisible = outputIsVisible(in: host)
        reader.scrollTo("text-output-scroll-target", anchor: .bottom)
        // A changed frame after this request acknowledges scrolling. An already
        // visible target may not change geometry; its current-size bounds suffice.
        try await wait(host) {
            self.viewport == host.bounds.size && self.outputIsVisible(in: host) &&
            (wasVisible || self.outputRevision > revision)
        }
    }

    private func outputIsVisible(in host: NSView) -> Bool {
        guard let frame = rectangles["text-output-limit"] else { return false }
        return frame.minY >= -1 && frame.maxY <= host.bounds.maxY + 1
    }

    func wait(_ host: NSView, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(0.3)
        while !condition() && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Expected current viewport/target or post-request scroll geometry within the original bound")
    }
}

private actor ParameterLayoutEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}

@Observable @MainActor
private final class DelayedParameterState {
    var capability: TextExecutionCapability?
    var appeared = false
}

@MainActor
private struct DelayedParameterView: View {
    let state: DelayedParameterState
    let content: TextWorkbenchView
    var body: some View {
        content.generationControls(capability: state.capability, recommendation: nil,
            configurationError: nil, onChange: { _ in })
            .onAppear { state.appeared = true }
    }
}

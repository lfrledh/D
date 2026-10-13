import AppKit
import Foundation
import SwiftUI
import Testing
import DInference
@testable import DWorkbench
@testable import UI

// Runs in DTests TEST_HOST, with a review-only App that rejects missing isolation.
// AX actions here are component evidence, not a claim about foreground usability.
private actor CanvasSeriousImageEngine: InferenceEngine {
    private(set) var calls = 0
    var onSubmit: (@MainActor @Sendable () -> Void)?
    func configure(_ action: @escaping @MainActor @Sendable () -> Void) { onSubmit = action }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        await onSubmit?()
        return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {},
            outcome: { .failed(.inputIntegrityChanged("DHA UI serious")) })
    }
}

@MainActor private struct RecoveryButtonFixture: View {
    let controller: WorkflowController
    var body: some View {
        VStack {
            if let run = controller.runs.last {
                WorkflowRunRecoveryButton(controller: controller, run: run, readOnly: false)
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_RECOVERY_REVIEW"] == "1"), .serialized)
@MainActor struct WorkbenchRecoveryAppHostTests {
    @Test(arguments: ["zh-Hans", "en"])
    func appHostedRecoveryButtonSavesOnlyAndThenOffersExplicitRetry(locale: String) async throws {
        try #require(Bundle.main.bundleIdentifier == "first-test.D.review.D")
        try #require(Bundle.main.object(forInfoDictionaryKey: "DReviewLaunchMode") as? String == "isolated-download-v1")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("dha-recovery-button-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Recovery.dproject"), name: "Recovery fixture")
        print("D_APP_HOST_FIXTURE", root.path, Bundle.main.bundleIdentifier ?? "nil", Bundle.main.executableURL?.path ?? "nil")
        let engine = CanvasSeriousImageEngine()
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {},
            validateModel: { _ in }, imageCapability: .scalableKlein4B)
        let services = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root, revision: "fixture"), backendID: "fixture.image",
                imageRecipe: .klein(capability: .scalableKlein4B))
        }
        let c = WorkflowController(services: services); await c.load()
        c.addBlankGraph(name: "Failure recovery"); c.addNode(operationID: "d.image.generate")
        let target = try #require(c.selectedNodeID)
        c.setParameter(nodeID: target, key: "modelID", value: .text("image:frozen"))
        c.setParameter(nodeID: target, key: "promptText", value: .text("fixture"))
        c.setParameter(nodeID: target, key: "count", value: .integer(1))
        await engine.configure { c.beforeHistorySave = { throw WorkflowIssue("DHA UI history write") } }
        await c.run(target: target, only: false)
        let run = try #require(c.runs.last)
        try #require(run.status == .saving && run.steps.last?.status == .failed)
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        defer { application.setActivationPolicy(previousPolicy) }
        var mounted = false
        let host = NSHostingView(rootView: VStack {
            Button("Hosting accessibility probe") { print("D_APP_HOST_PROBE_PRESSED") }
                .accessibilityIdentifier("dha-hosting-probe")
            RecoveryButtonFixture(controller: c)
        }
            .onAppear { mounted = true }
            .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: [locale])))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        // Establish and verify this test process's window prerequisites before
        // interpreting an absent accessibility element as a product failure.
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if mounted && window.isVisible && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.isVisible && window.isKeyWindow && host.window === window,
            "Recovery fixture requires a visible key window in the test process")
        try #require(mounted, "Recovery fixture SwiftUI view did not appear")
        func control(_ identifier: String) async throws -> any NSAccessibilityProtocol {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                var pending: [NSObject] = [host], visited = Set<ObjectIdentifier>()
                while let object = pending.popLast(), visited.count < 2_000 {
                    guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
                    if let element = object as? any NSAccessibilityProtocol {
                        if element.accessibilityIdentifier() == identifier { return element }
                        pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
                    }
                    if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            print("D_APP_HOST_RECOVERY_AX_MISSING", identifier)
            throw WorkflowIssue("Recovery fixture accessibility element was not mounted: " + identifier)
        }
        let probe = try await control("dha-hosting-probe")
        #expect(probe.accessibilityPerformPress())
        print("D_APP_HOST_RECOVERY_PROBE", locale, window.isVisible, window.isKeyWindow)
        let recoveryID = "workflow-run-recovery-" + run.id.uuidString
        let savingButton = try await control(recoveryID)
        #expect(savingButton.accessibilityLabel() == (locale == "en" ? "Retry Saving Failure Record" : "重试保存失败记录"))
        c.beforeHistorySave = {}; await engine.configure {}
        #expect(savingButton.accessibilityPerformPress())
        for _ in 0..<200 {
            if c.runs.last?.status == .failed && !c.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.runs.last?.id == run.id && c.runs.last?.status == .failed && !c.hasPendingSaves)
        #expect(await engine.calls == 1)
        #expect(c.errorMessage?.contains("DHA UI serious") == true && c.errorMessage?.contains("DHA UI history write") == true)
        #expect(c.progressMessage.contains("失败记录已保存") && !c.progressMessage.contains("计算结果仍保留"))
        // Cold-read a stable copy before any recomputation, through the real Store.
        let savedCopy = root.appendingPathComponent("SavedFailure.dproject")
        try FileManager.default.copyItem(at: store.rootURL, to: savedCopy)
        let saved = try await ProjectStore.open(at: savedCopy)
        let savedState = try await saved.workflowState()
        let savedRun = try #require(savedState.archive?.runs.first { $0.id == run.id })
        #expect(savedRun.status == .failed && savedRun.steps.last?.status == .failed)
        #expect(savedRun.steps.last?.error?.contains("DHA UI serious") == true)
        try await saved.close()
        print("D_APP_HOST_SAVE_ONLY", locale, run.id, "failed", "calls", await engine.calls)
        // This is the same production button after recovery, with an explicit
        // computation action. Test-process events do not certify foreground UI.
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        let retryButton = try await control(recoveryID)
        #expect(retryButton.accessibilityLabel() == (locale == "en" ? "Retry Computation" : "重试计算"))
        #expect(retryButton.accessibilityPerformPress())
        for _ in 0..<200 {
            if await engine.calls == 2, !c.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.calls == 2 && c.runs.last?.status == .failed)
        #expect(c.errorMessage?.contains("DHA UI serious") == true)
        print("D_APP_HOST_RECOVERY_RESULT", locale, "run", run.id, "calls", await engine.calls,
              "status", c.runs.last?.status.rawValue ?? "nil", "pending", c.hasPendingSaves)
        try await c.close(); try await store.close()
        let cold = try await ProjectStore.open(at: store.rootURL)
        let snapshot = try await cold.workflowState()
        #expect(snapshot.archive?.runs.contains { $0.id == run.id && $0.status == .failed } == true)
        try await cold.close()
    }
}

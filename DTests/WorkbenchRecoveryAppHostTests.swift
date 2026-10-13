import AppKit
import Foundation
import Observation
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

// Explicit human-click mode is separate evidence from the AX method below.
@MainActor @Observable private final class RecoveryHostInteraction {
    enum Phase { case probe, save, checking, retry, finished }
    var phase = Phase.probe
    var probePressed = false
}

@MainActor private struct AttendedRecoveryFixture: View {
    let controller: WorkflowController
    let interaction: RecoveryHostInteraction
    let locale: String
    @Environment(\.dLanguageStore) private var languageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(locale == "en" ? "DHA recovery — isolated test" : "DHA 恢复 — 隔离测试").font(.headline)
            Text(instruction).fixedSize(horizontal: false, vertical: true)
            Text(workflowRecoveryErrorText(controller.errorMessage ?? "", language: languageStore)).textSelection(.enabled)
            Text(workflowRecoveryProgressText(controller.progressMessage, language: languageStore)).textSelection(.enabled)
            Button(locale == "en" ? "Begin this check" : "开始本项检查") {
                interaction.probePressed = true
                print("D_APP_HOST_HUMAN_PROBE", locale)
            }.disabled(interaction.phase != .probe || interaction.probePressed)
            RecoveryButtonFixture(controller: controller)
                // A saved run cannot expose an enabled retry until the test has
                // verified request count and cold-read the failure-only record.
                .disabled(!actionAllowed)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var actionAllowed: Bool {
        guard !controller.isRunning else { return false }
        switch interaction.phase {
        case .save: return controller.runs.last?.status == .saving
        case .retry: return controller.runs.last?.status == .failed
        default: return false
        }
    }
    private var instruction: String {
        switch interaction.phase {
        case .probe: return locale == "en" ? "Click Begin this check first." : "请先点“开始本项检查”。"
        case .save: return locale == "en" ? "Click Retry Saving Failure Record below." : "请点击下方生产按钮：重试保存失败记录。"
        case .checking: return locale == "en" ? "Verifying saved state; please wait." : "正在核对保存与冷读，请等待。"
        case .retry: return locale == "en" ? "Saving verified; click Retry Computation." : "保存已核对，请点击重试计算。"
        case .finished: return locale == "en" ? "Check complete; closing." : "本项完成，即将关闭。"
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_RECOVERY_REVIEW"] == "1"), .serialized)
@MainActor struct WorkbenchRecoveryAppHostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_RECOVERY_HUMAN_CLICKS"] != "1"),
          arguments: ["zh-Hans", "en"])
    func appHostedRecoveryButtonSavesOnlyAndThenOffersExplicitRetry(locale: String) async throws {
        try await verifyRecovery(locale: locale, attended: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_RECOVERY_HUMAN_CLICKS"] == "1"))
    func attendedRecoveryButtonSavesOnlyAndThenOffersExplicitRetry() async throws {
        // A prerequisite failure stops the whole attended run, including the
        // second language, instead of opening another unusable test window.
        for locale in ["zh-Hans", "en"] {
            try await verifyRecovery(locale: locale, attended: true)
        }
    }

    private func verifyRecovery(locale: String, attended: Bool) async throws {
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
        let interaction = RecoveryHostInteraction()
        let host = NSHostingView(rootView: Group {
            if attended {
                AttendedRecoveryFixture(controller: c, interaction: interaction, locale: locale)
            } else {
                VStack {
                    Button("Hosting accessibility probe") { print("D_APP_HOST_PROBE_PRESSED") }
                        .accessibilityIdentifier("dha-hosting-probe")
                    RecoveryButtonFixture(controller: c)
                }
            }
        }
            .onAppear { mounted = true }
            .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: [locale])))
        host.frame = CGRect(x: 0, y: 0, width: attended ? 640 : 420, height: attended ? 400 : 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let waitsForUserActivation = attended || ProcessInfo.processInfo.environment["D_NATIVE_RECOVERY_WAIT_FOR_ACTIVATION"] == "1"
        window.title = "D — DHA " + locale + " / " + String(run.id.uuidString.prefix(8))
            + " / PID " + String(ProcessInfo.processInfo.processIdentifier)
        // Establish and verify this test process's window prerequisites before
        // interpreting an absent accessibility element as a product failure.
        if attended { window.center() }
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        if waitsForUserActivation {
            print("D_APP_HOST_WAITING_FOR_ACTIVATION", locale, run.id, ProcessInfo.processInfo.processIdentifier)
        }
        // Explicit attended runs allow a user gesture to activate this host when
        // macOS declines programmatic activation. The readiness checks stay intact.
        for _ in 0..<(waitsForUserActivation ? 12_000 : 100) {
            host.layoutSubtreeIfNeeded()
            if mounted && window.isVisible && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("D_APP_HOST_WINDOW", locale, "active", application.isActive,
              "visible", window.isVisible, "key", window.isKeyWindow,
              "canBecomeKey", window.canBecomeKey, "mounted", mounted,
              "window", window.windowNumber, "currentKey", application.keyWindow?.windowNumber ?? -1)
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
        func waitForHuman(_ stage: String, maximumCalls: Int,
                          condition: @MainActor () async -> Bool) async throws {
            print("D_APP_HOST_HUMAN_WAIT", locale, stage, run.id, ProcessInfo.processInfo.processIdentifier)
            for _ in 0..<2_400 {
                try #require(window.isVisible && host.window === window, "Attended window disappeared")
                try #require(c.runs.last?.id == run.id, "Attended run identity changed")
                try #require(await engine.calls <= maximumCalls, "Unexpected computation during attended check")
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw WorkflowIssue("Attended recovery check timed out: " + stage)
        }
        let recoveryID = "workflow-run-recovery-" + run.id.uuidString
        if attended {
            try await waitForHuman("begin", maximumCalls: 1) { interaction.probePressed }
            c.beforeHistorySave = {}; await engine.configure {}
            interaction.phase = .save
            try await waitForHuman("save failure record", maximumCalls: 1) {
                c.runs.last?.status == .failed && !c.isRunning && !c.hasPendingSaves
            }
            interaction.phase = .checking
            try #require(await engine.calls == 1 && c.runs.last?.id == run.id)
        } else {
            let probe = try await control("dha-hosting-probe")
            #expect(probe.accessibilityPerformPress())
            print("D_APP_HOST_RECOVERY_PROBE", locale, window.isVisible, window.isKeyWindow)
            let savingButton = try await control(recoveryID)
            #expect(savingButton.accessibilityLabel() == (locale == "en" ? "Retry Saving Failure Record" : "重试保存失败记录"))
            c.beforeHistorySave = {}; await engine.configure {}
            #expect(savingButton.accessibilityPerformPress())
            for _ in 0..<200 {
                if c.runs.last?.status == .failed && !c.isRunning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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
        if attended {
            try #require(savedRun.status == .failed && savedRun.steps.last?.status == .failed)
            try #require(savedRun.steps.last?.error?.contains("DHA UI serious") == true)
            try #require(c.errorMessage?.contains("DHA UI serious") == true && c.errorMessage?.contains("DHA UI history write") == true)
            try #require(c.progressMessage.contains("失败记录已保存") && !c.progressMessage.contains("计算结果仍保留"))
            interaction.phase = .retry
            try await waitForHuman("retry computation", maximumCalls: 2) {
                await engine.calls == 2 && !c.isRunning
            }
            interaction.phase = .finished
        } else {
            let retryButton = try await control(recoveryID)
            #expect(retryButton.accessibilityLabel() == (locale == "en" ? "Retry Computation" : "重试计算"))
            #expect(retryButton.accessibilityPerformPress())
            for _ in 0..<200 {
                if await engine.calls == 2, !c.isRunning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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

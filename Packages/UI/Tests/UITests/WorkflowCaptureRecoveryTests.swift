import AppKit
import DInference
import Foundation
import SwiftUI
import Testing
@testable import DWorkbench
@testable import UI

private actor RecoveryNoEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) throws -> InferenceRun {
        throw WorkflowIssue("Recovery must not use a model")
    }
}

@MainActor private final class RecoveryNoDevice: AudioTransportDeviceFactory {
    func requestRecordPermission() async -> Bool { true }
    func makePlayback(url: URL, expected: AudioFormatInfo) throws -> any AudioPlaybackDevice {
        throw AudioMediaError.unavailable("No playback in recovery test")
    }
    func makeRecording(capture: AudioCaptureFile) throws -> any AudioRecordingDevice {
        throw AudioMediaError.unavailable("Controlled missing input device")
    }
}

@Suite(.serialized) @MainActor
struct WorkflowCaptureRecoveryTests {
    @Test func recoveryActionFromImageProjectPreservesCaptureAndRejectsStaleContext() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("workflow-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Recovery.dproject")
        let suite = "D.WorkflowRecovery." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let engine = RecoveryNoEngine()
        let session = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings, audioEnabled: true, audioRecordingEnabled: true,
            audioTransport: AudioTransport(recordingEnabled: true, deviceFactory: RecoveryNoDevice()))
        await session.createProject(at: project); await session.openWorkflow()
        let model = WorkbenchModel(projectSession: session, audioRecordingEnabled: true)
        let controller = try #require(session.workflow)
        controller.addExample("file")
        let node = try #require(controller.graph?.nodes.first { $0.operationID == "d.asset.reference" })
        await session.startWorkflowRecording(nodeID: node.id, controller: controller)
        let pending = try #require(session.audio?.pendingCaptures.first)
        let before = try Data(contentsOf: project.appendingPathComponent(pending.relativePath))
        #expect(session.creatorMode == .image)
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let host = NSHostingView(rootView: WorkflowHostView(model: model).environment(\.dLanguageStore, language))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        for _ in 0..<40 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.fittingSize.width <= 1100)
        let contextID = try #require(session.audio?.contextID)
        let documentID = model.activeDocumentID
        // Public in-process AX does not expose SwiftUI-drawn button identities
        // here (see WorkflowLocalizationTests). Native H27 verifies the visible
        // button separately; this exercises its real context-checked action.
        model.keepPendingAudioCaptureForRecovery(id: pending.id, contextID: UUID(), renderDocumentID: documentID)
        #expect(session.audio?.navigationBlockMessage != nil)
        model.clearError()
        model.keepPendingAudioCaptureForRecovery(id: pending.id, contextID: contextID, renderDocumentID: documentID)
        #expect(session.audio?.navigationBlockMessage == nil)
        #expect(session.creatorMode == .image)
        #expect(session.audio?.pendingCaptures == [pending])
        #expect(try Data(contentsOf: project.appendingPathComponent(pending.relativePath)) == before)
        #expect(await session.requestClose())
    }
}

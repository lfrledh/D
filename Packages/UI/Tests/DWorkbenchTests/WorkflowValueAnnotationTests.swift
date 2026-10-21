import Foundation
import Testing
@testable import DWorkbench

@Suite(.serialized) @MainActor
struct WorkflowValueAnnotationTests {
    @Test func terminalActivityClearsPreviousLocalizedProgress() {
        let state = WorkflowCallActivityState()
        state.begin(.init(node: .init(operationID: "d.text.input", title: "User name"), stepID: UUID(), inputs: [:]))
        state.update(phase: "running", progress: "", message: .init("savingResult"))
        #expect(state.current?.message?.code == "savingResult")
        state.end(phase: "completed")
        #expect(state.current?.phase == "completed" && state.current?.finished == true && state.current?.message == nil && state.current?.progress == "")
    }
    @Test func runtimeStageUsesTypedIdentityAndPreservesRawBackendText() {
        let active = UUID(), queued = UUID(), other = UUID()
        let status = WorkbenchRuntimeStatus(activeRunID: active, phase: "正在生成图像", queuedRunIDs: [queued], state: .generating, phaseCode: "denoising")
        #expect(status.phaseCode(for: active) == "denoising" && status.phase(for: active) == "正在生成图像")
        #expect(status.phaseCode(for: queued) == "queued" && status.phaseCode(for: other) == nil)
        let old = WorkbenchRuntimeStatus(activeRunID: active, phase: "Loading model / 正在加载模型", queuedRunIDs: [], state: .preparing)
        #expect(old.phaseCode(for: active) == "preparing" && old.phase(for: active) == "Loading model / 正在加载模型")
        let unknown = WorkbenchRuntimeStatus(activeRunID: active, phase: "unknown raw backend", queuedRunIDs: [])
        #expect(unknown.phaseCode(for: active) == nil && unknown.phase(for: active) == "unknown raw backend")
    }
    private func key(project: UUID = UUID(), instance: UUID = UUID(), run: UUID = UUID(), step: UUID = UUID(),
                     path: [WorkflowAddressComponent] = [], port: String = "output", text: String = "unchanged", candidate: UUID? = nil) throws -> WorkflowValueIdentity {
        try .init(projectID: project, instanceID: instance, call: .init(address: .init(runID: run, path: path), stepID: step),
                  port: port, value: .data(.text(text)), candidateID: candidate)
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("value-annotations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @Test func identityIncludesOwnerFullCallPortCandidateAndExactContentBytes() throws {
        let project = UUID(), instance = UUID(), run = UUID(), step = UUID(), node = UUID(), candidate = UUID()
        let path: [WorkflowAddressComponent] = [.node(node), .item("item-A"), .iteration(4), .node(node)]
        let first = try key(project: project, instance: instance, run: run, step: step, path: path, text: "é", candidate: candidate)
        #expect(first == (try key(project: project, instance: instance, run: run, step: step, path: path, text: "é", candidate: candidate)))
        let variants = try [key(project: project, instance: instance, run: UUID(), step: step, path: path, text: "é", candidate: candidate),
            key(project: project, instance: UUID(), run: run, step: step, path: path, text: "é", candidate: candidate),
            key(project: UUID(), instance: instance, run: run, step: step, path: path, text: "é", candidate: candidate),
            key(project: project, instance: instance, run: run, step: step, path: path + [.item("item-B")], text: "é", candidate: candidate),
            key(project: project, instance: instance, run: run, step: UUID(), path: path, text: "é", candidate: candidate),
            key(project: project, instance: instance, run: run, step: step, path: path, port: "other", text: "é", candidate: candidate),
            key(project: project, instance: instance, run: run, step: step, path: path, text: "e\u{301}", candidate: candidate),
            key(project: project, instance: instance, run: run, step: step, path: path, text: "é", candidate: UUID())]
        #expect(variants.allSatisfy { $0 != first })
        #expect(try key(path: [.item(String(repeating: "long", count: 400))]).storageKey.count < 512)
    }
    @Test func explicitSaveColdOpenConflictUndoAndDiskFailure() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json"), identity = try key(), other = try key()
        let store = try SharedLibraryStore(fileURL: file)
        let draft = WorkflowValueAnnotation(name: "用户名 {port}", note: "原文🙂", favorite: true)
        #expect(!FileManager.default.fileExists(atPath: file.path)) // Cancelled/unsubmitted draft has no write.
        try store.saveRuntimeAnnotation(identity: identity, expected: nil, value: draft)
        let firstBytes = try Data(contentsOf: file)
        let reopened = try SharedLibraryStore(fileURL: file)
        #expect(reopened.metadata.runtimeAnnotations[identity.storageKey] == draft)
        let changed = WorkflowValueAnnotation(name: "changed")
        try store.saveRuntimeAnnotation(identity: identity, expected: draft, value: changed)
        #expect(throws: SharedLibraryError.staleAnnotation) { try store.saveRuntimeAnnotation(identity: identity, expected: draft, value: draft) }
        #expect(draft.name == "用户名 {port}" && store.metadata.runtimeAnnotations[identity.storageKey] == changed)
        try store.undo(); #expect(store.metadata.runtimeAnnotations[identity.storageKey] == draft)
        try store.redo(); #expect(store.metadata.runtimeAnnotations[identity.storageKey] == changed)
        #expect(store.metadata.runtimeAnnotations[other.storageKey] == nil)
        let state = store.metadata
        try firstBytes.write(to: file)
        #expect(throws: SharedLibraryError.externalChange) { try store.saveRuntimeAnnotation(identity: other, expected: nil, value: draft) }
        #expect(store.metadata == state)
        let noDirectory = try SharedLibraryStore(fileURL: root.appendingPathComponent("missing/library.json"))
        #expect(throws: (any Error).self) { try noDirectory.saveRuntimeAnnotation(identity: identity, expected: nil, value: draft) }
        #expect(noDirectory.metadata.runtimeAnnotations.isEmpty && !noDirectory.canUndo)
    }
    @Test func schemaTwoColdReadIsLazyUpgradeBacksUpAndUnknownFieldsFailClosed() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        let original = Data(#"{"schema":2,"metadata":{"tags":[],"folders":[],"savedQueries":[],"tagAssignments":{},"importedLegacyKeys":[]}}"#.utf8)
        try original.write(to: file)
        let store = try SharedLibraryStore(fileURL: file)
        #expect(store.metadata.runtimeAnnotations.isEmpty)
        #expect(try Data(contentsOf: file) == original)
        try store.saveRuntimeAnnotation(identity: key(), expected: nil, value: .init(name: "name"))
        #expect(try Data(contentsOf: SharedLibraryStore.schemaTwoBackupURL(for: file)) == original)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var body = try #require(envelope["metadata"] as? [String: Any]); body["future"] = true; envelope["metadata"] = body
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        #expect(throws: (any Error).self) { _ = try SharedLibraryStore(fileURL: file) }
    }
}

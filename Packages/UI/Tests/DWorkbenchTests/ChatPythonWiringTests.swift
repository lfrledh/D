import Foundation
import Testing
@testable import DWorkbench

@Suite("Python tool and artifact wiring", .serialized) @MainActor
struct ChatPythonWiringTests {
    private func fixture() async throws -> (ProjectStore, ChatController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("python-wiring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Python")
        let package = ProcessInfo.processInfo.environment["D_CHAT_PYTHON_TEST_PACKAGE"].map { URL(fileURLWithPath: $0) }
        let chat = ChatController(store: store, pythonClient: .init(packageURL: package)) {
            throw WorkflowIssue("Python must not run a model")
        }
        await chat.load()
        return (store, chat)
    }

    @Test func unselectedInputIsRejectedBeforeHelperLaunch() async throws {
        let (store, chat) = try await fixture(); let id = try chat.newSession()
        try chat.updateDraft("原文 remains", sessionID: id)
        let input = try await store.publishWorkflowAsset(data: Data("x\n1\n".utf8), mediaType: "text/plain",
            name: "Unselected", operationID: "fixture").record.reference
        await #expect(throws: (any Error).self) { try await chat.executeTool(.python(code: "print(1)", inputs: [input]), sessionID: id) }
        #expect(chat.selectedSession?.toolActivities?.isEmpty != false)
        #expect(chat.selectedSession?.draft == "原文 remains")
        #expect(try await store.workflowData(input) == Data("x\n1\n".utf8))
        try await store.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_CHAT_PYTHON_TEST_PACKAGE"] != nil))
    func realWASIAnalysisArtifactsAndIndependentRestore() async throws {
        let (store, chat) = try await fixture(); let id = try chat.newSession()
        try chat.updateDraft("未发送的草稿", sessionID: id)
        let bytes = Data("name,value\n一,10\n二,20\n三,30\n".utf8)
        let input = try await store.publishWorkflowAsset(data: bytes, mediaType: "text/plain", name: "数据.csv", operationID: "fixture").record.reference
        _ = try await chat.addAttachment(input, name: "数据.csv", sessionID: id)
        let code = """
        import csv, statistics
        from d_result import publish
        with open('/inputs/input-1.csv', encoding='utf-8') as f:
            values = [float(row['value']) for row in csv.DictReader(f)]
        mean = statistics.mean(values)
        print('mean:', mean)
        publish('summary.csv', 'csv', 'mean\\n' + str(mean) + '\\n')
        publish('chart.svg', 'svg', '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="' + str(mean) + '" height="20"/></svg>')
        """
        let activity = try await chat.executeTool(.python(code: code, inputs: [input]), sessionID: id)
        let record = try #require(chat.selectedSession?.toolActivities?.last)
        #expect(record.status == .completed)
        let result = try JSONDecoder().decode(ChatPythonResult.self, from: Data(try #require(record.resultJSON).utf8))
        #expect(result.stdout == "mean: 20.0\n" && result.outputs.count == 2)
        #expect(chat.selectedSession?.messages.isEmpty == true)
        #expect(chat.selectedSession?.draft == "未发送的草稿")
        #expect(chat.selectedSession?.artifacts?.isEmpty != false)
        let other = try chat.newSession()
        let csv = try await chat.artifactFromPython(activity, outputIndex: 0, sessionID: id)
        #expect(csv.output == nil && csv.sessionID == id)
        let savedCSV = try await chat.saveArtifact(csv)
        let svg = try await chat.artifactFromPython(activity, outputIndex: 1, sessionID: id)
        let savedSVG = try await chat.saveArtifact(svg)
        #expect(try await chat.artifactFromPython(activity, outputIndex: 0, sessionID: id) == savedCSV)
        #expect(chat.selectedSession?.id == other && chat.selectedSession?.artifacts?.isEmpty != false)
        #expect(try await store.workflowData(input) == bytes)
        let receipt = try #require(savedCSV.source)
        #expect(receipt == savedSVG.source)
        let source = try await store.workflowData(receipt)
        #expect(String(decoding: source, as: UTF8.self).contains(input.sha256))
        try await chat.prepareForBackup()
        let root = store.rootURL.deletingLastPathComponent(), backup = root.appendingPathComponent("Python.dbackup")
        _ = try await store.createBackup(at: backup)
        let destination = root.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let copied = try await restored.chatState(), session = try #require(copied.sessions.first { $0.id == id })
        #expect(session.toolActivities?.last?.status == .completed)
        #expect(session.artifacts == [savedCSV, savedSVG])
        #expect(try await restored.workflowData(try #require(savedCSV.output)) == Data(savedCSV.text.utf8))
        #expect(try await restored.workflowData(try #require(savedSVG.output)) == Data(savedSVG.text.utf8))
        #expect(try await restored.workflowData(receipt) == source)
        #expect(try await restored.workflowData(input) == bytes)
        try await restored.close(); try await store.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_CHAT_PYTHON_TEST_PACKAGE"] != nil))
    func realGuestFailuresRetainDiagnosticsWithoutPublishingAndCanRetry() async throws {
        let (store, chat) = try await fixture(); let id = try chat.newSession()
        try chat.updateDraft("原文 must survive", sessionID: id)
        let cases = [
            ("import sys\nprint('A' + '\\u0301' * 10000, file=sys.stderr)\nraise ValueError('unicode boundary')", "", "stderr truncated"),
            ("print('before failure', flush=True)\nraise ValueError('specific diagnostic')", "before failure", "ValueError: specific diagnostic"),
            ("def broken(:", "", "SyntaxError"),
            ("import sys\nprint('visible-prefix:' + 'x' * 3000, flush=True)\nprint('specific stderr diagnostic', file=sys.stderr, flush=True)\nprint('D_CHAT_FILE_V1:not-json')", "visible-prefix:", "specific stderr diagnostic")
        ]
        for (code, stdout, stderr) in cases {
            await #expect(throws: (any Error).self) { try await chat.executeTool(.python(code: code, inputs: []), sessionID: id) }
            let activity = try #require(chat.selectedSession?.toolActivities?.last)
            #expect(activity.status == .failed)
            #expect(activity.issue?.contains(stderr) == true)
            #expect((activity.issue?.utf8.count ?? 0) <= 16_384)
            if !stdout.isEmpty { #expect(activity.issue?.contains(stdout) == true) }
            #expect(activity.resultJSON == nil && activity.output == nil)
            #expect(chat.selectedSession?.artifacts?.isEmpty != false)
            #expect(chat.selectedSession?.draft == "原文 must survive")
            #expect(!chat.isToolRunning)
        }
        _ = try await chat.executeTool(.python(code: "print('recovered')", inputs: []), sessionID: id)
        #expect(chat.selectedSession?.toolActivities?.last?.status == .completed)
        try await chat.flush()
        let saved = try await store.chatState()
        #expect(saved.sessions.first?.toolActivities?.filter { $0.status == .failed }.count == 4)
        try await store.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_CHAT_PYTHON_TEST_PACKAGE"] != nil))
    func realCancellationKeepsDraftThenNextRequestWorks() async throws {
        let (store, chat) = try await fixture(); let id = try chat.newSession()
        try chat.updateDraft("Keep this", sessionID: id)
        let run = Task { try await chat.executeTool(.python(code: "while True: pass", inputs: []), sessionID: id) }
        for _ in 0..<200 where !chat.isToolRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(chat.isToolRunning)
        try await Task.sleep(for: .milliseconds(150))
        await chat.cancelTool()
        await #expect(throws: (any Error).self) { try await run.value }
        #expect(!chat.isToolRunning && chat.selectedSession?.toolActivities?.last?.status == .cancelled)
        #expect(chat.selectedSession?.draft == "Keep this" && chat.selectedSession?.messages.isEmpty == true)
        _ = try await chat.executeTool(.python(code: "print(42)", inputs: []), sessionID: id)
        #expect(chat.selectedSession?.toolActivities?.last?.status == .completed)
        try await store.close()
    }
}

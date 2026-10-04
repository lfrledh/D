import Foundation
import Testing
@testable import DWorkbench

@Suite("Bounded Python WASI client")
struct ChatPythonTests {
    private func input(_ name: String, _ bytes: Int = 1) -> ChatPythonInput {
        .init(name: name, data: Data(repeating: 65, count: bytes))
    }

    @Test func validatesCodeAndSelectedInputCopies() throws {
        try ChatPythonPolicy.validate(code: " print('👩‍💻')\n", inputs: [input("数据.csv")])
        try ChatPythonPolicy.validate(code: "import os\n", inputs: [])
        for code in ["", " \n", "print(1)\0", String(repeating: "é", count: 32_769)] {
            #expect(throws: ChatPythonError.invalidCode) {
                try ChatPythonPolicy.validate(code: code, inputs: [])
            }
        }
        try ChatPythonPolicy.validate(code: String(repeating: "a", count: 65_536), inputs: [])
        for name in ["", ".", "..", "program.py", "/tmp/a", "../a", "a\\b", "a\n.txt",
                     String(repeating: "a", count: 129), String(repeating: "é", count: 257)] {
            #expect(throws: ChatPythonError.invalidInput) {
                try ChatPythonPolicy.validate(code: "pass", inputs: [input(name)])
            }
        }
        #expect(throws: ChatPythonError.invalidInput) {
            try ChatPythonPolicy.validate(code: "pass", inputs: [input("x"), input("x")])
        }
        #expect(throws: ChatPythonError.invalidInput) {
            try ChatPythonPolicy.validate(code: "pass", inputs: (0...8).map { input("\($0).txt") })
        }
        try ChatPythonPolicy.validate(code: "pass", inputs: [input("a", 2_097_152), input("b", 2_097_152)])
        #expect(throws: ChatPythonError.inputTooLarge) {
            try ChatPythonPolicy.validate(code: "pass", inputs: [input("a", 2_097_153)])
        }
        #expect(throws: ChatPythonError.inputTooLarge) {
            try ChatPythonPolicy.validate(code: "pass", inputs: [input("a", 2_097_152),
                                                                  input("b", 2_097_152), input("c")])
        }
    }

    @Test func decodesOnlyExactFileDeclarationsAndPreservesOtherText() throws {
        let source = "before👩‍💻\nD_CHAT_FILE_V1:{\"name\":\"图表.svg\",\"kind\":\"svg\",\"text\":\"<svg/>\"}\n" +
                     "D_CHAT_FILE_V1:not-json\n"
        // A malformed prefixed line rejects the whole result, even after a valid declaration.
        #expect(throws: ChatPythonError.invalidOutput) {
            try ChatPythonPolicy.decode(stdout: Data(source.utf8), stderr: Data())
        }
        let ordinary = try ChatPythonPolicy.decode(stdout: Data("D_CHAT_FILE_V1 is ordinary text?\n".utf8), stderr: Data())
        #expect(ordinary.stdout == "D_CHAT_FILE_V1 is ordinary text?\n")
        #expect(ordinary.outputs.isEmpty)
        let valid = "before👩‍💻\nD_CHAT_FILE_V1:{\"name\":\"图表.svg\",\"kind\":\"svg\",\"text\":\"<svg/>\"}\nafter\n"
        let result = try ChatPythonPolicy.decode(stdout: Data(valid.utf8), stderr: Data("提醒\n".utf8))
        #expect(result.stdout == "before👩‍💻\nafter\n")
        #expect(result.stderr == "提醒\n")
        #expect(result.outputs == [.init(name: "图表.svg", kind: .svg, text: "<svg/>")])
        #expect(result.pythonVersion == "3.14.8")
        #expect(result.runtimeVersion == "49.0.2")
        #expect(result.engine == "pulley")
        #expect(try JSONDecoder().decode(ChatPythonResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func rejectsUntrustedOutputNamesKindsDuplicatesAndBytes() throws {
        let bad = [
            "{\"name\":\"../x.txt\",\"kind\":\"plainText\",\"text\":\"x\"}",
            "{\"name\":\"program.py\",\"kind\":\"plainText\",\"text\":\"x\"}",
            "{\"name\":\"a.svg\",\"kind\":\"html\",\"text\":\"x\"}",
            "{\"name\":\"a.txt\",\"kind\":\"csv\",\"text\":\"x\"}",
            "{\"name\":\"a.txt\",\"kind\":\"plainText\",\"text\":\"x\\u0000\"}",
            "{\"name\":\"a.txt\",\"kind\":\"plainText\",\"text\":\"x\",\"id\":\"forged\"}",
            "{\"name\":\"a.txt\",\"name\":\"b.txt\",\"kind\":\"plainText\",\"text\":\"x\"}",
            "{\"name\":\"a.txt\",\"kind\":\"plainText\",\"k\\u0069nd\":\"plainText\",\"text\":\"x\"}",
            "{\"name\":\"a.txt\",\"kind\":\"plainText\",\"text\":\"x\",\"text\":\"y\"}",
            "not-json"
        ]
        for declaration in bad {
            #expect(throws: ChatPythonError.invalidOutput) {
                try ChatPythonPolicy.decode(stdout: Data("D_CHAT_FILE_V1:\(declaration)\n".utf8), stderr: Data())
            }
        }
        let line = "D_CHAT_FILE_V1:{\"name\":\"a.txt\",\"kind\":\"plainText\",\"text\":\"x\"}\n"
        #expect(throws: ChatPythonError.invalidOutput) {
            try ChatPythonPolicy.decode(stdout: Data((line + line).utf8), stderr: Data())
        }
        #expect(throws: ChatPythonError.invalidOutput) {
            try ChatPythonPolicy.decode(stdout: Data([0xff]), stderr: Data())
        }
        #expect(throws: ChatPythonError.invalidOutput) {
            try ChatPythonPolicy.decode(stdout: Data(), stderr: Data([0xff]))
        }
        #expect(throws: ChatPythonError.outputTooLarge) {
            try ChatPythonPolicy.decode(stdout: Data(repeating: 65, count: 1_048_576), stderr: Data([65]))
        }
        let oversized = "D_CHAT_FILE_V1:{\"name\":\"a.txt\",\"kind\":\"plainText\",\"text\":\"" +
                        String(repeating: "a", count: 262_145) + "\"}\n"
        #expect(throws: ChatPythonError.outputTooLarge) {
            try ChatPythonPolicy.decode(stdout: Data(oversized.utf8), stderr: Data())
        }
        let nine = (0...8).map {
            "D_CHAT_FILE_V1:{\"name\":\"\($0).txt\",\"kind\":\"plainText\",\"text\":\"x\"}\n"
        }.joined()
        #expect(throws: ChatPythonError.outputTooLarge) {
            try ChatPythonPolicy.decode(stdout: Data(nine.utf8), stderr: Data())
        }
    }

    @Test func packageRequiresExactManifestAndRegularRunnerModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("d-chat-python-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("runner")
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let module = runtime.appendingPathComponent("python.wasm")
        let library = runtime.appendingPathComponent("lib/python3.14", isDirectory: true)
        let manifest = root.appendingPathComponent("engine.json")
        #expect(throws: ChatPythonError.unavailable) { try ChatPythonPolicy.package(at: root) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("fixture only".utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        try Data("wasm fixture only".utf8).write(to: module)
        func writeManifest(engine: String) throws {
            let data: [String: Any] = ["schemaVersion": 1, "kind": "d-chat-python-wasi",
                                       "pythonVersion": "3.14.8", "wasmtimeVersion": "49.0.2", "engine": engine]
            try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        }
        try writeManifest(engine: "pulley")
        #expect(throws: ChatPythonError.unavailable) { try ChatPythonPolicy.package(at: root) }
        try writeManifest(engine: "pulley64")
        #expect(try ChatPythonPolicy.package(at: root).runner == runner)
        try Data(repeating: 65, count: 65_537).write(to: manifest)
        #expect(throws: ChatPythonError.unavailable) { try ChatPythonPolicy.package(at: root) }
        try writeManifest(engine: "pulley64")
        try FileManager.default.removeItem(at: module)
        try FileManager.default.createSymbolicLink(at: module, withDestinationURL: runner)
        #expect(throws: ChatPythonError.unavailable) { try ChatPythonPolicy.package(at: root) }
    }

    @Test func ownedFixtureChildCancelsDrainsCleansAndAllowsNextRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("d-chat-python-lifecycle-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("runner")
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("lib/python3.14"),
                                                withIntermediateDirectories: true)
        try Data("fixture module, never executed".utf8).write(to: runtime.appendingPathComponent("python.wasm"))
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "d-chat-python-wasi",
                                       "pythonVersion": "3.14.8", "wasmtimeVersion": "49.0.2", "engine": "pulley64"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("engine.json"))
        // This fixed, trusted script ignores program.py. It only exercises the client's own Process lifecycle.
        let script = """
        #!/bin/sh
        printf '%s' "$TMPDIR" > "$0.started"
        if [ -f "$0.slow" ]; then
            exec /bin/sleep 30
        fi
        printf '%s\n' 'D_CHAT_FILE_V1:{"name":"answer.txt","kind":"plainText","text":"fixture"}'
        """
        try Data(script.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let slow = root.appendingPathComponent("runner.slow")
        let started = root.appendingPathComponent("runner.started")
        try Data().write(to: slow)
        let client = ChatPythonClient(packageURL: root)
        let task = Task { try await client.run(code: "print('guest only')", inputs: []) }
        defer { task.cancel() }
        var privatePath: String?
        for _ in 0..<100 {
            if let path = try? String(contentsOf: started, encoding: .utf8), !path.isEmpty {
                privatePath = path
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let privatePath else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The owned fixture child did not start")
            return
        }
        #expect(FileManager.default.fileExists(atPath: privatePath))
        task.cancel()
        await #expect(throws: ChatPythonError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: privatePath))

        try FileManager.default.removeItem(at: slow)
        try FileManager.default.removeItem(at: started)
        let result = try await client.run(code: "print('still guest only')", inputs: [])
        #expect(result.outputs == [.init(name: "answer.txt", kind: .plainText, text: "fixture")])
        let nextPath = try String(contentsOf: started, encoding: .utf8)
        #expect(nextPath != privatePath)
        #expect(!FileManager.default.fileExists(atPath: nextPath))
    }
}

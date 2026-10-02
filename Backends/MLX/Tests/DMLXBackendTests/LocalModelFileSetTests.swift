import Foundation
import MLXLMCommon
import Testing
@testable import DMLXBackend

@Suite("Fixed local Qwen file projection")
struct LocalModelFileSetTests {
    @Test func catalogMatchesEightWorkbenchManifests() throws {
        let source = URL(fileURLWithPath: #filePath)
        let root = (0..<5).reduce(source) { url, _ in url.deletingLastPathComponent() }
        let resources = root.appendingPathComponent("Packages/UI/Sources/DWorkbench/Models/Resources")
        let manifests = ["text-model.json", "text-model-1_5b.json", "text-model-7b.json",
                         "text-model-32b.json", "qwen35-9b-bf16.json", "qwen35-9b-q4.json",
                         "qwen38-27b-bf16.json", "qwen38-27b-q4.json"]
        for name in manifests {
            let data = try Data(contentsOf: resources.appendingPathComponent(name))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let revision = try #require(object["revision"] as? String)
            let entries = try #require(object["files"] as? [[String: Any]])
            let expected = Dictionary(uniqueKeysWithValues: try entries.map { entry in
                (try #require(entry["name"] as? String), try #require(entry["size"] as? NSNumber).uint64Value)
            })
            #expect(try LocalModelFileSet.resolve(revision)?.files == expected)
        }
        #expect(try LocalModelFileSet.resolve(nil)?.revision == nil)
        #expect(throws: (any Error).self) { _ = try LocalModelFileSet.resolve("unknown") }
    }

    @Test func independentSelectionsIgnoreExtrasAndRejectMissingOrChangedAdmittedFiles() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LocalModelFileSet(revision: "fixture-a", files: [
            "config.json": 2, "a.safetensors": 9, "chat_template.jinja": 5,
            "generation_config.json": 2,
        ])
        let b = LocalModelFileSet(revision: "fixture-b", files: ["config.json": 2, "b.safetensors": 10])
        try Data("{}".utf8).write(to: first.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 9).write(to: first.appendingPathComponent("a.safetensors"))
        try Data("hello".utf8).write(to: first.appendingPathComponent("chat_template.jinja"))
        try Data("{}".utf8).write(to: first.appendingPathComponent("generation_config.json"))
        try Data("{}".utf8).write(to: second.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 10).write(to: second.appendingPathComponent("b.safetensors"))
        try Data("damaged extra".utf8).write(to: first.appendingPathComponent("b.safetensors"))
        try Data("damaged extra".utf8).write(to: second.appendingPathComponent("a.safetensors"))
        try Data("invalid".utf8).write(to: second.appendingPathComponent("chat_template.jinja"))
        try Data("invalid".utf8).write(to: second.appendingPathComponent("model.safetensors.index.json"))
        try a.validateRequired(in: first)
        try b.validateRequired(in: second)
        #expect(a.weightNames == ["a.safetensors"])
        #expect(b.weightNames == ["b.safetensors"])
        #expect(!b.admits("chat_template.jinja"))
        #expect(!b.admits("model.safetensors.index.json"))
        #expect(a.selection.weightURLs(in: first).map(\.lastPathComponent) == ["a.safetensors"])
        try FileManager.default.removeItem(at: first.appendingPathComponent("chat_template.jinja"))
        #expect(throws: (any Error).self) { try a.validateRequired(in: first) }
        try Data("hello".utf8).write(to: first.appendingPathComponent("chat_template.jinja"))
        try Data("xx".utf8).write(to: first.appendingPathComponent("generation_config.json"))
        #expect(throws: (any Error).self) {
            _ = try decodeAdmittedGenerationConfig(Data(contentsOf: first.appendingPathComponent("generation_config.json")))
        }
        try Data("{}".utf8).write(to: first.appendingPathComponent("generation_config.json"))
        try FileManager.default.removeItem(at: first.appendingPathComponent("a.safetensors"))
        #expect(throws: (any Error).self) { try a.validateRequired(in: first) }
        try Data(repeating: 0, count: 9).write(to: first.appendingPathComponent("a.safetensors"))
        try Data("changed".utf8).write(to: first.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try a.validateRequired(in: first) }
    }

    @Test func admittedGenerationSidecarRejectsCorruptKnownFields() throws {
        let valid = try decodeAdmittedGenerationConfig(Data("{\"eos_token_id\":[1,2],\"stop_strings\":[\"<end>\"]}".utf8))
        #expect(valid.eosTokenIds?.values == [1, 2])
        #expect(throws: (any Error).self) {
            _ = try decodeAdmittedGenerationConfig(Data("{\"stop_strings\":123}".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try decodeAdmittedGenerationConfig(Data("{\"eos_token_id\":\"broken\"}".utf8))
        }
    }
}

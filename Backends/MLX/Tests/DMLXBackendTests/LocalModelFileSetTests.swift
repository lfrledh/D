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
        #expect(try LocalModelFileSet.resolve("unknown")?.revision == nil)
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

    @Test func fixedTokenizerIgnoresUnselectedBrokenSidecars() async throws {
        let directory = try tokenizerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0xff]).write(to: directory.appendingPathComponent("chat_template.jinja"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("chat_template.json"))
        let tokenizer = try await LocalTokenizerLoader(fileSet: tokenizerFiles(in: directory, template: nil)).load(from: directory)
        let rendered = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]],
                                                       tools: nil, additionalContext: ["add_generation_prompt": true])
        #expect(tokenizer.decode(tokenIds: rendered, skipSpecialTokens: false).contains("Hello"))
    }

    @Test func declaredTemplateOverridesEmbeddedTemplate() async throws {
        let directory = try tokenizerFixture(embeddedTemplate: "{{ 'embedded' }}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = "{{ 'selected' }}"
        try Data(selected.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        let tokenizer = try await LocalTokenizerLoader(fileSet: tokenizerFiles(in: directory, template: selected)).load(from: directory)
        let rendered = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]],
                                                       tools: nil, additionalContext: nil)
        let output = tokenizer.decode(tokenIds: rendered, skipSpecialTokens: false)
        #expect(output.contains("selected"))
        #expect(!output.contains("embedded"))
    }

    @Test("Selected template damage fails at load or application", arguments: ["missing", "badUTF8", "syntax", "json"])
    func selectedTemplateDamage(kind: String) async throws {
        let directory = try tokenizerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = kind == "json" ? "chat_template.json" : "chat_template.jinja"
        let content: Data
        switch kind {
        case "badUTF8": content = Data([0xff, 0xfe])
        case "syntax": content = Data("{% if %}".utf8)
        case "json": content = Data("{\"chat_template\": 12}".utf8)
        default: content = Data("{{ 'selected' }}".utf8)
        }
        if kind != "missing" { try content.write(to: directory.appendingPathComponent(name)) }
        let files = LocalModelFileSet(revision: "selected-fixture", files: [
            "tokenizer.json": try fileSize(directory, "tokenizer.json"),
            "tokenizer_config.json": try fileSize(directory, "tokenizer_config.json"),
            name: UInt64(content.count),
        ])
        do {
            let tokenizer = try await LocalTokenizerLoader(fileSet: files).load(from: directory)
            _ = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]],
                                                tools: nil, additionalContext: nil)
            Issue.record("Damaged selected \(name) unexpectedly rendered")
        } catch { /* Loading and template application are both valid rejection points. */ }
    }

    @Test func alternatingFixedLoadersKeepTheirOwnTemplate() async throws {
        let first = try tokenizerFixture()
        let second = try tokenizerFixture()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let a = "{{ 'first' }}", b = "{{ 'second' }}"
        try Data(a.utf8).write(to: first.appendingPathComponent("chat_template.jinja"))
        try Data(b.utf8).write(to: second.appendingPathComponent("chat_template.jinja"))
        let loaderA = LocalTokenizerLoader(fileSet: try tokenizerFiles(in: first, template: a))
        let loaderB = LocalTokenizerLoader(fileSet: try tokenizerFiles(in: second, template: b))
        for expected in ["first", "second", "first", "second"] {
            let tokenizer = try await (expected == "first" ? loaderA : loaderB).load(
                from: expected == "first" ? first : second)
            let ids = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]],
                                                      tools: nil, additionalContext: nil)
            let output = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
            #expect(output.contains(expected))
            #expect(!output.contains(expected == "first" ? "second" : "first"))
        }
    }

    @Test func cleanFixedAndLegacyTokenizersRenderTheSameToolsAndContext() async throws {
        let directory = try tokenizerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try sourceTemplate()
        try Data(source.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        let fixed = try await LocalTokenizerLoader(fileSet: tokenizerFiles(in: directory, template: source)).load(from: directory)
        let legacy = try await LocalTokenizerLoader().load(from: directory)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "Hello"]]
        let tools: [[String: any Sendable]] = [["name": "lookup"]]
        let context: [String: any Sendable] = ["add_generation_prompt": true, "enable_thinking": false]
        let fixedIDs = try fixed.applyChatTemplate(messages: messages, tools: tools, additionalContext: context)
        let legacyIDs = try legacy.applyChatTemplate(messages: messages, tools: tools, additionalContext: context)
        #expect(fixedIDs == legacyIDs)
        #expect(fixed.decode(tokenIds: fixedIDs, skipSpecialTokens: false)
                == legacy.decode(tokenIds: legacyIDs, skipSpecialTokens: false))
        let sample = "Hello, tokenizer!"
        #expect(fixed.encode(text: sample, addSpecialTokens: false)
                == legacy.encode(text: sample, addSpecialTokens: false))
        #expect(fixed.decode(tokenIds: fixed.encode(text: sample, addSpecialTokens: false), skipSpecialTokens: false)
                == legacy.decode(tokenIds: legacy.encode(text: sample, addSpecialTokens: false), skipSpecialTokens: false))
    }

    private func tokenizerFixture(embeddedTemplate: String? = nil) throws -> URL {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]),
                       isDirectory: true).resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("local-tokenizer-" + UUID().uuidString)
        let source = sourceTokenizerDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("tokenizer_config.json"))) as? [String: Any])
        config["chat_template"] = try embeddedTemplate ?? sourceTemplate()
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        return directory
    }

    private func sourceTokenizerDirectory() -> URL {
        let source = URL(fileURLWithPath: #filePath)
        let root = (0..<5).reduce(source) { url, _ in url.deletingLastPathComponent() }
        return root.appendingPathComponent("Vendor/flux2-swift/fixtures/flux2_klein4b/tokenizer")
    }

    private func sourceTemplate() throws -> String {
        let data = try Data(contentsOf: sourceTokenizerDirectory().appendingPathComponent("chat_template.jinja"))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func fileSize(_ directory: URL, _ name: String) throws -> UInt64 {
        UInt64(try Data(contentsOf: directory.appendingPathComponent(name)).count)
    }

    private func tokenizerFiles(in directory: URL, template: String?) throws -> LocalModelFileSet {
        var files = ["tokenizer.json": try fileSize(directory, "tokenizer.json"),
                     "tokenizer_config.json": try fileSize(directory, "tokenizer_config.json")]
        if let template { files["chat_template.jinja"] = UInt64(template.utf8.count) }
        return LocalModelFileSet(revision: "fixture", files: files)
    }
}

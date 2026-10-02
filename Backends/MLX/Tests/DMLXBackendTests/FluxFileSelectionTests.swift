import Foundation
import Flux2
import Testing

@Suite("Verified Flux file selection", .serialized)
struct FluxFileSelectionTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("flux-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func explicitSelectionsAreIndependentAndRejectUnsafeNames() throws {
        for path in ["/absolute", "a/../b", "a//b", "a\\b", ""] {
            #expect(throws: (any Error).self) { try Flux2FileSet(paths: [path]) }
        }
        let root = try fixture(), component = root.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        for name in ["a.safetensors", "b.safetensors", "extra.safetensors"] {
            try Data("not weights".utf8).write(to: component.appendingPathComponent(name))
        }
        let a = try Flux2WeightsLoader(snapshot: root, fileSet: .init(paths: ["transformer/a.safetensors"]))
        let b = try Flux2WeightsLoader(snapshot: root, fileSet: .init(paths: ["transformer/b.safetensors"]))
        #expect(try a.listSafetensors(component: .transformer).map(\.lastPathComponent) == ["a.safetensors"])
        #expect(try b.listSafetensors(component: .transformer).map(\.lastPathComponent) == ["b.safetensors"])
        #expect(try Flux2WeightsLoader(snapshot: root).listSafetensors(component: .transformer).count == 3)
        try FileManager.default.removeItem(at: component.appendingPathComponent("a.safetensors"))
        #expect(throws: (any Error).self) { try a.load(component: .transformer) }
    }

    @Test func undeclaredQuantizationCannotChangePrecisionAndDeclaredDamageRejects() throws {
        let root = try fixture(), file = root.appendingPathComponent("quantization.json")
        try Data("broken optional sidecar".utf8).write(to: file)
        let original = try Flux2FileSet(paths: ["transformer/model.safetensors"])
        #expect(!Flux2Quantizer.hasQuantization(at: root, fileSet: original))
        #expect(try Flux2Quantizer.loadManifest(from: root, fileSet: original) == nil)
        let quantized = try Flux2FileSet(paths: ["quantization.json", "transformer/model.safetensors"])
        #expect(throws: (any Error).self) { try Flux2Quantizer.loadManifest(from: root, fileSet: quantized) }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try Flux2Quantizer.loadManifest(from: root, fileSet: quantized) }
    }

    @Test func undeclaredHigherPrioritySchedulerCannotOverrideFixedConfiguration() throws {
        let root = try fixture(), directory = root.appendingPathComponent("scheduler")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"shift\":3,\"num_train_timesteps\":4}".utf8).write(to: directory.appendingPathComponent("scheduler_config.json"))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("config.json"))
        let selected = try Flux2FileSet(paths: ["scheduler/scheduler_config.json"])
        #expect(try FlowMatchEulerDiscreteScheduler.load(from: root, fileSet: selected).config.shift == 3)
        let other = try Flux2FileSet(paths: ["scheduler/config.json"])
        #expect(throws: (any Error).self) { try FlowMatchEulerDiscreteScheduler.load(from: root, fileSet: other) }
    }

    @Test func undeclaredTemplateIsIgnoredButAdmittedMissingTemplateRejects() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let fixture = repo.appendingPathComponent("Vendor/flux2-swift/fixtures/flux2_klein4b/tokenizer")
        let root = try self.fixture(), directory = root.appendingPathComponent("tokenizer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["tokenizer.json", "tokenizer_config.json"]
        for name in names { try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
        // This fixture normally has a separate template. Embed that same template
        // to exercise a valid selected fallback before adding an unselected one.
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        config["chat_template"] = try String(contentsOf: fixture.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let selected = try Flux2FileSet(paths: Set(names.map { "tokenizer/" + $0 }))
        let before = try Flux2QwenTokenizer.load(from: root, maxLengthOverride: 128, fileSet: selected)
            .encode(prompts: ["A red teapot"], maxLength: 128, truncation: false).inputIds.asArray(Int32.self)
        let extra = directory.appendingPathComponent("chat_template.jinja")
        try Data("{{ raise_exception('must not execute') }}".utf8).write(to: extra)
        let after = try Flux2QwenTokenizer.load(from: root, maxLengthOverride: 128, fileSet: selected)
            .encode(prompts: ["A red teapot"], maxLength: 128, truncation: false).inputIds.asArray(Int32.self)
        #expect(before == after)
        try FileManager.default.removeItem(at: extra)
        let required = try Flux2FileSet(paths: selected.paths.union(["tokenizer/chat_template.jinja"]))
        #expect(throws: (any Error).self) { try Flux2QwenTokenizer.load(from: root, fileSet: required) }
    }
}

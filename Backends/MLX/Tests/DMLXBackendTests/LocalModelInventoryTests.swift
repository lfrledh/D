import DInference
import DMLXBackend
import Foundation
import Testing

@Suite("MLX metadata admission")
struct LocalModelInventoryTests {
    @Test("Estimate reads file sizes, never invalid tensor contents or lifecycle")
    func metadataOnlyEstimate() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let estimate = try await backend.estimate(mlxRequest(directory: fixture.url))
        #expect(estimate.peakBytes > 1024)
        #expect(estimate.confidence == .estimated)
        #expect(await trace.entries().isEmpty)
        await backend.release()
        await backend.release()
        #expect(await trace.entries().isEmpty)
    }

    @Test("Missing and remote model directories are rejected", arguments: [false, true])
    func invalidDirectory(remote: Bool) async throws {
        let directory = remote ? URL(string: "https://example.invalid/model")!
            : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: directory))
    }

    @Test("Unsupported model families are rejected before loading")
    func unsupportedArchitecture() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata(modelType: "unvalidated_model")
        try fixture.writeFakeWeights()
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
    }

    @Test("Weights must be present and nonempty", arguments: [false, true])
    func missingWeights(empty: Bool) async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        if empty { try Data().write(to: fixture.url.appendingPathComponent("model.safetensors")) }
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
    }

    @Test("Backend output and prompt byte limits are enforced", arguments: [false, true])
    func requestLimits(oversizedPrompt: Bool) async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let backend = try MLXTextBackend(configuration: .init(maximumOutputTokens: 32))
        let request = mlxRequest(directory: fixture.url, maxTokens: oversizedPrompt ? 16 : 33,
                                 prompt: oversizedPrompt ? String(repeating: "a", count: 1_048_577) : "Hello")
        await expectAdmissionRejected(backend, request)
    }

    @Test("Oversized model configuration is rejected")
    func oversizedConfiguration() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        try Data(repeating: 0x20, count: 1_048_577).write(to: fixture.url.appendingPathComponent("config.json"))
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
    }

    @Test("Symbolic links cannot make loading inspect a different weight tree")
    func symbolicLinkRejected() async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        try FileManager.default.createSymbolicLink(at: fixture.url.appendingPathComponent("linked.safetensors"),
                                                  withDestinationURL: fixture.url.appendingPathComponent("model.safetensors"))
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
    }

    @Test("Unsafe Qwen dimensions are rejected before model initialization", arguments: [
        "vocabularyZero", "vocabularyOversized", "intermediateZero", "intermediateOversized", "nondividingKVHeads",
    ])
    func unsafeDimensions(field: String) async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let path = fixture.url.appendingPathComponent("config.json")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        switch field {
        case "vocabularyZero": config["vocab_size"] = 0
        case "vocabularyOversized": config["vocab_size"] = Int.max
        case "intermediateZero": config["intermediate_size"] = 0
        case "intermediateOversized": config["intermediate_size"] = Int.max
        default: config["num_key_value_heads"] = 3
        }
        try JSONSerialization.data(withJSONObject: config).write(to: path)
        let backend = try MLXTextBackend()
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
    }

    @Test("Unsupported quantization metadata is rejected before weight loading", arguments: [
        "zeroGroupSize", "unsupportedBits", "perLayerOverride",
    ])
    func unsafeQuantization(field: String) async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let path = fixture.url.appendingPathComponent("config.json")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var quantization: [String: Any] = ["group_size": 64, "bits": 4]
        switch field {
        case "zeroGroupSize": quantization["group_size"] = 0
        case "unsupportedBits": quantization["bits"] = 8
        default: quantization["model.layers.0.self_attn.q_proj"] = ["group_size": 64, "bits": 4]
        }
        config["quantization"] = quantization
        try JSONSerialization.data(withJSONObject: config).write(to: path)
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
        #expect(await trace.entries().isEmpty)
    }

    @Test("Invalid rope factors are rejected during metadata admission", arguments: [false, true])
    func unsafeRopeScaling(stringFactor: Bool) async throws {
        let fixture = try TemporaryModelDirectory()
        defer { fixture.remove() }
        try fixture.writeMetadata()
        try fixture.writeFakeWeights()
        let path = fixture.url.appendingPathComponent("config.json")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let factor: Any = stringFactor ? "2.0" : 0
        config["rope_scaling"] = ["type": "linear", "factor": factor]
        try JSONSerialization.data(withJSONObject: config).write(to: path)
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        if stringFactor {
            // The strict decoder must not coerce an upstream-accepted string to a numeric factor.
            do {
                _ = try await backend.estimate(mlxRequest(directory: fixture.url))
                Issue.record("String-valued rope factor unexpectedly passed admission")
            } catch DecodingError.typeMismatch(let type, _) {
                #expect(ObjectIdentifier(type) == ObjectIdentifier(Float.self))
            } catch { Issue.record("Expected numeric factor decoding failure, received \(error)") }
        } else {
            await expectAdmissionRejected(backend, mlxRequest(directory: fixture.url))
        }
        #expect(await trace.entries().isEmpty)
    }

    @Test("Invalid backend configuration fails at initialization")
    func invalidLimits() {
        #expect(throws: (any Error).self) { _ = try MLXTextBackend(configuration: .init(maximumPromptTokens: 0)) }
        #expect(throws: (any Error).self) { _ = try MLXTextBackend(configuration: .init(maximumOutputTokens: 0)) }
        #expect(throws: (any Error).self) { _ = try MLXTextBackend(configuration: .init(cacheLimitBytes: -1)) }
    }
}

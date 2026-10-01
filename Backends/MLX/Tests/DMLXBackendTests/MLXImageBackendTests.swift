import DInference
import CryptoKit
import Flux2
import MLX
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Klein image loading selection")
struct MLXImageBackendTests {
    @Test("Original VAE scalar is admitted while misplaced or changed scalars fail")
    func layeredScalarPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func metadata(_ name: String, _ dtype: String, _ bytes: Int) throws -> SafeTensorMetadata {
            let url = root.appendingPathComponent(UUID().uuidString + ".safetensors")
            let header = "{\"\(name)\":{\"dtype\":\"\(dtype)\",\"shape\":[],\"data_offsets\":[0,\(bytes)]}}"
            var length = UInt64(header.utf8.count).littleEndian
            var data = withUnsafeBytes(of: &length) { Data($0) }
            data.append(contentsOf: header.utf8)
            data.append(Data(repeating: 0, count: bytes))
            try data.write(to: url)
            let reader = try SafeTensorsReader(fileURL: url)
            return try #require(reader.metadata(for: name))
        }
        let scalar = try metadata("bn.num_batches_tracked", "I64", 8)
        #expect(LocalImageModelInventory.validLayeredTensor(scalar,
            component: "vae/diffusion_pytorch_model.safetensors", firstDataOffset: scalar.dataOffset))
        #expect(!LocalImageModelInventory.validLayeredTensor(scalar,
            component: "transformer/diffusion_pytorch_model.safetensors", firstDataOffset: scalar.dataOffset))
        let wrongKey = try metadata("other.num_batches_tracked", "I64", 8)
        #expect(!LocalImageModelInventory.validLayeredTensor(wrongKey,
            component: "vae/diffusion_pytorch_model.safetensors", firstDataOffset: wrongKey.dataOffset))
        let wrongDType = try metadata("bn.num_batches_tracked", "F64", 8)
        #expect(!LocalImageModelInventory.validLayeredTensor(wrongDType,
            component: "vae/diffusion_pytorch_model.safetensors", firstDataOffset: wrongDType.dataOffset))
        #expect(!LocalImageModelInventory.validLayeredTensor(scalar,
            component: "vae/diffusion_pytorch_model.safetensors", firstDataOffset: scalar.dataOffset - 1))
    }

    @Test("Over 16 GiB original inventory has a bounded layer peak and dimension based workspace")
    func sparseLayeredInventory() throws {
        let template = try LocalImageModelInventory.Manifest.bundled(revision: LocalImageModelInventory.fullRevision)
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = parent.resolvingSymlinksInPath()
            .appendingPathComponent("D-layered-\(UUID().uuidString)")
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        typealias Entry = (String, String, [Int], UInt64)
        func sparse(_ url: URL, _ entries: [Entry]) throws -> UInt64 {
            var tensors: [String: Any] = [:]
            var offset: UInt64 = 0
            for (name, dtype, shape, bytes) in entries {
                tensors[name] = ["dtype": dtype, "shape": shape, "data_offsets": [offset, offset + bytes]]
                offset += bytes
            }
            let header = try JSONSerialization.data(withJSONObject: tensors, options: [.sortedKeys])
            var length = UInt64(header.count).littleEndian
            var prefix = withUnsafeBytes(of: &length) { Data($0) }
            prefix.append(header)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: prefix)
            try handle.truncate(atOffset: UInt64(prefix.count) + offset)
            return UInt64(prefix.count) + offset
        }
        let blockBytes = 224 * 1024 * 1024
        let textEntries: [Entry] = [("model.embed_tokens.weight", "BF16", [1], 2)] +
            (0..<27).map { ("model.layers.\($0).weight", "BF16", [blockBytes / 2], UInt64(blockBytes)) }
        let transformerEntries: [Entry] = [("time_text_embed.weight", "BF16", [1], 2)] +
            (0..<8).map { ("transformer_blocks.\($0).weight", "BF16", [blockBytes / 2], UInt64(blockBytes)) } +
            (0..<48).map { ("single_transformer_blocks.\($0).weight", "BF16", [blockBytes / 2], UInt64(blockBytes)) }
        let vaeEntries: [Entry] = [("bn.num_batches_tracked", "I64", [], 8)] +
            (0..<250).map { ("decoder.weight\($0)", "BF16", [1], 2) }
        var sizes: [String: UInt64] = [:]
        var contents: [String: Data] = [:]
        for file in template.files {
            let url = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.path == "text_encoder/model-00001-of-00002.safetensors" {
                sizes[file.path] = try sparse(url, textEntries)
            } else if file.path == "text_encoder/model-00002-of-00002.safetensors" {
                sizes[file.path] = try sparse(url, [("model.norm.weight", "BF16", [1], 2)])
            } else if file.path == "transformer/diffusion_pytorch_model.safetensors" {
                sizes[file.path] = try sparse(url, transformerEntries)
            } else if file.path == "vae/diffusion_pytorch_model.safetensors" {
                sizes[file.path] = try sparse(url, vaeEntries)
            } else {
                let data: Data
                switch file.path {
                case "text_encoder/config.json":
                    data = Data(#"{"hidden_size":2048,"num_hidden_layers":27,"intermediate_size":8192,"num_attention_heads":16,"rms_norm_eps":0.000001,"vocab_size":100,"num_key_value_heads":8,"head_dim":128}"#.utf8)
                case "transformer/config.json":
                    data = Data(#"{"num_layers":8,"num_single_layers":48}"#.utf8)
                default: data = Data("fixture \(file.path)".utf8)
                }
                try data.write(to: url)
                contents[file.path] = data
                sizes[file.path] = UInt64(data.count)
            }
        }
        let files = template.files.map { file -> LocalImageModelInventory.Manifest.File in
            let digest: String
            if let data = contents[file.path] {
                if file.algorithm == "git-blob-sha1" {
                    var sha = Insecure.SHA1()
                    sha.update(data: Data("blob \(data.count)\0".utf8)); sha.update(data: data)
                    digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
                } else {
                    digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
            } else { digest = String(repeating: "0", count: file.algorithm == "git-blob-sha1" ? 40 : 64) }
            return .init(path: file.path, size: sizes[file.path] ?? 0,
                         sha256: digest, algorithm: file.algorithm)
        }
        let manifest = LocalImageModelInventory.Manifest(schemaVersion: 1, repository: template.repository,
            revision: template.revision, files: files)
        func request(_ width: Int, _ height: Int, reference: ImageReference? = nil) -> InferenceRequest {
            .init(model: .init(directory: model, revision: template.revision),
                  input: .image(.init(prompt: "Test", width: width, height: height,
                                      steps: 4, guidanceScale: 1, seed: 1,
                                      executionProfile: reference == nil
                                          ? ImageExecutionCapability.scalableKlein4B.profile
                                          : ImageExecutionCapability.referenceKlein4B.profile,
                                      referenceImage: reference,
                                      loadingStrategy: .ssdLayered)))
        }
        let small = try LocalImageModelInventory.inspect(request(512, 512), manifest: manifest,
                                                          profile: .scalableKlein4B)
        let large = try LocalImageModelInventory.inspect(request(2048, 2048), manifest: manifest,
                                                          profile: .scalableKlein4B)
        let reference = ImageReference(url: model.appendingPathComponent("reference.rgb"),
            sha256: String(repeating: "0", count: 64), byteCount: 2048 * 2048 * 3,
            width: 2048, height: 2048)
        let conditioned = try LocalImageModelInventory.inspect(request(2048, 2048, reference: reference),
                                                               manifest: manifest, profile: .scalableKlein4B)
        #expect(small.weightBytes > 16 * 1024 * 1024 * 1024)
        #expect(small.estimatedPeakBytes < 16 * 1024 * 1024 * 1024)
        #expect(large.estimatedPeakBytes > small.estimatedPeakBytes)
        #expect(conditioned.estimatedPeakBytes > large.estimatedPeakBytes)
        #expect(conditioned.estimatedPeakBytes > 16 * 1024 * 1024 * 1024)
    }
    @Test("SSD layering rejects the pinned q8 installation before opening weights")
    func layeredRequiresOriginalBF16() throws {
        let image = ImageRequest(prompt: "A test", width: 512, height: 512,
            steps: 4, guidanceScale: 1, seed: 42,
            executionProfile: ImageExecutionCapability.verified512.profile,
            loadingStrategy: .ssdLayered)
        let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/nonexistent/klein"),
            revision: LocalImageModelInventory.revision), input: .image(image))
        do {
            _ = try LocalImageModelInventory.inspect(request)
            Issue.record("Expected the pinned q8 revision to reject SSD layering")
        } catch InferenceFailure.invalidRequest(let message) {
            #expect(message == "SSD layered image loading requires the original pinned Klein BF16 installation.")
        } catch {
            Issue.record("Expected the precision admission error, got \(error)")
        }
    }
}

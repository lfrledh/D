import DInference
import Foundation
import MLXLMCommon

/// Frozen operational paths for the eight registered Qwen revisions. Sizes come from the
/// corresponding DWorkbench catalog manifests; ModelLibrary owns full digest verification.
struct LocalModelFileSet: Sendable {
    let revision: String
    let files: [String: UInt64]
    var selection: ModelFileSelection { ModelFileSelection(paths: Set(files.keys)) }
    var weightNames: [String] { files.keys.filter { $0.hasSuffix(".safetensors") }.sorted() }
    func admits(_ name: String) -> Bool { files[name] != nil }

    func validateRequired(in directory: URL) throws {
        try AudioFileSystem.validateDirectory(directory, label: "Fixed Qwen model")
        for (name, expected) in files {
            guard !name.contains("/"), name != ".", name != ".." else {
                throw InferenceFailure.invalidRequest("Invalid fixed model path.")
            }
            let url = directory.appendingPathComponent(name)
            let identity = try AudioFileSystem.regularFile(url, label: name, maximumBytes: expected)
            guard identity.size >= 0, UInt64(identity.size) == expected else {
                throw InferenceFailure.invalidRequest("Fixed model file is missing or changed: \(name)")
            }
        }
    }

    static func resolve(_ revision: String?) throws -> Self? {
        guard let revision else { return nil } // Explicit legacy directory behavior.
        guard let files = catalog[revision] else {
            throw InferenceFailure.invalidRequest("Unsupported fixed model revision.")
        }
        return Self(revision: revision, files: files)
    }

    private static let catalog: [String: [String: UInt64]] = [
        "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3": ["README.md": 748, "added_tokens.json": 605, "config.json": 783, "merges.txt": 1671853, "model.safetensors": 278064920, "model.safetensors.index.json": 44209, "special_tokens_map.json": 613, "tokenizer.json": 7031673, "tokenizer_config.json": 7308, "vocab.json": 2776833], // text-model.json
        "8b403126fc14f14cfc99bb4cfa72ecbc129ea677": ["README.md": 748, "added_tokens.json": 605, "config.json": 784, "merges.txt": 1671853, "model.safetensors": 868628559, "model.safetensors.index.json": 51569, "special_tokens_map.json": 613, "tokenizer.json": 7031673, "tokenizer_config.json": 7308, "vocab.json": 2776833], // text-model-1_5b.json
        "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed": ["README.md": 732, "added_tokens.json": 605, "config.json": 787, "merges.txt": 1671853, "model.safetensors": 4284346255, "model.safetensors.index.json": 51711, "special_tokens_map.json": 613, "tokenizer.json": 7031673, "tokenizer_config.json": 7280, "vocab.json": 2776833], // text-model-7b.json
        "2938092373e5f97b95538884112085364c2da315": ["README.md": 740, "added_tokens.json": 605, "config.json": 787, "merges.txt": 1671853, "model-00001-of-00004.safetensors": 5366582717, "model-00002-of-00004.safetensors": 5335712920, "model-00003-of-00004.safetensors": 5366641934, "model-00004-of-00004.safetensors": 2362540888, "model.safetensors.index.json": 143017, "special_tokens_map.json": 613, "tokenizer.json": 7031673, "tokenizer_config.json": 7308, "vocab.json": 2776833], // text-model-32b.json
        "c202236235762e1c871ad0ccb60c8ee5ba337b9a": ["LICENSE": 11544, "README.md": 77643, "chat_template.jinja": 7756, "config.json": 3126, "merges.txt": 3353259, "model.safetensors-00001-of-00004.safetensors": 5276436216, "model.safetensors-00002-of-00004.safetensors": 5335161512, "model.safetensors-00003-of-00004.safetensors": 5368717440, "model.safetensors-00004-of-00004.safetensors": 3325995712, "model.safetensors.index.json": 79657, "preprocessor_config.json": 390, "tokenizer.json": 12807982, "tokenizer_config.json": 16710, "video_preprocessor_config.json": 385, "vocab.json": 6722759], // qwen35-9b-bf16.json
        "8b2b98c00a6b4d291155e4890773ca8f769aee53": ["README.md": 666, "chat_template.jinja": 7756, "config.json": 3331, "model-00001-of-00002.safetensors": 5349771222, "model-00002-of-00002.safetensors": 600449850, "model.safetensors.index.json": 123592, "preprocessor_config.json": 390, "processor_config.json": 1300, "tokenizer.json": 19989343, "tokenizer_config.json": 1139, "video_preprocessor_config.json": 385, "vocab.json": 6722759], // qwen35-9b-q4.json
        "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0": ["LICENSE": 11544, "README.md": 65012, "chat_template.jinja": 8952, "config.json": 4312, "crc32.txt": 238, "generation_config.json": 202, "merges.txt": 3353259, "model-00001-of-00018.safetensors": 3966730552, "model-00002-of-00018.safetensors": 3043080328, "model-00003-of-00018.safetensors": 2542796952, "model-00004-of-00018.safetensors": 3988973152, "model-00005-of-00018.safetensors": 2099339864, "model-00006-of-00018.safetensors": 3979553696, "model-00007-of-00018.safetensors": 2108759344, "model-00008-of-00018.safetensors": 3979553696, "model-00009-of-00018.safetensors": 2108759344, "model-00010-of-00018.safetensors": 3979553696, "model-00011-of-00018.safetensors": 2108759344, "model-00012-of-00018.safetensors": 3979553696, "model-00013-of-00018.safetensors": 2108759344, "model-00014-of-00018.safetensors": 3979553696, "model-00015-of-00018.safetensors": 2108759344, "model-00016-of-00018.safetensors": 3979564040, "model-00017-of-00018.safetensors": 2108759344, "model-00018-of-00018.safetensors": 3392197344, "model.safetensors.index.json": 112216, "preprocessor_config.json": 390, "tokenizer.json": 12809320, "tokenizer_config.json": 17928, "video_preprocessor_config.json": 385, "vocab.json": 6722759], // qwen38-27b-bf16.json
        "10c35caafbb80f7dc6a7a432cdd11af10a6d4818": ["README.md": 632, "chat_template.jinja": 8952, "config.json": 4932, "generation_config.json": 202, "model-00001-of-00003.safetensors": 5343268662, "model-00002-of-00003.safetensors": 5354185130, "model-00003-of-00003.safetensors": 5357087557, "model.safetensors.index.json": 218281, "preprocessor_config.json": 390, "processor_config.json": 991, "tokenizer.json": 19989325, "tokenizer_config.json": 1165, "video_preprocessor_config.json": 385, "vocab.json": 6722759], // qwen38-27b-q4.json
    ]
}

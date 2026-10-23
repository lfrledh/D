import Foundation

/// Published rounded logical counts. Packed quantized file element counts are not parameter counts.
public struct ModelParameterScale: Equatable, Sendable {
    public enum Scope: Sendable { case total, languageModel, transformer, vocoder, officialPublished }
    public let publishedBillions: String
    public let activeBillions: String?
    public let scope: Scope
    public let sourceURLs: [String]
    public let checkedAt: String
    public let noteKey: String?
    public init(publishedBillions: String, activeBillions: String?, scope: Scope, sourceURLs: [String], checkedAt: String, noteKey: String? = nil) {
        self.publishedBillions = publishedBillions; self.activeBillions = activeBillions; self.scope = scope
        self.sourceURLs = sourceURLs; self.checkedAt = checkedAt; self.noteKey = noteKey
    }
}
public extension ModelNodeDescriptor {
    var parameterScale: ModelParameterScale? { ModelNodeCatalog.parameterScale(modelIdentity: modelIdentity, revision: revision) }
    var weightSummary: String? {
        if let value = ModelNodeCatalog.weightSummaries[modelIdentity + "@" + revision] { return value }
        guard ModelNodeCatalog.entries.contains(where: { $0.id == id && $0.modelIdentity == modelIdentity && $0.revision == revision }) else { return nil }
        switch id {
        case "flux2-klein-4b-q8": return "model.spec.weight.q8Compute"
        case "flux2-klein-4b-bf16", "flux2-dev-bf16": return "BF16"
        case "sm-music", "sm-sfx", "medium": return "FP16 · codec FP32"
        case "wan21-t2v-1.3b-bf16-v1": return "model.spec.weight.wanMixed"
        case "ace-step-1.5-xl-sft-f32-no-lm": return "FP32"
        case "audio.singing.qixuan": return "model.spec.weight.acoustic"
        case "mrt2-small-export-v1": return "model.spec.weight.graphUnknown"
        case "swift-f0-0.1.2-cpu-v1": return "model.spec.weight.inputOnly"
        case "video.model.minimax-h3-fl2va-bf16-full-v1", "video.model.ltx-2.3-dev-bf16-full-v1", "video.model.ltx-2.5-dev-bf16-full-v1": return "BF16"
        case "video.model.ltx-2.3-dev-q8-gemma3-q4-test-v1": return "model.spec.weight.ltxMixed"
        default: return nil
        }
    }
    var unrecordedScaleReasonKey: String? {
        guard ModelNodeCatalog.entries.contains(where: { $0.id == id && $0.modelIdentity == modelIdentity && $0.revision == revision }) else { return nil }
        switch id {
        case "flux2-klein-4b-q8": return "model.spec.unknown.convertedCount"
        case "sm-music", "sm-sfx": return "model.spec.unknown.stableAudioConflict"
        case "swift-f0-0.1.2-cpu-v1": return "model.spec.unknown.swiftVersion"
        case "video.model.ltx-2.5-dev-bf16-full-v1": return "model.spec.unknown.ltx25"
        default: return nil
        }
    }
}
public extension ModelNodeCatalog {
    fileprivate static let weightSummaries: [String: String] = Dictionary(
        (((try? TextModelProfiles.registered()) ?? []) + ((try? TextModelProfiles.registeredVLM()) ?? [])).map {
            ($0.repository + "@" + $0.revision, $0.quantizationBits == 0 ? "BF16" : "Q\($0.quantizationBits) · affine")
        }, uniquingKeysWith: { first, _ in first })
    static func parameterScale(modelIdentity: String, revision: String) -> ModelParameterScale? {
        switch (modelIdentity, revision) {
        case ("mlx-community/Qwen2.5-0.5B-Instruct-4bit", "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"):
            return .init(publishedBillions: "0.49", activeBillions: nil, scope: .total, sourceURLs: ["https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/raw/7ae557604adf67be50417f59c2c2f167def9a775/README.md", "https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit/raw/a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3/README.md"], checkedAt: "2026-10-21")
        case ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"):
            return .init(publishedBillions: "1.54", activeBillions: nil, scope: .total, sourceURLs: ["https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/raw/989aa7980e4cf806f80c7fef2b1adb7bc71aa306/README.md", "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit/raw/8b403126fc14f14cfc99bb4cfa72ecbc129ea677/README.md"], checkedAt: "2026-10-21")
        case ("mlx-community/Qwen2.5-7B-Instruct-4bit", "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed"):
            return .init(publishedBillions: "7.61", activeBillions: nil, scope: .total, sourceURLs: ["https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/raw/a09a35458c702b33eeacc393d103063234e8bc28/README.md", "https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit/raw/c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed/README.md"], checkedAt: "2026-10-21")
        case ("mlx-community/Qwen2.5-32B-Instruct-4bit", "2938092373e5f97b95538884112085364c2da315"):
            return .init(publishedBillions: "32.5", activeBillions: nil, scope: .total, sourceURLs: ["https://huggingface.co/Qwen/Qwen2.5-32B-Instruct/raw/5ede1c97bbab6ce5cda5812749b4c0bdf79b18dd/README.md", "https://huggingface.co/mlx-community/Qwen2.5-32B-Instruct-4bit/raw/2938092373e5f97b95538884112085364c2da315/README.md"], checkedAt: "2026-10-21")
        case ("Qwen/Qwen3.5-9B", "c202236235762e1c871ad0ccb60c8ee5ba337b9a"):
            return .init(publishedBillions: "9", activeBillions: nil, scope: .languageModel, sourceURLs: ["https://huggingface.co/Qwen/Qwen3.5-9B/raw/c202236235762e1c871ad0ccb60c8ee5ba337b9a/README.md"], checkedAt: "2026-10-21")
        case ("mlx-community/Qwen3.5-9B-4bit", "8b2b98c00a6b4d291155e4890773ca8f769aee53"):
            return .init(publishedBillions: "9", activeBillions: nil, scope: .languageModel, sourceURLs: ["https://huggingface.co/Qwen/Qwen3.5-9B/raw/c202236235762e1c871ad0ccb60c8ee5ba337b9a/README.md", "https://huggingface.co/mlx-community/Qwen3.5-9B-4bit/raw/8b2b98c00a6b4d291155e4890773ca8f769aee53/README.md"], checkedAt: "2026-10-21")
        case ("Qwen/Qwen3.8-27B", "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"):
            return .init(publishedBillions: "27", activeBillions: nil, scope: .languageModel, sourceURLs: ["https://huggingface.co/Qwen/Qwen3.8-27B/raw/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/README.md"], checkedAt: "2026-10-21")
        case ("mlx-community/Qwen3.8-27B-4bit", "10c35caafbb80f7dc6a7a432cdd11af10a6d4818"):
            return .init(publishedBillions: "27", activeBillions: nil, scope: .languageModel, sourceURLs: ["https://huggingface.co/Qwen/Qwen3.8-27B/raw/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/README.md", "https://huggingface.co/mlx-community/Qwen3.8-27B-4bit/raw/10c35caafbb80f7dc6a7a432cdd11af10a6d4818/README.md"], checkedAt: "2026-10-21")
        case ("black-forest-labs/FLUX.2-klein-4B", "e7b7dc27f91deacad38e78976d1f2b499d76a294"):
            return .init(publishedBillions: "4", activeBillions: nil, scope: .transformer, sourceURLs: ["https://huggingface.co/black-forest-labs/FLUX.2-klein-4B/raw/e7b7dc27f91deacad38e78976d1f2b499d76a294/README.md"], checkedAt: "2026-10-21")
        case ("black-forest-labs/FLUX.2-dev", "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c"):
            // Public official model card; fixed revision README required authorization.
            return .init(publishedBillions: "32", activeBillions: nil, scope: .transformer,
                sourceURLs: ["https://huggingface.co/black-forest-labs/FLUX.2-dev"], checkedAt: "2026-10-21")
        case ("google/magenta-realtime-2 · mrt2_small", "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"):
            return .init(publishedBillions: "0.23", activeBillions: nil, scope: .transformer, sourceURLs: ["https://huggingface.co/google/magenta-realtime-2/blob/010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc/README.md"], checkedAt: "2026-10-21", noteKey: "model.spec.note.mrt2")
        case ("ACE-Step/acestep-v15-xl-sft", "d06de46b4622f781cf07f4a013a67d591ca52819"):
            return .init(publishedBillions: "4", activeBillions: nil, scope: .transformer, sourceURLs: ["https://huggingface.co/ACE-Step/acestep-v15-xl-sft/blob/d06de46b4622f781cf07f4a013a67d591ca52819/README.md"], checkedAt: "2026-10-21", noteKey: "model.spec.note.ace")
        case ("Wan-AI/Wan2.1-T2V-1.3B", "37ec512624d61f7aa208f7ea8140a131f93afc9a"):
            return .init(publishedBillions: "1.3", activeBillions: nil, scope: .transformer, sourceURLs: ["https://huggingface.co/Wan-AI/Wan2.1-T2V-1.3B/blob/37ec512624d61f7aa208f7ea8140a131f93afc9a/README.md"], checkedAt: "2026-10-21", noteKey: "model.spec.note.wan")
        case ("MiniMaxAI/MiniMax-H3 · FL2VA", "42ed227ee7df40d41602854ae760620d6eb651fe"):
            return .init(publishedBillions: "33", activeBillions: nil, scope: .transformer, sourceURLs: ["https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/42ed227ee7df40d41602854ae760620d6eb651fe/README.md"], checkedAt: "2026-10-21", noteKey: "model.spec.note.minimax")
        case ("Qixuan 绮萱 2.7.0 DiffSinger/OpenUtau ONNX + nvidia/bigvgan_v2_44khz_128band_512x", "BigVGAN 95a9d1dcb12906c03edd938d77b9333d6ded7dfb · Qixuan 2.7.0 fixture-bound"):
            return .init(publishedBillions: "0.122", activeBillions: nil, scope: .vocoder, sourceURLs: ["https://huggingface.co/nvidia/bigvgan_v2_44khz_128band_512x/raw/95a9d1dcb12906c03edd938d77b9333d6ded7dfb/README.md"], checkedAt: "2026-10-21", noteKey: "model.spec.note.qixuan")
        case ("stabilityai/stable-audio-3-optimized / medium", "da6edc54ddba10bfd79a077102ded687f80e882b"):
            return .init(publishedBillions: "1.4", activeBillions: nil, scope: .transformer, sourceURLs: ["https://arxiv.org/html/2605.17991v1"], checkedAt: "2026-10-21", noteKey: "model.spec.note.stableAudio")
        case ("Lightricks/LTX · dev", "cfc837526e56abf8657823a0ae192eec3a40177d"):
            return .init(publishedBillions: "20.9", activeBillions: nil, scope: .officialPublished, sourceURLs: ["https://ltx.io/newsroom/ltx-2-3-offers-creative-intelligence-without-the-cloud-costs"], checkedAt: "2026-10-21", noteKey: "model.spec.note.ltx23")
        case ("Lightricks/LTX · dev", "6671a7572a530862d1d60ce393b5d93491e3f76b"):
            return .init(publishedBillions: "20.9", activeBillions: nil, scope: .officialPublished, sourceURLs: ["https://ltx.io/newsroom/ltx-2-3-offers-creative-intelligence-without-the-cloud-costs"], checkedAt: "2026-10-21", noteKey: "model.spec.note.ltx23q8")
        default: return nil
        }
    }
}

import Foundation
import DInference

/// Explicit operation identity. Titles and description strings never choose a backend.
public enum WorkflowModelRoutes {
    public static let qwen35 = "d.model.qwen35-9b"
    public static let qwen38 = "d.model.qwen38-27b"
    public static let fluxDev = "d.image.flux2-dev"
    public static let ace = "d.music.ace-step-1.5-xl-sft"
    public static func isLanguage(_ id: String) -> Bool { ["d.model.language", qwen35, qwen38].contains(id) }
    public static func isImage(_ id: String) -> Bool { ["d.image.generate", fluxDev].contains(id) }
    public static func operation(for choice: WorkflowModelChoice) -> String? {
        if let entry = try? ModelCatalog.entries().first(where: { choice.id == choice.kind.rawValue + ":" + $0.revision }),
           let operation = entry.workflowProfileID { return operation }
        if choice.kind == .text, let profile = try? TextModelProfiles.registeredVLM().first(where: { "text:" + $0.revision == choice.id }) {
            return profile.repository.contains("Qwen3.8-27B") ? qwen38 : qwen35
        }
        if choice.id == "image:26afe3a78bb242c0a8bb181dcc8937bb16e5c66c" { return fluxDev }
        if choice.id == "music:d06de46b4622f781cf07f4a013a67d591ca52819" { return ace }
        return nil
    }

    /// Fixed descriptive routes may be placed as drafts before installation.
    /// This lookup is not registration, readiness, or runtime admission.
    public static func draftChoice(operationID: String, modelID: String) -> WorkflowModelChoice? {
        draftRoutes.first { $0.choice.id == modelID && ($0.operation == operationID || legacyTextOperations(identity: modelID).contains(operationID)) }?.choice
    }
    /// The existing Qwen2.5 backend implements exactly these two prompt operations.
    /// No type/title similarity grants compatibility to other models or operations.
    public static func legacyTextOperations(identity: String) -> Set<String> {
        legacyTextIdentities.contains(identity) ? ["d.model.language", "d.text.rewrite"] : []
    }
    private static let legacyTextIdentities = Set(((try? TextModelProfiles.registered()) ?? []).map { "text:" + $0.revision })
    public static func supports(_ entry: ModelCatalogEntry, operationID: String, identity: String) -> Bool {
        guard entry.workflowIdentity == identity else { return false }
        if entry.workflowProfileID == operationID { return true }
        return entry.workflowProfileID == "d.model.language" && identity == "text:" + entry.revision && legacyTextOperations(identity: identity).contains(operationID)
    }
    /// A restriction from the fixed adapter catalog, not a claim of runtime readiness.
    /// Unknown/local identities still require the backend's full inventory validation.
    public static func rejectsTextLoading(modelIdentity: String?, strategy: String) -> Bool {
        strategy == "ssdLayered" && modelIdentity.map(quantizedVLMIdentities.contains) == true
    }
    private static let quantizedVLMIdentities = Set(((try? TextModelProfiles.registeredVLM()) ?? [])
        .filter { $0.quantizationBits > 0 }.map { "text:" + $0.revision })

    private static let draftRoutes: [(operation: String, choice: WorkflowModelChoice)] = {
        let textIDs = Set((((try? TextModelProfiles.registered()) ?? [])
            + ((try? TextModelProfiles.registeredVLM()) ?? [])).map(\.id))
        return ModelNodeCatalog.entries.compactMap { descriptor in
            let video = ExternalVideoExecutionProfile.allCases.first { descriptor.id == "video.model." + $0.rawValue }
            let kind: WorkflowModelKind
            if video != nil { kind = .video }
            else if textIDs.contains(descriptor.modelIdentity) { kind = .text }
            else {
                switch descriptor.id {
                case "flux2-klein-4b-q8", "flux2-klein-4b-bf16", "flux2-dev-bf16": kind = .image
                case "mrt2-small-export-v1", "ace-step-1.5-xl-sft-f32-no-lm": kind = .music
                case "wan21-t2v-1.3b-bf16-v1": kind = .video
                case "swift-f0-0.1.2-cpu-v1": kind = .pitch
                default: return nil
                }
            }
            let choice = WorkflowModelChoice(id: kind.rawValue + ":" + (video?.modelIdentity ?? descriptor.revision),
                kind: kind, displayName: descriptor.title)
            let fallback: String
            switch kind {
            case .text: fallback = "d.model.language"
            case .image: fallback = "d.image.generate"
            case .music: fallback = "d.music.generate"
            case .video: fallback = "d.video.generate"
            case .pitch: fallback = "d.music.pitch"
            }
            let route = video.map { WorkflowVideoRecipe(profile: $0).operationID }
                ?? operation(for: choice) ?? fallback
            return (route, choice)
        }
    }()

}

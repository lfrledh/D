import Foundation

/// Explicit operation identity. Titles and description strings never choose a backend.
public enum WorkflowModelRoutes {
    public static let qwen35 = "d.model.qwen35-9b"
    public static let qwen38 = "d.model.qwen38-27b"
    public static let fluxDev = "d.image.flux2-dev"
    public static let ace = "d.music.ace-step-1.5-xl-sft"
    public static func isLanguage(_ id: String) -> Bool { ["d.model.language", qwen35, qwen38].contains(id) }
    public static func isImage(_ id: String) -> Bool { ["d.image.generate", fluxDev].contains(id) }
    public static func operation(for choice: WorkflowModelChoice) -> String? {
        if choice.kind == .text, let profile = try? TextModelProfiles.registeredVLM().first(where: { "text:" + $0.revision == choice.id }) {
            return profile.repository.contains("Qwen3.8-27B") ? qwen38 : qwen35
        }
        if choice.id == "image:26afe3a78bb242c0a8bb181dcc8937bb16e5c66c" { return fluxDev }
        if choice.id == "music:d06de46b4622f781cf07f4a013a67d591ca52819" { return ace }
        return nil
    }
}

import Foundation

/// Portable settings, not model installation instructions or an executable tool.
public enum ChatPresetFile {
    private struct Envelope: Codable {
        var version = 1
        var presets: [ChatPromptPreset]
    }
    public static func encode(_ presets: [ChatPromptPreset]) throws -> Data {
        try validate(presets)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(presets: presets))
        guard data.count <= 2_097_152 else { throw WorkflowIssue("Chat preset file exceeds 2 MiB.", code: "chat.presetFile.tooLarge") }
        return data
    }
    /// Returns a preview; importing does not apply anything to a conversation.
    public static func decode(_ data: Data) throws -> [ChatPromptPreset] {
        guard !data.isEmpty, data.count <= 2_097_152 else { throw WorkflowIssue("Chat preset file is empty or exceeds 2 MiB.", code: "chat.presetFile.emptyOrTooLarge") }
        let value: Envelope
        do { value = try JSONDecoder().decode(Envelope.self, from: data) }
        catch let error as DecodingError {
            // Only structural decoding belongs here. Validation and I/O retain
            // their distinct reasons; preserve the original diagnostic verbatim.
            throw WorkflowIssue(String(describing: error), code: "chat.presetFile.invalidStructure")
        }
        guard value.version == 1 else { throw WorkflowIssue("Chat preset version is unsupported.", code: "chat.presetFile.unsupportedVersion") }
        try validate(value.presets)
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        guard original == encoded else { throw WorkflowIssue("Chat preset file has unknown or unsupported fields; nothing was imported.", code: "chat.presetFile.unsupportedFields") }
        return value.presets
    }
    private static func validate(_ presets: [ChatPromptPreset]) throws {
        guard presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WorkflowIssue("A new chat preset name cannot be blank.", code: "chat.presetFile.blankName")
        }
        var state = ChatState(); state.presets = presets; try state.validate()
    }
}

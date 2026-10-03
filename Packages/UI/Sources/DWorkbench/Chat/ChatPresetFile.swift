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
        guard data.count <= 2_097_152 else { throw WorkflowIssue("预设文件超过2MiB。") }
        return data
    }
    /// Returns a preview; importing does not apply anything to a conversation.
    public static func decode(_ data: Data) throws -> [ChatPromptPreset] {
        guard !data.isEmpty, data.count <= 2_097_152 else { throw WorkflowIssue("预设文件为空或超过2MiB。") }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.version == 1 else { throw WorkflowIssue("预设版本不支持。") }
        try validate(value.presets)
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        guard original == encoded else { throw WorkflowIssue("预设包含未知或无法保留的字段；未导入。") }
        return value.presets
    }
    private static func validate(_ presets: [ChatPromptPreset]) throws {
        guard presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WorkflowIssue("新预设名称不能为空白。")
        }
        var state = ChatState(); state.presets = presets; try state.validate()
    }
}

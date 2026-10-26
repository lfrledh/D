import Foundation

public enum WorkflowInputCompatibility: String, Sendable { case direct, conversion, unverified, incompatible }
public struct WorkflowInputCompatibilityResult: Sendable, Equatable {
    public let status: WorkflowInputCompatibility
    public let reason: String
    public let converter: String?
    public var reasonCode: String = "diagnostic"
}

/// One receiving port, shared with historical-input admission. This is not whole
/// node admission: other required inputs, installation and execution remain separate.
public struct WorkflowInputContract: Sendable {
    public let node: WorkflowNode
    public let port: WorkflowPortDefinition
    public let schema: WorkflowDataSchema?
    public init(step: WorkflowPlannedStep, portID: String, tools: [WorkflowToolDefinition] = [], registry: WorkflowRegistry = .standard) throws {
        node = step.node
        if case .invoke(_, let body) = step.kind, let field = body.interface.inputs.first(where: { $0.name == portID }) {
            port = .init(portID, field.name, kinds: field.type.portKinds); schema = field.type
        } else {
            guard let input = registry.definition(for: step.node, tools: tools)?.inputs.first(where: { $0.id == portID }) else { throw WorkflowIssue("接收端口不存在。") }
            port = input
            if case .loop(_, let state, _, _) = step.kind, portID == "input" { schema = state }
            else { schema = step.node.dataConfiguration?.fields.first(where: { $0.name == portID })?.type }
        }
    }
    private var specializedKind: WorkflowDataKind? {
        switch (node.operationID, port.id) {
        case ("d.music.align", "input"), ("d.music.keys", "input"), ("d.music.render", "input"), ("d.music.generate", "notes"): .notes
        case ("d.music.chords", "input"), ("d.music.generate", "chords"): .chords
        case ("d.music.align", "tempo"): .tempo
        default: nil
        }
    }
    // Legacy fact values remain stable for saved searches; never select a
    // validator by translated display text.
    public var specializedConcept: String? {
        switch specializedKind {
        case .notes: "音符序列"
        case .chords: "和弦轨"
        case .tempo: "速度映射"
        default: nil
        }
    }
    public func validate(_ value: WorkflowValue) throws {
        guard port.kinds.contains(value.kind) else { throw WorkflowIssue("内容类型与接收端口不匹配。", nodeID: node.id, port: port.id) }
        if port.assetListKind != nil { _ = try port.resolveAssets(value) }
        if let schema {
            guard let datum = value.datum else { throw WorkflowIssue("接收端需要明确的数据结构。") }
            try datum.validate(as: schema)
        }
        switch value {
        case .data(let datum):
            try datum.validate()
            switch value.asset == nil ? specializedKind : nil {
            case .notes: _ = try WorkflowNoteSequence(datum: datum)
            case .chords: _ = try WorkflowChordTrack(datum: datum)
            case .tempo: _ = try WorkflowTempoMap(datum: datum)
            default: break
            }
        case .asset(let reference):
            guard reference.sha256.count == 64, reference.sha256.allSatisfy({ $0.isHexDigit }) else { throw WorkflowIssue("资产摘要无效。") }
        case .collection(let values):
            guard Set(values.map(\.id)).count == values.count else { throw WorkflowIssue("候选身份重复。") }
        case .receipt(let receipt):
            guard receipt.names.count == receipt.hashes.count else { throw WorkflowIssue("导出回执结构无效。") }
        }
    }
    public func compatibility(with value: WorkflowValue, decodedAsset: WorkflowDatum? = nil) -> WorkflowInputCompatibilityResult {
        do {
            try validate(value)
            if specializedKind != nil && value.asset != nil {
                guard let decodedAsset else { return .init(status: .unverified, reason: "需读取并验证专用数据；文件类型不能证明结构兼容。", converter: nil, reasonCode: "specialized") }
                switch specializedKind {
                case .notes: _ = try WorkflowNoteSequence(datum: decodedAsset)
                case .chords: _ = try WorkflowChordTrack(datum: decodedAsset)
                case .tempo: _ = try WorkflowTempoMap(datum: decodedAsset)
                default: break
                }
            }
            if schema == nil && specializedKind == nil && [.record, .list, .optional, .result, .notes, .chords, .tempo, .pitch].contains(value.kind) && port.assetListKind == nil {
                return .init(status: .unverified, reason: "接收端未声明足够精确的结构契约。", converter: nil, reasonCode: "contract")
            }
            return .init(status: .direct, reason: "符合此输入的已声明结构；其他输入与运行条件另行校验。", converter: nil, reasonCode: "direct")
        } catch {
            if let schema, case .data(.text(let text)) = value, (try? WorkflowStructuredText.parse(text, as: schema)) != nil {
                return .init(status: .conversion, reason: "可经 JSON 检查（严格）再读取报告的 data 字段得到接收结构；不会自动转换。", converter: "d.value.validate", reasonCode: "conversion")
            }
            return .init(status: .incompatible, reason: error.localizedDescription, converter: nil)
        }
    }
    public static func conceptIdentity(of datum: WorkflowDatum) -> SharedLibraryConcept? {
        if (try? WorkflowNoteSequence(datum: datum)) != nil { return .structured(.notes) }
        if (try? WorkflowChordTrack(datum: datum)) != nil { return .structured(.chords) }
        if (try? WorkflowTempoMap(datum: datum)) != nil { return .structured(.tempo) }
        return nil
    }
    /// Compatibility for existing callers; never used to select a validator.
    public static func concept(of datum: WorkflowDatum) -> String? { conceptIdentity(of: datum)?.wireValue }
}

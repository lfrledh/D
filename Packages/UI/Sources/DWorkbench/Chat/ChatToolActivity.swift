import Foundation

/// Explicit operations only; model prose never invokes these tools.
public enum ChatToolRequest: Codable, Sendable, Equatable {
    case calculator(ChatDeterministicTools.ArithmeticRequest)
    case units(ChatDeterministicTools.UnitRequest)
    case time(ChatDeterministicTools.TimeRequest)
    case csv(WorkflowAssetReference, columns: [String])
    case webSearch(query: String, language: ChatWebLanguage)
    case webRead(ChatWebSearchHit)

    public var identifier: String {
        switch self {
        case .calculator: "d.chat.calculate.v1"
        case .units: "d.chat.units.v1"
        case .time: "d.chat.time.v1"
        case .csv: "d.chat.csv.v1"
        case .webSearch: "d.chat.wikipedia.search.v1"
        case .webRead: "d.chat.wikipedia.read.v1"
        }
    }
    public var usesNetwork: Bool {
        switch self { case .webSearch, .webRead: true; default: false }
    }
    public var parents: [WorkflowAssetReference] {
        if case .csv(let reference, _) = self { [reference] } else { [] }
    }
}

public struct ChatToolActivity: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let request: ChatToolRequest
    public let startedAt: Date
    public var endedAt: Date?
    public var status: Status
    /// Persisted before publication, so a save retry never repeats a network/tool call.
    public var resultJSON: String?
    public var output: WorkflowAssetReference?
    public var issue: String?
    public init(id: UUID = UUID(), request: ChatToolRequest) {
        self.id = id; self.request = request; startedAt = Date(); status = .running
    }
    public func validate() throws {
        let requestBytes = try JSONEncoder().encode(request)
        guard requestBytes.count <= 65_536, (resultJSON?.utf8.count ?? 0) <= 2_097_152,
              (issue?.utf8.count ?? 0) <= 16_384, output == nil || output?.kind == .text,
              status != .completed || resultJSON != nil else { throw WorkflowIssue("工具记录大小或结果无效。") }
    }
}

public struct ChatWebOptions: Codable, Sendable, Equatable {
    public var allowed = false
    public var automaticSearch = false
    public var language: ChatWebLanguage = .zh
    public init() {}
}

extension ChatToolRequest {
    func execute(store: ProjectStore, authorized: Bool, web: ChatWebSearchClient) async throws -> String {
        @Sendable func encoded<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(value)
            guard data.count <= 2_097_152 else { throw WorkflowIssue("工具结果超过保存预算；没有截断结果。") }
            return String(decoding: data, as: UTF8.self)
        }
        switch self {
        case .calculator(let request): return try await WorkflowCPU.run { try encoded(ChatDeterministicTools.calculate(request)) }
        case .units(let request): return try await WorkflowCPU.run { try encoded(ChatDeterministicTools.convert(request)) }
        case .time(let request): return try await WorkflowCPU.run { try encoded(ChatDeterministicTools.convert(request)) }
        case .csv(let reference, let columns):
            guard reference.kind == .text else { throw WorkflowIssue("CSV分析需要选定的文字资产。") }
            let bytes = try await store.workflowData(reference)
            return try await WorkflowCPU.run { try encoded(ChatDeterministicTools.analyze(.init(csvData: bytes, numericColumns: columns))) }
        case .webSearch(let query, let language): return try encoded(await web.search(query, language: language, networkAuthorized: authorized))
        case .webRead(let hit): return try encoded(await web.readPage(hit, networkAuthorized: authorized))
        }
    }
}

/// Tool records may advance while the sending input must stay fixed across every await.
struct ChatAutomaticWebInput {
    private let captured: ChatSession
    init(_ session: ChatSession) { captured = session }
    func validate(_ current: ChatSession, addedAttachment: ChatAttachment? = nil) throws {
        var comparable = current
        comparable.toolActivities = captured.toolActivities
        if let addedAttachment, !captured.attachments.contains(where: { $0.reference == addedAttachment.reference }) {
            guard comparable.attachments.filter({ $0.reference == addedAttachment.reference }) == [addedAttachment] else {
                throw WorkflowIssue("The adopted web source changed or was removed; no model request was sent.")
            }
            comparable.attachments.removeAll { $0.reference == addedAttachment.reference }
        }
        guard comparable == captured else {
            throw WorkflowIssue("The conversation changed while preparing web sources. Results remain saved; no model request was sent.")
        }
    }
}

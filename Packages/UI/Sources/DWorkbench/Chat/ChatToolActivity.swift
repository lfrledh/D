import Foundation

/// Explicit operations only; model prose never invokes these tools.
public enum ChatToolRequest: Codable, Sendable, Equatable {
    case calculator(ChatDeterministicTools.ArithmeticRequest)
    case units(ChatDeterministicTools.UnitRequest)
    case time(ChatDeterministicTools.TimeRequest)
    case csv(WorkflowAssetReference, columns: [String])
    case python(code: String, inputs: [WorkflowAssetReference])
    case webSearch(query: String, language: ChatWebLanguage)
    case webRead(ChatWebSearchHit)
    case providerSearch(query: String, provider: ChatSearchProvider)
    case pageRead(URL)
    case mcp(endpoint: String, tool: String, argumentsJSON: String)

    public var identifier: String {
        switch self {
        case .calculator: "d.chat.calculate.v1"
        case .units: "d.chat.units.v1"
        case .time: "d.chat.time.v1"
        case .csv: "d.chat.csv.v1"
        case .python: "d.chat.python.wasi.v1"
        case .webSearch: "d.chat.wikipedia.search.v1"
        case .webRead: "d.chat.wikipedia.read.v1"
        case .providerSearch: "d.chat.search.v1"
        case .pageRead: "d.chat.webpage.read.v1"
        case .mcp: "d.chat.mcp.call.v1"
        }
    }
    public var usesNetwork: Bool {
        switch self { case .webSearch, .webRead, .providerSearch, .pageRead: true; default: false }
    }
    /// API search metadata is transient; only the request and completion receipt persist.
    public var hasTransientResult: Bool {
        if case .providerSearch = self { true } else { false }
    }
    public var parents: [WorkflowAssetReference] {
        switch self {
        case .csv(let reference, _): [reference]
        case .python(_, let inputs): inputs
        default: []
        }
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
        if case .python(let code, let inputs) = request {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  code.utf8.count <= 65_536, !code.contains("\0"), inputs.count <= 8,
                  Set(inputs).count == inputs.count, inputs.allSatisfy({ $0.kind == .text }) else {
                throw WorkflowIssue("Python 分析需要有界代码和明确选择的文字/CSV素材。")
            }
        }
        if case .mcp(let endpoint, let tool, let arguments) = request {
            _ = try ChatMCPService.validateEndpoint(endpoint)
            guard !tool.isEmpty, tool.utf8.count <= 1024 else { throw ChatMCPError.unknownTool }
            _ = try ChatMCPService.parseArguments(arguments)
        }
        let requestBytes = try JSONEncoder().encode(request)
        guard requestBytes.count <= 65_536, (resultJSON?.utf8.count ?? 0) <= 2_097_152,
              (issue?.utf8.count ?? 0) <= 16_384, output == nil || output?.kind == .text,
              status != .completed || resultJSON != nil || request.hasTransientResult,
              !request.hasTransientResult || (resultJSON == nil && output == nil) else { throw WorkflowIssue("工具记录大小或结果无效。") }
    }
}

public struct ChatWebOptions: Codable, Sendable, Equatable {
    public var allowed = false
    public var automaticSearch = false
    public var language: ChatWebLanguage = .zh
    /// nil in legacy documents requires an explicit new provider choice. It is not a fallback.
    public var provider: ChatSearchProvider?
    public init() {}
}

extension ChatToolRequest {
    func execute(store: ProjectStore, authorized: Bool, web: ChatWebSearchClient, mcp: (any ChatMCPServing)?,
                 search: ChatSearchClient = .init(), credential: String? = nil,
                 page: ChatWebPageClient = .init(), python: ChatPythonClient = .init()) async throws -> String {
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
        case .python(let code, let references):
            var inputs: [ChatPythonInput] = []
            for (index, reference) in references.enumerated() {
                guard reference.kind == .text else { throw WorkflowIssue("Python 输入必须是已选择的文字/CSV素材。") }
                try Task.checkCancellation()
                let bytes = try await store.workflowData(reference)
                inputs.append(.init(name: "input-\(index + 1).csv", data: bytes))
            }
            return try encoded(await python.run(code: code, inputs: inputs))
        case .webSearch(let query, let language): return try encoded(await web.search(query, language: language, networkAuthorized: authorized))
        case .webRead(let hit): return try encoded(await web.readPage(hit, networkAuthorized: authorized))
        case .providerSearch(let query, let provider):
            guard let credential else { throw ChatSearchError.invalidCredential }
            return try encoded(await search.search(query: query, provider: provider, credential: credential, networkAuthorized: authorized))
        case .pageRead(let url): return try encoded(await page.read(url, networkAuthorized: authorized))
        case .mcp(let endpoint, let tool, let arguments):
            guard let mcp, await mcp.status() == .connected(endpoint: endpoint) else { throw ChatMCPError.notConnected }
            return try await mcp.callTool(name: tool, argumentsJSON: arguments, permitted: authorized, timeoutSeconds: 30).resultJSON
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

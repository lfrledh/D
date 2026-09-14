import Foundation

public enum TextSourcesArchive {
    private static let schemaVersion = 1
    private struct Envelope: Codable { let schema_version: Int; let notebook: TextSourcesNotebook }

    public static func validate(_ notebook: TextSourcesNotebook) throws {
        guard notebook.question.utf8.count <= TextSourcesLimits.questionBytes else {
            throw TextSourcesError.limit("问题超过 16 KiB 限制。")
        }
        guard notebook.sources.count <= TextSourcesLimits.sources,
              notebook.excerpts.count <= TextSourcesLimits.excerpts,
              notebook.records.count <= TextSourcesLimits.records else {
            throw TextSourcesError.limit("资料问答记录超过数量限制。")
        }
        try unique(notebook.sources.map(\.id), "资料 ID 重复。")
        try unique(notebook.excerpts.map(\.id), "片段 ID 重复。")
        try unique(notebook.records.map(\.id), "回答 ID 重复。")
        try validateSources(notebook.sources, excerpts: notebook.excerpts)
        for record in notebook.records {
            guard record.completedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw TextSourcesError.invalid("历史回答时间无效。")
            }
            try validateMetrics(record.metrics)
            try validateSubmission(record.submission)
        }
        let data = try JSONEncoder().encode(Envelope(schema_version: schemaVersion, notebook: notebook))
        guard data.count <= TextSourcesLimits.archiveBytes else {
            throw TextSourcesError.limit("资料归档超过 8 MiB 限制。")
        }
    }

    public static func encode(_ notebook: TextSourcesNotebook) throws -> Data {
        try validate(notebook)
        let data = try JSONEncoder().encode(Envelope(schema_version: schemaVersion, notebook: notebook))
        guard data.count <= TextSourcesLimits.archiveBytes else {
            throw TextSourcesError.limit("资料归档超过 8 MiB 限制。")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> TextSourcesNotebook {
        guard data.count <= TextSourcesLimits.archiveBytes else { throw TextSourcesError.limit("资料归档超过 8 MiB 限制。") }
        guard jsonDepth(data) <= 32 else { throw TextSourcesError.invalid("资料归档嵌套过深。") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: []) }
        catch { throw TextSourcesError.invalid("资料归档不是有效 JSON。") }
        guard let dictionary = object as? [String: Any], let version = dictionary["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), isIntegerJSONNumber(version),
              version.intValue == schemaVersion else {
            throw TextSourcesError.invalid("资料归档 schema_version 无效或不受支持。")
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw TextSourcesError.invalid("资料归档缺少必需字段或字段类型无效。") }
        guard envelope.schema_version == schemaVersion else { throw TextSourcesError.invalid("资料归档版本不受支持。") }
        try validate(envelope.notebook)
        return envelope.notebook
    }

    private static func validateSubmission(_ submission: TextSourcesSubmission) throws {
        guard !submission.question.isEmpty, submission.question.utf8.count <= TextSourcesLimits.questionBytes,
              !submission.sources.isEmpty, !submission.excerpts.isEmpty else {
            throw TextSourcesError.invalid("历史提交缺少问题、资料或片段。")
        }
        try unique(submission.sources.map(\.id), "历史资料 ID 重复。")
        try unique(submission.excerpts.map(\.id), "历史片段 ID 重复。")
        try validateSources(submission.sources, excerpts: submission.excerpts)
        try TextSourcesContext.validateModelIdentity(submission.modelID, revision: submission.modelRevision)
        let rebuilt = try TextSourcesContext.makePrompt(question: submission.question, sources: submission.sources,
                                                         excerpts: submission.excerpts)
        guard submission.request.prompt.utf8.elementsEqual(rebuilt.utf8),
              submission.request.prompt.utf8.count <= TextSourcesLimits.promptBytes,
              submission.request.maxTokens > 0,
              submission.request.temperature.isFinite, submission.request.temperature == 0.2,
              submission.request.topP.isFinite, submission.request.topP == 0.95,
              submission.request.execution?.maximumPromptTokens ?? 0 > 0,
              validExecutionProfileIdentifier(submission.request.execution?.profile.identifier),
              submission.request.execution?.profile.revision ?? 0 > 0 else {
            throw TextSourcesError.invalid("历史提交的请求与冻结资料不一致。")
        }
    }

    private static func validateSources(_ sources: [TextSourceSnapshot], excerpts: [TextSourceExcerpt]) throws {
        var map: [UUID: TextSourceSnapshot] = [:]
        for source in sources { _ = try source.validatedText(); map[source.id] = source }
        for excerpt in excerpts {
            guard let source = map[excerpt.sourceID] else { throw TextSourcesError.invalid("片段没有对应资料。") }
            try excerpt.validate(against: source)
        }
    }

    private static func unique(_ ids: [UUID], _ message: String) throws {
        guard Set(ids).count == ids.count else { throw TextSourcesError.invalid(message) }
    }

    private static func validateMetrics(_ metrics: [String: String]) throws {
        let allowed: Set<String> = [
            "promptTokens", "generationTokens", "promptSeconds", "generationSeconds", "stopReason",
            "upstreamStopReason", "modelRevision", "randomSeed", "weightBytes", "estimatedPeakBytes",
            "executionProfileIdentifier", "executionProfileRevision", "maximumPromptTokens", "maximumOutputTokens"
        ]
        guard metrics.keys.allSatisfy(allowed.contains),
              metrics.allSatisfy({ $0.key.utf8.count <= 512 && $0.value.utf8.count <= 512 }) else {
            throw TextSourcesError.invalid("历史执行指标包含未允许或过长字段。")
        }
    }

    private static func validExecutionProfileIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 512 else { return false }
        return !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func jsonDepth(_ data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .max }
        func depth(_ value: Any) -> Int {
            if let dictionary = value as? [String: Any] { return 1 + (dictionary.values.map(depth).max() ?? 0) }
            if let array = value as? [Any] { return 1 + (array.map(depth).max() ?? 0) }
            return 0
        }
        return depth(object)
    }

    private static func isIntegerJSONNumber(_ value: NSNumber) -> Bool {
        switch String(cString: value.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q": true
        default: false
        }
    }
}

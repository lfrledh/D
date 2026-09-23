import Foundation

public enum ModelNodeTagStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyTag
    case duplicateTag(String)
    case tooManyTags(maximum: Int)
    case tagTooLong(tag: String, maximumCharacters: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyTag:
            "标签不能为空或只包含空白。"
        case .duplicateTag(let tag):
            "标签“\(tag)”已经存在。"
        case .tooManyTags(let maximum):
            "每个模型最多可保存 \(maximum) 个标签。"
        case .tagTooLong(let tag, let maximumCharacters):
            "标签“\(tag)”超过 \(maximumCharacters) 个字符。"
        }
    }
}

/// User-authored labels keyed by the catalog's stable model ID.
/// Passing no settings keeps the store in memory and never touches global defaults.
@MainActor
public final class ModelNodeTagStore {
    private static let maximumTags = 24
    private static let maximumCharacters = 32
    private static let keyPrefix = "D.ModelNodeTags.v1."

    private let settings: UserDefaults?
    private var memoryTags: [String: [String]] = [:]

    public init(settings: UserDefaults? = nil) {
        self.settings = settings
    }

    public func tags(for modelID: String) -> [String] {
        guard let settings else { return memoryTags[modelID] ?? [] }
        guard let stored = settings.object(forKey: Self.storageKey(for: modelID)) as? [String],
              let validated = try? Self.validate(stored) else {
            return []
        }
        return validated
    }

    public func setTags(_ tags: [String], for modelID: String) throws {
        let validated = try Self.validate(tags)
        if let settings {
            let key = Self.storageKey(for: modelID)
            if validated.isEmpty {
                settings.removeObject(forKey: key)
            } else {
                settings.set(validated, forKey: key)
            }
        } else if validated.isEmpty {
            memoryTags.removeValue(forKey: modelID)
        } else {
            memoryTags[modelID] = validated
        }
    }

    private static func storageKey(for modelID: String) -> String {
        keyPrefix + modelID
    }

    private static func validate(_ tags: [String]) throws -> [String] {
        guard tags.count <= maximumTags else {
            throw ModelNodeTagStoreError.tooManyTags(maximum: maximumTags)
        }

        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(tags.count)
        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { throw ModelNodeTagStoreError.emptyTag }
            guard tag.count <= maximumCharacters else {
                throw ModelNodeTagStoreError.tagTooLong(tag: tag, maximumCharacters: maximumCharacters)
            }
            guard seen.insert(tag).inserted else {
                throw ModelNodeTagStoreError.duplicateTag(tag)
            }
            result.append(tag)
        }
        return result
    }
}

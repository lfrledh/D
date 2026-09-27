import Foundation

public enum LibraryTagsError: Error, Equatable, LocalizedError, Sendable {
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
            "最多可保存 \(maximum) 个标签。"
        case .tagTooLong(let tag, let maximumCharacters):
            "标签“\(tag)”超过 \(maximumCharacters) 个字符。"
        }
    }
}

public enum LibraryTags {
    public static let maximumTags = 24
    public static let maximumCharacters = 32

    /// Validates user input without applying Unicode normalization. Only leading and
    /// trailing whitespace is removed, so the returned strings retain authored bytes.
    public static func validate(_ tags: [String]) throws -> [String] {
        guard tags.count <= maximumTags else {
            throw LibraryTagsError.tooManyTags(maximum: maximumTags)
        }

        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(tags.count)
        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { throw LibraryTagsError.emptyTag }
            guard tag.count <= maximumCharacters else {
                throw LibraryTagsError.tagTooLong(tag: tag, maximumCharacters: maximumCharacters)
            }
            guard seen.insert(tag).inserted else {
                throw LibraryTagsError.duplicateTag(tag)
            }
            result.append(tag)
        }
        return result
    }
}

public enum LibrarySearch {
    private static let comparisonOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    public static func matches(
        query: String,
        selectedTags: Set<String>,
        title: String,
        detail: String,
        systemTags: [String],
        userTags: [String]
    ) -> Bool {
        let searchableText = ([title, detail] + systemTags + userTags).joined(separator: "\n")
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.allSatisfy({ token in
            searchableText.range(
                of: token,
                options: comparisonOptions,
                range: nil,
                locale: comparisonLocale
            ) != nil
        }) else { return false }

        let availableTags = Set((systemTags + userTags).map { folded($0) })
        return selectedTags.allSatisfy { availableTags.contains(folded($0)) }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: comparisonOptions, locale: comparisonLocale)
    }
}

import Foundation
import NaturalLanguage

/// Frozen extraction supplied by a caller that has already verified the asset bytes and parser choice.
public struct ChatKnowledgeSource: Sendable, Equatable {
    public let reference: WorkflowAssetReference
    public let extraction: DocumentTextExtraction

    public init(reference: WorkflowAssetReference, extraction: DocumentTextExtraction) {
        self.reference = reference
        self.extraction = extraction
    }
}

public struct ChatKnowledgeHit: Sendable, Equatable {
    public let source: WorkflowAssetReference
    /// Exact UTF-16 range in the unchanged DocumentTextExtraction.text.
    public let range: NSRange
    public let text: String
    public let page: Int?
    public let line: Int?
    /// Scoped lexical rank, not a probability or confidence value.
    public let score: Double
}

/// Storage and per-call work limits. All excess input is rejected, never silently truncated.
public struct ChatKnowledgeLimits: Sendable, Equatable {
    public var maxSources: Int
    public var maxTotalTextUTF8Bytes: Int
    public var maxSourceTextUTF8Bytes: Int
    public var maxTokensPerSource: Int
    public var maxChunksPerSource: Int
    public var maxSearchChunks: Int
    public var maxQueryUTF8Bytes: Int
    public var maxQueryTokens: Int
    public var maxResults: Int

    public init(maxSources: Int = 64, maxTotalTextUTF8Bytes: Int = 8_388_608,
                maxSourceTextUTF8Bytes: Int = 1_048_576, maxTokensPerSource: Int = 150_000,
                maxChunksPerSource: Int = 2_048, maxSearchChunks: Int = 8_192,
                maxQueryUTF8Bytes: Int = 4_096, maxQueryTokens: Int = 64,
                maxResults: Int = 100) {
        self.maxSources = maxSources
        self.maxTotalTextUTF8Bytes = maxTotalTextUTF8Bytes
        self.maxSourceTextUTF8Bytes = maxSourceTextUTF8Bytes
        self.maxTokensPerSource = maxTokensPerSource
        self.maxChunksPerSource = maxChunksPerSource
        self.maxSearchChunks = maxSearchChunks
        self.maxQueryUTF8Bytes = maxQueryUTF8Bytes
        self.maxQueryTokens = maxQueryTokens
        self.maxResults = maxResults
    }

    fileprivate var isValid: Bool {
        maxSources > 0 && maxTotalTextUTF8Bytes > 0 && maxSourceTextUTF8Bytes > 0 &&
        maxTokensPerSource > 0 && maxChunksPerSource > 0 && maxSearchChunks > 0 &&
        maxQueryUTF8Bytes > 0 && maxQueryTokens > 0 && maxResults > 0
    }
}

public enum ChatKnowledgeError: Error, Sendable, Equatable {
    case invalidLimits
    case projectMismatch
    case digestMismatch
    case invalidLocation
    case sourceTooLarge
    case capacityExceeded
    case tokenBudgetExceeded
    case chunkBudgetExceeded
    case queryTooLarge
    case queryTokenBudgetExceeded
    case searchScopeTooLarge
    case invalidMaximumHits
}

/// Ephemeral, project-bound lexical index. A caller must explicitly enumerate authorized asset IDs.
public struct ChatKnowledgeIndex: Sendable {
    private struct Chunk: Sendable {
        let range: NSRange
        let frequencies: [String: Int]
        let tokenCount: Int
    }

    private struct Entry: Sendable {
        let source: ChatKnowledgeSource
        let textBytes: Int
        let chunks: [Chunk]
    }

    private struct Candidate {
        let assetID: UUID
        let chunkIndex: Int
        let score: Double
    }

    private static let chunkUTF16Limit = 1_024
    public let projectID: UUID
    public let limits: ChatKnowledgeLimits
    private var entries: [UUID: Entry] = [:]
    private var totalTextBytes = 0

    public init(projectID: UUID, limits: ChatKnowledgeLimits = .init()) throws {
        guard limits.isValid else { throw ChatKnowledgeError.invalidLimits }
        self.projectID = projectID
        self.limits = limits
    }

    /// An explicit update fully replaces the asset entry, including a same-version extraction.
    /// Build and budget checks precede the swap, preserving the old entry on failure or cancellation.
    public mutating func update(_ source: ChatKnowledgeSource) throws {
        try Task.checkCancellation()
        guard source.reference.projectID == projectID else { throw ChatKnowledgeError.projectMismatch }
        guard source.reference.sha256 == source.extraction.sourceSHA256 else {
            throw ChatKnowledgeError.digestMismatch
        }
        let text = source.extraction.text
        let byteCount = text.utf8.count
        guard byteCount <= limits.maxSourceTextUTF8Bytes else { throw ChatKnowledgeError.sourceTooLarge }
        let textLength = text.utf16.count
        for (index, location) in source.extraction.locations.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let range = location.range
            guard range.location >= 0, range.length >= 0, range.location <= textLength,
                  range.length <= textLength - range.location else {
                throw ChatKnowledgeError.invalidLocation
            }
        }

        let oldBytes = entries[source.reference.assetID]?.textBytes ?? 0
        let retainedBytes = totalTextBytes - oldBytes
        guard byteCount <= limits.maxTotalTextUTF8Bytes - retainedBytes,
              entries[source.reference.assetID] != nil || entries.count < limits.maxSources else {
            throw ChatKnowledgeError.capacityExceeded
        }

        var chunks: [Chunk] = []
        var totalTokens = 0
        var cursor = text.startIndex
        let boundaryTokenizer = NLTokenizer(unit: .word)
        boundaryTokenizer.string = text
        while cursor < text.endIndex {
            try Task.checkCancellation()
            guard chunks.count < limits.maxChunksPerSource else { throw ChatKnowledgeError.chunkBudgetExceeded }
            let start = cursor
            var units = 0
            while cursor < text.endIndex {
                let next = text.index(after: cursor) // advances by a complete Character
                let character = text[cursor..<next]
                let isLineBreak = character.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
                // Keep line and page location metadata precise for ordinary extracts.
                if units > 0 && isLineBreak { break }
                let size = text[cursor..<next].utf16.count
                guard size <= Self.chunkUTF16Limit else { throw ChatKnowledgeError.chunkBudgetExceeded }
                if units > Self.chunkUTF16Limit - size { break }
                units += size
                cursor = next
                if isLineBreak { break }
            }
            // A UTF-16 cap can land inside an otherwise ordinary word. Move the
            // boundary to its tokenizer start so the next chunk indexes it whole.
            // When a tokenizer word alone exceeds the cap, reject the source.
            if cursor < text.endIndex,
               let word = boundaryTokenizer.tokenRange(at: cursor),
               word.lowerBound < cursor, word.upperBound > cursor {
                guard word.lowerBound > start else { throw ChatKnowledgeError.chunkBudgetExceeded }
                cursor = word.lowerBound
            }
            let fragment = String(text[start..<cursor])
            let tokens = try Self.tokens(in: fragment, maximum: limits.maxTokensPerSource - totalTokens,
                                         overflow: .tokenBudgetExceeded)
            totalTokens += tokens.count
            var frequencies: [String: Int] = [:]
            for token in tokens { frequencies[token, default: 0] += 1 }
            chunks.append(.init(range: NSRange(start..<cursor, in: text),
                                frequencies: frequencies, tokenCount: tokens.count))
        }
        try Task.checkCancellation()
        entries[source.reference.assetID] = Entry(source: source, textBytes: byteCount, chunks: chunks)
        totalTextBytes = retainedBytes + byteCount
    }

    /// A stale version cannot remove its replacement. Hash changes on the same version are
    /// handled by the explicit update operation; removal identity is project + asset + version.
    public mutating func remove(source: WorkflowAssetReference) {
        guard source.projectID == projectID,
              let entry = entries[source.assetID],
              entry.source.reference.version == source.version else { return }
        totalTextBytes -= entry.textBytes
        entries.removeValue(forKey: source.assetID)
    }

    public func search(_ query: String, within: Set<UUID>, maximumHits: Int = 12) throws -> [ChatKnowledgeHit] {
        try Task.checkCancellation()
        guard maximumHits >= 0, maximumHits <= limits.maxResults else {
            throw ChatKnowledgeError.invalidMaximumHits
        }
        guard within.count <= limits.maxSources else { throw ChatKnowledgeError.searchScopeTooLarge }
        guard query.utf8.count <= limits.maxQueryUTF8Bytes else { throw ChatKnowledgeError.queryTooLarge }
        guard maximumHits > 0, !within.isEmpty, !query.isEmpty else { return [] }
        let queryTokens = try Self.tokens(in: query, maximum: limits.maxQueryTokens,
                                          overflow: .queryTokenBudgetExceeded)
        guard !queryTokens.isEmpty else { return [] }
        var queryFrequencies: [String: Int] = [:]
        for token in queryTokens { queryFrequencies[token, default: 0] += 1 }
        let terms = queryFrequencies.keys.sorted()

        let selected = within.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> (UUID, Entry)? in
            entries[id].map { (id, $0) }
        }
        var chunkCount = 0
        var tokenCount = 0
        for (_, entry) in selected {
            try Task.checkCancellation()
            guard entry.chunks.count <= limits.maxSearchChunks - chunkCount else {
                throw ChatKnowledgeError.searchScopeTooLarge
            }
            chunkCount += entry.chunks.count
            for chunk in entry.chunks { tokenCount += chunk.tokenCount }
        }
        guard chunkCount > 0, tokenCount > 0 else { return [] }
        let averageLength = Double(tokenCount) / Double(chunkCount)
        var documentFrequencies: [String: Int] = [:]
        var visited = 0
        for (_, entry) in selected {
            for chunk in entry.chunks {
                if visited.isMultiple(of: 64) { try Task.checkCancellation() }
                visited += 1
                for term in terms where chunk.frequencies[term] != nil {
                    documentFrequencies[term, default: 0] += 1
                }
            }
        }

        var candidates: [Candidate] = []
        visited = 0
        for (assetID, entry) in selected {
            for (index, chunk) in entry.chunks.enumerated() {
                if visited.isMultiple(of: 64) { try Task.checkCancellation() }
                visited += 1
                var score = 0.0
                let lengthRatio = Double(chunk.tokenCount) / averageLength
                for term in terms {
                    guard let frequency = chunk.frequencies[term],
                          let documentFrequency = documentFrequencies[term] else { continue }
                    let idf = log(1 + (Double(chunkCount - documentFrequency) + 0.5) /
                                  (Double(documentFrequency) + 0.5))
                    let tf = Double(frequency)
                    let saturation = tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * lengthRatio))
                    score += idf * saturation * Double(min(queryFrequencies[term] ?? 1, 3))
                }
                if score > 0 { candidates.append(.init(assetID: assetID, chunkIndex: index, score: score)) }
            }
        }
        try Task.checkCancellation()
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.assetID != $1.assetID { return $0.assetID.uuidString < $1.assetID.uuidString }
            return $0.chunkIndex < $1.chunkIndex
        }
        var hits: [ChatKnowledgeHit] = []
        for candidate in candidates.prefix(maximumHits) {
            try Task.checkCancellation()
            guard let entry = entries[candidate.assetID] else { throw ChatKnowledgeError.invalidLocation }
            let chunk = entry.chunks[candidate.chunkIndex]
            let text = entry.source.extraction.text
            guard let range = Range(chunk.range, in: text) else { throw ChatKnowledgeError.invalidLocation }
            let (page, line) = Self.location(for: chunk.range, in: entry.source.extraction.locations)
            hits.append(.init(source: entry.source.reference, range: chunk.range,
                              text: String(text[range]), page: page, line: line,
                              score: candidate.score))
        }
        return hits
    }

    private static func tokens(in text: String, maximum: Int,
                               overflow: ChatKnowledgeError) throws -> [String] {
        try Task.checkCancellation()
        var result: [String] = []
        var exceeded = false
        var cancelled = false
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if result.count.isMultiple(of: 128), Task.isCancelled {
                cancelled = true
                return false
            }
            let token = String(text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                     locale: Locale(identifier: "en_US_POSIX"))
            guard !token.isEmpty else { return true }
            guard result.count < maximum else { exceeded = true; return false }
            result.append(token)
            return true
        }
        if cancelled { throw CancellationError() }
        if exceeded { throw overflow }
        // Word boundaries for Han text can vary by system language recognition. Bounded
        // one- and two-character terms preserve short Chinese queries across those choices.
        // NLTokenizer's word unit can omit pictographs, so index whole emoji graphemes too.
        var previousHan: String?
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                guard result.count < maximum else { throw overflow }
                result.append(String(character))
            }
            let isHan = character.unicodeScalars.contains { scalar in
                (0x3400...0x9FFF).contains(scalar.value) ||
                (0x20000...0x2FA1F).contains(scalar.value)
            }
            guard isHan else { previousHan = nil; continue }
            let current = String(character)
            guard result.count < maximum else { throw overflow }
            result.append(current)
            if let previousHan {
                guard result.count < maximum else { throw overflow }
                result.append(previousHan + current)
            }
            previousHan = current
        }
        try Task.checkCancellation()
        return result
    }

    private static func location(for range: NSRange, in locations: [DocumentTextLocation]) -> (Int?, Int?) {
        if let exactLine = locations.first(where: {
            $0.range.length > 0 && $0.range.location <= range.location &&
            range.length <= $0.range.location + $0.range.length - range.location
        }) {
            return (exactLine.page, exactLine.line)
        }
        // Page numbers are only reported when the entire returned fragment lies within
        // one page's covered text span. A fragment crossing a page separator has no page.
        var pageSpans: [Int: NSRange] = [:]
        for location in locations {
            guard let page = location.page, location.range.length > 0 else { continue }
            if let span = pageSpans[page] {
                let start = min(span.location, location.range.location)
                let end = max(span.location + span.length,
                              location.range.location + location.range.length)
                pageSpans[page] = NSRange(location: start, length: end - start)
            } else {
                pageSpans[page] = location.range
            }
        }
        let covering = pageSpans.filter { _, span in
            span.location <= range.location &&
            range.length <= span.location + span.length - range.location
        }
        return (covering.count == 1 ? covering.first?.key : nil, nil)
    }
}

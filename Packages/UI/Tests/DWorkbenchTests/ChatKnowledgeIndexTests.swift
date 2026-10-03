import Foundation
import Testing
@testable import DWorkbench

@Suite("Project-scoped lexical knowledge retrieval")
struct ChatKnowledgeIndexTests {
    private let project = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let otherProject = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let asset = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let oldVersion = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    private let newVersion = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
    private let hash = String(repeating: "a", count: 64)

    private func source(_ text: String, projectID: UUID? = nil, assetID: UUID? = nil,
                        version: UUID? = nil, digest: String? = nil,
                        parserVersion: String = "fixture-v1",
                        locations: [DocumentTextLocation] = []) -> ChatKnowledgeSource {
        let digest = digest ?? hash
        let reference = WorkflowAssetReference(projectID: projectID ?? project,
                                               assetID: assetID ?? asset,
                                               version: version ?? oldVersion,
                                               kind: .text, sha256: digest)
        let extraction = DocumentTextExtraction(text: text, sourceSHA256: digest,
                                                format: "plain-text", parserVersion: parserVersion,
                                                locations: locations, warnings: [])
        return .init(reference: reference, extraction: extraction)
    }

    @Test func realPlainTextExtractionFindsEnglishAndChineseWithOriginalLines() async throws {
        let first = "Local retrieval finds moonlight."
        let second = "本地检索找到月光。"
        let text = first + "\n" + second
        let extraction = try await DocumentTextExtractor.extract(data: Data(text.utf8), fileName: "notes.txt")
        let reference = WorkflowAssetReference(projectID: project, assetID: asset,
                                               version: oldVersion, kind: .text,
                                               sha256: extraction.sourceSHA256)
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(.init(reference: reference, extraction: extraction))
        let english = try #require(index.search("moonlight", within: [asset]).first)
        let chinese = try #require(index.search("检索", within: [asset]).first)
        #expect(english.source.projectID == project)
        #expect(english.source.assetID == asset)
        #expect(english.source.version == oldVersion)
        #expect(english.source.sha256 == extraction.sourceSHA256)
        #expect(english.text == first)
        #expect(english.page == nil && english.line == 1)
        #expect(chinese.text == second)
        #expect(chinese.page == nil && chinese.line == 2)
        #expect((text as NSString).substring(with: english.range) == english.text)
        #expect((text as NSString).substring(with: chinese.range) == chinese.text)
        #expect(english.score > 0 && chinese.score > 0)
        #expect(try index.search("unrelated", within: [asset]).isEmpty)
        #expect(try index.search("", within: [asset]).isEmpty)
    }

    @Test func pageCrossingFragmentNeverClaimsOnePage() throws {
        let text = "page one\npage two"
        let firstLength = ("page one" as NSString).length
        let locations = [DocumentTextLocation(page: 1, line: 1,
                                              range: NSRange(location: 0, length: firstLength)),
                         DocumentTextLocation(page: 2, line: 1,
                                              range: NSRange(location: firstLength + 1,
                                                             length: ("page two" as NSString).length))]
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source(text, locations: locations))
        let hits = try index.search("page", within: [asset])
        #expect(Set(hits.compactMap(\.page)) == [1, 2])
        #expect(hits.allSatisfy { $0.text == "page one" || $0.text == "page two" })
        try index.update(source("alpha beta", locations: [
            .init(page: 1, line: 1, range: NSRange(location: 0, length: 5)),
            .init(page: 2, line: 1, range: NSRange(location: 6, length: 4))
        ]))
        let crossing = try #require(index.search("alpha", within: [asset]).first)
        #expect(crossing.text == "alpha beta")
        #expect(crossing.page == nil && crossing.line == nil)
    }

    @Test func replacementAndStaleRemovalKeepOnlyCurrentContent() throws {
        var index = try ChatKnowledgeIndex(projectID: project)
        let old = source("obsolete orchard", version: oldVersion)
        let current = source("renewed moonlight", version: newVersion,
                             parserVersion: "fixture-v2")
        try index.update(old)
        try index.update(current)
        index.remove(source: old.reference)
        #expect(try index.search("obsolete", within: [asset]).isEmpty)
        #expect(try index.search("moonlight", within: [asset]).first?.source.version == newVersion)
        // Same-version changes are an explicit replacement, not a cache hit.
        try index.update(source("fresh constellation", version: newVersion,
                                parserVersion: "fixture-v3"))
        #expect(try index.search("moonlight", within: [asset]).isEmpty)
        #expect(try index.search("constellation", within: [asset]).count == 1)
        index.remove(source: current.reference)
        #expect(try index.search("constellation", within: [asset]).isEmpty)
        let changedHash = String(repeating: "b", count: 64)
        try index.update(source("hashed horizon", version: newVersion, digest: changedHash))
        #expect(try index.search("constellation", within: [asset]).isEmpty)
        #expect(try index.search("horizon", within: [asset]).first?.source.sha256 == changedHash)
    }

    @Test func authorizationAndProjectIdentityCannotBleedAcrossProjects() throws {
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source("private nebula"))
        #expect(try index.search("nebula", within: []).isEmpty)
        #expect(try index.search("nebula", within: [UUID()]).isEmpty)
        #expect(throws: ChatKnowledgeError.projectMismatch) {
            try index.update(source("foreign nebula", projectID: otherProject, assetID: asset))
        }
        index.remove(source: source("foreign nebula", projectID: otherProject, assetID: asset).reference)
        #expect(try index.search("foreign", within: [asset]).isEmpty)
        #expect(try index.search("private", within: [asset]).count == 1)
    }

    @Test func combinedUnicodeRangesStayAtCharacterBoundaries() throws {
        let text = "👩🏽‍🎨 e\u{301} 本地绘画 🧑‍🚀"
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source(text))
        for query in ["👩🏽‍🎨", "绘画", "🧑‍🚀"] {
            let hit = try #require(index.search(query, within: [asset]).first)
            let range = try #require(Range(hit.range, in: text))
            #expect(text.indices.contains(range.lowerBound))
            #expect(range.upperBound == text.endIndex || text.indices.contains(range.upperBound))
            #expect(String(text[range]) == hit.text)
            #expect((text as NSString).substring(with: hit.range) == hit.text)
        }
    }

    @Test func limitsRejectInputWithoutReplacingPriorEntry() throws {
        let tiny = ChatKnowledgeLimits(maxSources: 1, maxTotalTextUTF8Bytes: 32,
                                       maxSourceTextUTF8Bytes: 32, maxTokensPerSource: 4,
                                       maxChunksPerSource: 2, maxSearchChunks: 1,
                                       maxQueryUTF8Bytes: 16, maxQueryTokens: 2,
                                       maxResults: 1)
        var index = try ChatKnowledgeIndex(projectID: project, limits: tiny)
        try index.update(source("safe moon"))
        #expect(throws: ChatKnowledgeError.sourceTooLarge) {
            try index.update(source(String(repeating: "x", count: 33)))
        }
        #expect(throws: ChatKnowledgeError.tokenBudgetExceeded) {
            try index.update(source("one two three four five"))
        }
        #expect(throws: ChatKnowledgeError.capacityExceeded) {
            try index.update(source("second moon", assetID: UUID()))
        }
        #expect(throws: ChatKnowledgeError.queryTooLarge) {
            try index.search(String(repeating: "q", count: 17), within: [asset])
        }
        #expect(throws: ChatKnowledgeError.queryTokenBudgetExceeded) {
            try index.search("one two three", within: [asset])
        }
        #expect(throws: ChatKnowledgeError.invalidMaximumHits) {
            try index.search("moon", within: [asset], maximumHits: -1)
        }
        #expect(throws: ChatKnowledgeError.invalidMaximumHits) {
            try index.search("moon", within: [asset], maximumHits: 2)
        }
        #expect(try index.search("moon", within: [asset], maximumHits: 0).isEmpty)
        #expect(try index.search("moon", within: [asset], maximumHits: 1).first?.text == "safe moon")
        #expect(throws: ChatKnowledgeError.invalidLimits) {
            try ChatKnowledgeIndex(projectID: project, limits: .init(maxSources: 0))
        }
    }

    @Test func chunkAndSearchScopeBudgetsAreExplicit() throws {
        let limits = ChatKnowledgeLimits(maxSources: 2, maxTotalTextUTF8Bytes: 100,
                                         maxSourceTextUTF8Bytes: 100, maxTokensPerSource: 20,
                                         maxChunksPerSource: 2, maxSearchChunks: 1)
        var index = try ChatKnowledgeIndex(projectID: project, limits: limits)
        #expect(throws: ChatKnowledgeError.chunkBudgetExceeded) {
            try index.update(source("first\nsecond\nthird"))
        }
        try index.update(source("moon"))
        let secondAsset = UUID()
        try index.update(source("moon", assetID: secondAsset))
        #expect(throws: ChatKnowledgeError.searchScopeTooLarge) {
            try index.search("moon", within: [asset, secondAsset])
        }
        #expect(throws: ChatKnowledgeError.searchScopeTooLarge) {
            try index.search("moon", within: [asset, secondAsset, UUID()])
        }
    }

    @Test func equalScoresUseStableAssetOrder() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source("moon", assetID: secondID))
        try index.update(source("moon", assetID: firstID))
        let hits = try index.search("moon", within: [secondID, firstID])
        #expect(hits.map(\.source.assetID) == [firstID, secondID])
        #expect(hits[0].score == hits[1].score)
    }

    @Test func shortAndLongTermsMatchWithoutChangingSourceText() throws {
        let longTerm = String(repeating: "z", count: 200)
        let text = "go " + longTerm
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source(text))
        #expect(try index.search("go", within: [asset]).first?.text == text)
        #expect(try index.search(longTerm, within: [asset]).first?.text == text)
    }

    @Test func wordCrossingUTF16ChunkLimitRemainsSearchable() throws {
        let prefix = String(repeating: "a ", count: 511)
        let text = prefix + "moonlight"
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source(text))
        let hit = try #require(index.search("moonlight", within: [asset]).first)
        #expect(hit.text == "moonlight")
        #expect(hit.range == NSRange(location: (prefix as NSString).length,
                                     length: ("moonlight" as NSString).length))
        #expect((text as NSString).substring(with: hit.range) == hit.text)
    }

    @Test func aggregateTextBudgetRejectsNewSource() throws {
        let limits = ChatKnowledgeLimits(maxSources: 2, maxTotalTextUTF8Bytes: 8,
                                         maxSourceTextUTF8Bytes: 8)
        var index = try ChatKnowledgeIndex(projectID: project, limits: limits)
        try index.update(source("moon"))
        #expect(throws: ChatKnowledgeError.capacityExceeded) {
            try index.update(source("orbit", assetID: UUID()))
        }
        #expect(try index.search("moon", within: [asset]).count == 1)
    }

    @Test func digestAndInvalidLocationAreRejected() throws {
        var index = try ChatKnowledgeIndex(projectID: project)
        let mismatched = ChatKnowledgeSource(
            reference: source("moon").reference,
            extraction: .init(text: "moon", sourceSHA256: String(repeating: "b", count: 64),
                              format: "plain-text", parserVersion: "fixture-v1",
                              locations: [], warnings: []))
        #expect(throws: ChatKnowledgeError.digestMismatch) { try index.update(mismatched) }
        #expect(throws: ChatKnowledgeError.invalidLocation) {
            try index.update(source("moon", locations: [
                .init(page: nil, line: 1, range: NSRange(location: 0, length: 99))
            ]))
        }
    }

    @Test func cancelledBuildAndSearchReportCancellation() async throws {
        var index = try ChatKnowledgeIndex(projectID: project)
        try index.update(source("moon"))
        let current = index
        let searchTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try current.search("moon", within: [asset])
        }
        do {
            _ = try await searchTask.value
            #expect(Bool(false), "Cancelled search unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        let replacement = source("replacement")
        let buildTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var copy = current
            try copy.update(replacement)
        }
        do {
            try await buildTask.value
            #expect(Bool(false), "Cancelled update unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(try index.search("moon", within: [asset]).count == 1)
    }
}

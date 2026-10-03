import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Chat assistance values")
struct ChatAssistanceTests {
    private func fixture() throws -> (ChatSession, ChatContextSource) {
        var session = ChatSession(title: "fixture")
        let message = ChatMessage(parentID: nil, role: .user, text: "原文 👩🏽‍🎨 e\u{301}")
        session.messages = [message]
        session.selectedLeafID = message.id
        let source = try ChatContextSource.capture(session: session, coveredMessageIDs: [message.id])
        return (session, source)
    }

    @Test func defaultsAreIndependentAndRequireExplicitMemoryTarget() throws {
        let options = ChatAssistanceOptions()
        try options.validate()
        #expect(try JSONDecoder().decode(ChatAssistanceOptions.self,
            from: JSONEncoder().encode(options)) == options)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ChatAssistanceKind.self, from: Data(#""unknown""#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ChatAssistanceMemoryMode.self, from: Data(#""unknown""#.utf8))
        }
        #expect(ChatAssistanceKind.allCases.allSatisfy { !options.isEnabled($0) })
        #expect(options.memoryMode == .off && options.memoryTarget == nil)
        #expect(options.requestedMemoryAcceptance == nil)
        #expect(ChatAssistanceOptions(memoryTarget: .personal).requestedMemoryAcceptance == nil)
        #expect(options.summaryThresholdEstimatedTokens == 4_096)
        #expect(options.outputTokenBudgets.summary == 512)
        #expect(options.outputTokenBudgets.memory == 512)
        #expect(options.outputTokenBudgets.title == 256)
        #expect(options.outputTokenBudgets.tags == 256)
        #expect(options.outputTokenBudgets.followUps == 256)

        let titleOnly = ChatAssistanceOptions(title: true)
        #expect(titleOnly.isEnabled(.title))
        #expect(!titleOnly.isEnabled(.summary) && !titleOnly.isEnabled(.memory))
        #expect(throws: (any Error).self) { try ChatAssistanceOptions(memoryMode: .suggest).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceOptions(memoryMode: .automatic).validate() }
        #expect(ChatAssistanceOptions(memoryMode: .automatic).requestedMemoryAcceptance == nil)
        let suggested = ChatAssistanceOptions(memoryMode: .suggest, memoryTarget: .personal)
        try suggested.validate()
        #expect(suggested.isEnabled(.memory) && suggested.requestedMemoryAcceptance == .suggested)
        let automatic = ChatAssistanceOptions(memoryMode: .automatic, memoryTarget: .project(UUID()))
        try automatic.validate()
        #expect(automatic.isEnabled(.memory) && automatic.requestedMemoryAcceptance == .accepted)
        #expect(try JSONDecoder().decode(ChatAssistanceOptions.self,
            from: JSONEncoder().encode(automatic)) == automatic)
        #expect(throws: (any Error).self) {
            try ChatAssistanceOptions(memoryMode: .suggest,
                memoryTarget: .project(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)).validate()
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceOptions(summaryThresholdEstimatedTokens: 0).validate()
        }
        let capability = TextExecutionCapability(maximumPromptTokens: 2_048, maximumOutputTokens: 1_024)
        try options.validateEnabledBudgets(capability: capability, requestMaximumOutputTokens: 256)
        try titleOnly.validateEnabledBudgets(capability: capability, requestMaximumOutputTokens: 256)
        #expect(throws: (any Error).self) {
            try ChatAssistanceOptions(summary: true).validateEnabledBudgets(
                capability: capability, requestMaximumOutputTokens: 256)
        }
        #expect(try options.maximumOutputTokens(for: .summary, capability: capability,
            requestMaximumOutputTokens: 512) == 512)
        #expect(throws: (any Error).self) {
            try options.maximumOutputTokens(for: .summary, capability: capability,
                requestMaximumOutputTokens: 256)
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceOptions(outputTokenBudgets: .init(tags: 0)).validate()
        }
    }

    @Test func exactKindSchemasAndUnicodeRoundTrip() throws {
        let cases: [(ChatAssistanceKind, String, ChatAssistanceResult)] = [
            (.summary, #"{"summary":"原文 👩🏽‍🎨 e\u0301"}"#, .summary("原文 👩🏽‍🎨 e\u{301}")),
            (.title, #"{"title":"  東京 🎨  "}"#, .title("東京 🎨")),
            (.tags, #"{"tags":[" 漢字 ","👩🏽‍🎨"]}"#, .tags(["漢字", "👩🏽‍🎨"])),
            (.followUps, #"{"followUps":["次は何？","  Preserve spaces?  "]}"#,
                .followUps(["次は何？", "  Preserve spaces?  "])),
            (.memory, #"{"memory":["项目是蓝桉。","e\u0301 stays decomposed"]}"#,
                .memory(["项目是蓝桉。", "e\u{301} stays decomposed"])),
        ]
        for (kind, json, expected) in cases {
            let parsed = try ChatAssistanceResult.parse(json, as: kind)
            #expect(parsed == expected)
            #expect(try JSONDecoder().decode(ChatAssistanceResult.self,
                from: JSONEncoder().encode(parsed)) == parsed)
            #expect(kind.promptInstruction.contains("Return values only"))
            #expect(kind.promptInstruction.contains("\"\(kind.rawValue)\""))
            #expect(kind.outputSchema.kind == .record)
        }
        #expect(try ChatAssistanceResult.parse(#"{"tags":[]}"#, as: .tags) == .tags([]))
        #expect(try ChatAssistanceResult.parse(#"{"followUps":[]}"#, as: .followUps) == .followUps([]))
        #expect(try ChatAssistanceResult.parse(#"{"memory":[]}"#, as: .memory) == .memory([]))
        #expect(try ChatAssistanceResult.parse(#"{"summary":"  原文  "}"#, as: .summary) == .summary("  原文  "))
        #expect(try ChatAssistanceResult.parse(#"{"memory":["  fact  "]}"#, as: .memory) == .memory(["  fact  "]))
    }

    @Test func rejectsWrongShapeExtraTextAndOversizedValuesWithoutTruncation() throws {
        for (kind, text) in [
            (ChatAssistanceKind.summary, #"{"title":"wrong"}"#),
            (.title, #"{"title":"ok","tags":[]}"#),
            (.tags, #"{"tags":"one"}"#),
            (.followUps, #"{"followUps":[3]}"#),
            (.memory, #"{"memory":null}"#),
            (.summary, "```json\n{\"summary\":\"ok\"}\n```"),
            (.summary, #"{"summary":"ok"} trailing"#),
            (.summary, #"{"summary":"first","summary":"second"}"#),
        ] {
            #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(text, as: kind) }
        }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"title":"   "}"#, as: .title) }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"summary":""}"#, as: .summary) }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"summary":" \n\t "}"#, as: .summary) }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"followUps":[" \n\t "]}"#, as: .followUps) }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"memory":[" \n\t "]}"#, as: .memory) }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.summary(" \n\t ").validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.followUps([" \n\t "]).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.memory([" \n\t "]).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.parse(#"{"tags":[" x ","x"]}"#, as: .tags) }
        #expect(throws: (any Error).self) {
            try ChatAssistanceResult.parse(#"{"tags":[""]}"#, as: .tags)
        }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.summary(String(repeating: "é", count: 32_769)).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.title(String(repeating: "é", count: 257)).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.tags([String(repeating: "界", count: 33)]).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.tags((0..<25).map { "tag\($0)" }).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.followUps([String(repeating: "é", count: 1_025)]).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.followUps(Array(repeating: "?", count: 9)).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.memory([String(repeating: "é", count: 8_193)]).validate() }
        #expect(throws: (any Error).self) { try ChatAssistanceResult.memory(Array(repeating: "fact", count: 17)).validate() }
        #expect(throws: (any Error).self) {
            try ChatAssistanceResult.parse("{\"summary\":\"\(String(repeating: "é", count: 32_769))\"}", as: .summary)
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceResult.parse("{\"title\":\"\(String(repeating: "é", count: 257))\"}", as: .title)
        }
        let boundary = String(repeating: "a", count: 65_536)
        #expect(try ChatAssistanceResult.parse("{\"summary\":\"\(boundary)\"}", as: .summary) == .summary(boundary))
    }

    @Test func recordPreservesSourceIdentityAndRejectsFabricatedSuccess() throws {
        let (session, source) = try fixture()
        let created = Date(timeIntervalSince1970: 100)
        let ended = Date(timeIntervalSince1970: 101)
        let pending = try ChatAssistanceRecord(kind: .summary, source: source,
            createdAt: created, maximumOutputTokens: 512)
        #expect(pending.status == .pending && pending.output == nil && pending.result == nil)
        try pending.validate(current: session)
        let output = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .text,
            sha256: String(repeating: "a", count: 64))
        let complete = try ChatAssistanceRecord(id: pending.id, kind: .summary, source: source,
            createdAt: created, endedAt: ended, status: .completed, output: output,
            result: .summary("原文"), maximumOutputTokens: 512)
        let decoded = try JSONDecoder().decode(ChatAssistanceRecord.self,
            from: JSONEncoder().encode(complete))
        #expect(decoded == complete && decoded.source == source)
        try decoded.validate(current: session)
        #expect(throws: (any Error).self) {
            try ChatAssistanceRecord(kind: .summary, source: source, createdAt: created,
                endedAt: ended, status: .completed, result: .summary("false success"), maximumOutputTokens: 512)
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceRecord(kind: .summary, source: source, createdAt: created,
                endedAt: ended, status: .failed, result: .summary("false success"),
                issue: "parse failed", maximumOutputTokens: 512)
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceRecord(kind: .title, source: source, createdAt: created,
                endedAt: ended, status: .completed, output: output, result: .summary("wrong kind"),
                maximumOutputTokens: 512)
        }
        #expect(throws: (any Error).self) {
            try ChatAssistanceRecord(kind: .summary, source: source, createdAt: created,
                endedAt: ended, status: .completed,
                output: .init(projectID: UUID(), assetID: UUID(), kind: .image,
                    sha256: String(repeating: "a", count: 64)), result: .summary("wrong asset"),
                maximumOutputTokens: 512)
        }
        let failed = try ChatAssistanceRecord(kind: .summary, source: source,
            createdAt: created, endedAt: ended, status: .failed, output: output,
            issue: "parse failed", maximumOutputTokens: 512)
        #expect(failed.result == nil)
        for status in [ChatAssistanceStatus.cancelled, .stale] {
            let interrupted = try ChatAssistanceRecord(kind: .summary, source: source,
                createdAt: created, endedAt: ended, status: status, output: output,
                maximumOutputTokens: 512)
            let restored = try JSONDecoder().decode(ChatAssistanceRecord.self,
                from: JSONEncoder().encode(interrupted))
            #expect(restored == interrupted && restored.output == output && restored.source == source)
            #expect(restored.result == nil)
            #expect(throws: (any Error).self) {
                try ChatAssistanceRecord(kind: .summary, source: source,
                    createdAt: created, endedAt: ended, status: status, output: output,
                    result: .summary("false success"), maximumOutputTokens: 512)
            }
        }
        var changed = session
        changed.messages[0] = ChatMessage(id: session.messages[0].id, parentID: nil,
            role: .user, text: "changed")
        #expect(throws: (any Error).self) { try decoded.validate(current: changed) }
        let staleWithRaw = try ChatAssistanceRecord(kind: .summary, source: source,
            createdAt: created, endedAt: ended, status: .stale, output: output,
            maximumOutputTokens: 512)
        #expect(throws: (any Error).self) { try staleWithRaw.validate(current: changed) }
        let capability = TextExecutionCapability(maximumPromptTokens: 2_048, maximumOutputTokens: 1_024)
        try decoded.validate(capability: capability, requestMaximumOutputTokens: 512)
        #expect(throws: (any Error).self) {
            try decoded.validate(capability: capability, requestMaximumOutputTokens: 256)
        }
    }
}

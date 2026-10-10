import Foundation
import Testing
@testable import DWorkbench

@Suite("UI performance dependency checks", .serialized) @MainActor
struct SystematicPerformanceTests {
    static func history(_ count: Int) -> ChatState {
        var session = ChatSession(title: "Performance fixture")
        for index in 0..<count {
            session.messages.append(.init(parentID: session.messages.last?.id,
                role: index.isMultiple(of: 2) ? .user : .assistant, text: "Message \(index) 中文 👩🏽‍🎨",
                importedSource: .init(format: ChatInterchange.sourceFormat, version: ChatInterchange.sourceVersion,
                    sourceSHA256: String(repeating: "a", count: 64), sourceIndex: index)))
        }
        session.selectedLeafID = session.messages.last?.id
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        return state
    }
    @Test func repeatedRegistryAndLongHistoryBaseline() throws {
        let clock = ContinuousClock()
        var count = 0
        let registryTime = clock.measure {
            for _ in 0..<500 { count += WorkflowRegistry.standard.definitions.count }
        }
        #expect(count > 0)
        let state = Self.history(800)
        let validationTime = try clock.measure { for _ in 0..<3 { try state.validate() } }
        #expect(try state.sessions[0].path(to: state.sessions[0].selectedLeafID).count == 800)
        print("R15_BASELINE registry500=\(registryTime) validate800x3=\(validationTime)")
    }
    @Test func longHistoryValidationPreservesBranchAndErrorSemantics() throws {
        var state = Self.history(8)
        state.sessions[0].messages.reverse()
        try state.validate() // Parents need not precede their children.
        let original = state.sessions[0].messages
        let branch = ChatMessage(parentID: original[0].id, role: .user, text: "branch")
        state.sessions[0].messages.append(branch)
        try state.validate()
        func replacingParent(_ message: ChatMessage, with parent: UUID?, text: String? = nil) -> ChatMessage {
            .init(id: message.id, parentID: parent, role: message.role, text: text ?? message.text,
                  importedSource: message.importedSource)
        }
        state = Self.history(8)
        let first = state.sessions[0].messages[0]
        state.sessions[0].messages[0] = replacingParent(first, with: UUID())
        #expect(throws: WorkflowIssue.self) { try state.validate() }
        state.sessions[0].messages[0] = replacingParent(first, with: first.id)
        #expect(throws: WorkflowIssue.self) { try state.validate() }
        state.sessions[0].messages[0] = replacingParent(first, with: state.sessions[0].messages.last!.id)
        do { try state.validate(); Issue.record("Cycle accepted") }
        catch { #expect(error.localizedDescription == "聊天分支引用或循环无效。") }
        state.sessions[0].messages[0] = replacingParent(first, with: state.sessions[0].messages.last!.id, text: " ")
        do { try state.validate(); Issue.record("Invalid user accepted") }
        catch { #expect(error.localizedDescription == "用户消息文字或父助手消息无效。") }
    }

    @Test func transcriptCacheIgnoresDraftButTracksBranchesAndReplacements() throws {
        var session = Self.history(800).sessions[0]
        let cache = ChatTranscriptCache()
        let path = cache.structure(for: session).path
        for i in 0..<36 {
            session.draft = "draft \(i)"
            #expect(cache.structure(for: session).path == path)
        }
        #expect(cache.treeBuilds == 1 && cache.pathBuilds == 1)
        session.selectedLeafID = session.messages[3].id
        #expect(cache.structure(for: session).path.count == 4)
        #expect(cache.treeBuilds == 1 && cache.pathBuilds == 2)
        session.messages.append(.init(parentID: session.messages[3].id, role: .user, text: "branch"))
        session.selectedLeafID = session.messages.last?.id
        #expect(cache.structure(for: session).path.count == 5)
        #expect(cache.treeBuilds == 2)
        let other = Self.history(2).sessions[0]
        #expect(cache.structure(for: other).path.count == 2)
        #expect(cache.treeBuilds == 3)
    }

    @Test func batchSignaturesMatchIndividualBranchesAndIsolateEncodingFailure() throws {
        let registry = WorkflowRegistry.standard
        var graph = WorkflowExamples.template()
        for pass in 0..<3 {
            let signatures = try registry.signatures(in: graph, tools: [])
            for node in graph.nodes { #expect(signatures[node.id] == (try registry.signature(node.id, in: graph))) }
            graph.nodes.reverse(); graph.connections.reverse(); graph.layout.reverse()
            if pass == 1 { graph.name = "layout only"; graph.revision = UUID(); graph.nodes[0].title = "Renamed" }
        }
        var bad = try #require(registry.operation("d.text.input")).definition.makeNode()
        let good = try #require(registry.operation("d.text.input")).definition.makeNode()
        bad.dataConfiguration = .init(value: .number(.infinity, unit: nil))
        graph = .init(nodes: [bad, good])
        try registry.validate(graph)
        let signatures = try registry.signatures(in: graph, tools: [])
        #expect(signatures[bad.id] == nil)
        #expect(signatures[good.id] == (try registry.signature(good.id, in: graph)))
    }

}

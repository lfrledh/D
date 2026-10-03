import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Single chat session archive selection")
struct ChatSessionArchiveSelectionTests {
    private func ref(_ kind: WorkflowDataKind = .text) -> WorkflowAssetReference {
        .init(projectID: projectID, assetID: UUID(), kind: kind,
              sha256: String(repeating: "a", count: 64))
    }
    private var projectID: UUID { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
    private func record(_ reference: WorkflowAssetReference,
                        parents: [WorkflowAssetReference] = [], operation: String = "fixture",
                        stepID: UUID? = nil, metadata: [String: String] = [:]) -> WorkflowAssetRecord {
        .init(reference: reference, parents: parents, operationID: operation,
              stepID: stepID, metadata: metadata)
    }
    private func attempt(session: UUID, user: ChatMessage, assistant: ChatMessage,
                         input: WorkflowAssetReference, output: WorkflowAssetReference) throws -> ChatAttempt {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["messagesJSON"] = .text("[private frozen input]")
        var result = ChatAttempt(id: try #require(assistant.attemptID), sessionID: session,
                                 userMessageID: user.id, assistantMessageID: assistant.id,
                                 node: node, messagesJSON: "[private frozen input]",
                                 inputs: ["images": .asset(input)], systemPrompt: "private frozen rule",
                                 status: .completed)
        result.rawText = "original answer"
        result.response = .init(rawText: "original answer", finalText: "original answer", finishReason: .stop)
        result.output = output
        return result
    }

    @Test func completeBranchAndDependenciesExcludeOtherOwners() throws {
        let image = ref(.image), output1 = ref(), output2 = ref(), parent = ref()
        let draftAsset = ref(), speech = ref(), document = ref(), scopedDocument = ref()
        let toolInput = ref(), toolOutput = ref(), artifactSource = ref(), artifact1 = ref(), artifact2 = ref()
        let auxOutput = ref(), otherAsset = ref()
        let sessionID = UUID()
        let user1 = ChatMessage(parentID: nil, role: .user, text: "first",
            attachments: [.init(name: "image", reference: image)])
        let answer1 = ChatMessage(parentID: user1.id, role: .assistant, text: "first answer", attemptID: UUID())
        let user2 = ChatMessage(parentID: nil, role: .user, text: "other branch")
        let answer2 = ChatMessage(parentID: user2.id, role: .assistant, text: "second answer", attemptID: UUID())
        var first = try attempt(session: sessionID, user: user1, assistant: answer1, input: image, output: output1)
        var second = try attempt(session: sessionID, user: user2, assistant: answer2, input: image, output: output2)
        let memory = try ChatMemoryEntry.manual(text: "private historical fact", scope: .project(projectID))
        let forgotten = try memory.forgotten()
        let unused = try ChatMemoryEntry.manual(text: "unused private canary", scope: .project(projectID))
        second.memoryUses = [ChatMemoryUse(memory)]
        first.replayedAttemptID = second.id
        var session = ChatSession(id: sessionID, title: "selected")
        session.messages = [user1, answer1, user2, answer2]
        session.attempts = [first, second]
        session.selectedLeafID = answer1.id
        session.draft = "unsent private draft"
        session.attachments = [.init(name: "draft", reference: draftAsset, textSnapshot: "draft source")]
        session.pendingSpeechDraft = .init(name: "speech", reference: speech, textSnapshot: "speech source", sourceOnly: true)
        session.memoryScopes = [.project(projectID)]
        let revision = ChatTextRevision(messageID: answer2.id, text: "manual answer")
        let savedOriginal = WorkflowAssetReference(projectID: projectID, assetID: answer2.id,
            kind: .text, sha256: String(repeating: "a", count: 64))
        let savedRevision = WorkflowAssetReference(projectID: projectID, assetID: revision.id,
            kind: .text, sha256: String(repeating: "a", count: 64))
        var choices = ChatContextChoices(); choices.revisions = [revision]; choices.adoptedRevisionIDs = [revision.id]
        session.contextChoices = choices
        let excerpt = ChatKnowledgeExcerpt(source: document, name: "historical", text: "abc",
                                           utf16Offset: 0, utf16Length: 3, page: nil, line: 1)
        session.knowledgeExcerpts = [excerpt]
        session.knowledgeScope = [scopedDocument.assetID]
        let source = try ChatContextSource.capture(session: session, coveredMessageIDs: [user1.id, answer1.id])
        session.contextSummaries = [try .init(text: "summary", source: source)]
        let auxRecord = try ChatAssistanceRecord(kind: .title, source: source, endedAt: Date(),
            status: .completed, output: auxOutput, result: .title("title"), maximumOutputTokens: 16)
        var auxiliaryNode = first.node
        auxiliaryNode.parameters["maximumOutputTokens"] = .integer(16)
        session.assistanceExecutions = [.init(record: auxRecord, options: .init(), node: auxiliaryNode,
            messagesJSON: first.messagesJSON, inputs: first.inputs, originalTags: [], memoryFingerprint: "fixture")]
        var tool = ChatToolActivity(request: .csv(toolInput, columns: []))
        tool.status = .completed; tool.endedAt = Date(); tool.resultJSON = "{}"; tool.output = toolOutput
        session.toolActivities = [tool]
        let artifactID = UUID()
        session.artifacts = [
            .init(id: artifactID, revision: 1, sessionID: sessionID, title: "one", kind: .markdown,
                  text: "one", source: artifactSource, output: artifact1),
            .init(id: artifactID, revision: 2, sessionID: sessionID, title: "two", kind: .markdown,
                  text: "two", source: artifactSource, output: artifact2)
        ]
        var other = ChatSession(title: "other private session")
        other.attachments = [.init(name: "other", reference: otherAsset, textSnapshot: "canary")]
        var state = ChatState(); state.sessions = [session, other]; state.selectedSessionID = other.id
        state.presets = [.init(name: "unused preset canary", prompt: "private")]
        state.knowledgeDocuments = [
            .init(material: .init(name: "historical", reference: document, textSnapshot: "abc")),
            .init(material: .init(name: "scoped", reference: scopedDocument, textSnapshot: "scope")),
            .init(material: .init(name: "unused", reference: otherAsset, textSnapshot: "canary"))
        ]
        state.memoryEntries = [memory, forgotten, unused]
        let refs = [image, output1, output2, parent, draftAsset, speech, document, scopedDocument,
                    toolInput, toolOutput, artifactSource, artifact1, artifact2, auxOutput, otherAsset]
        var records = refs.map { record($0) }
        records[1].parents = [parent]
        records.append(record(savedOriginal, parents: [output2], operation: "d.chat.save-final", stepID: second.id,
            metadata: ["chatSessionID": sessionID.uuidString, "chatMessageID": answer2.id.uuidString,
                       "chatAttemptID": second.id.uuidString]))
        records.append(record(savedRevision, operation: "d.chat.save-final", stepID: revision.id,
            metadata: ["chatSessionID": sessionID.uuidString, "chatMessageID": answer2.id.uuidString,
                       "chatAttemptID": second.id.uuidString, "chatRevisionID": revision.id.uuidString]))
        var archive = WorkflowArchive(graphs: [.init(name: "unrelated")], assets: records)
        archive.version = 1

        let selection = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: sessionID)
        #expect(selection.chat.sessions.count == 1)
        #expect(selection.chat.sessions[0].messages == session.messages)
        #expect(selection.chat.sessions[0].attempts == session.attempts)
        #expect(selection.chat.sessions[0].contextChoices == session.contextChoices)
        #expect(selection.chat.sessions[0].draft == session.draft)
        #expect(selection.chat.sessions[0].artifacts == session.artifacts)
        #expect(selection.chat.sessions[0].memoryScopes == [])
        #expect(selection.chat.presets.isEmpty)
        #expect(Set(selection.chat.knowledgeDocuments?.map(\.id) ?? []) == [document.assetID, scopedDocument.assetID])
        #expect(selection.chat.memoryEntries == [memory, forgotten])
        #expect(selection.unresolvedExternalMemoryUses.isEmpty)
        #expect(selection.chat.sessions[0].attempts[0].messagesJSON == "[private frozen input]")
        #expect(selection.archive.graphs.isEmpty && selection.archive.runs.isEmpty && selection.archive.tools == nil)
        let retained = Set(selection.archive.assets.map { $0.reference.assetID })
        #expect(retained.contains(parent.assetID) && retained.contains(savedOriginal.assetID) && retained.contains(savedRevision.assetID))
        #expect(retained.contains(toolOutput.assetID) && retained.contains(auxOutput.assetID) && retained.contains(artifact2.assetID))
        #expect(!retained.contains(otherAsset.assetID))
        #expect(selection.archive.assets.first(where: { $0.reference == output1 }) == records[1])
    }

    @Test func missingExactVersionAndCycleFailClosed() throws {
        let asset = ref(.text), parent = ref(.text)
        var session = ChatSession(title: "one")
        session.attachments = [.init(name: "source", reference: asset, textSnapshot: "source")]
        var state = ChatState(); state.sessions = [session]
        var archive = WorkflowArchive(assets: [record(asset, parents: [parent]), record(parent)])
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state,
                archive: .init(assets: [record(parent)]), sessionID: session.id)
        }
        let wrongVersion = WorkflowAssetReference(projectID: asset.projectID, assetID: asset.assetID,
            version: UUID(), kind: asset.kind, sha256: asset.sha256)
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state,
                archive: .init(assets: [record(wrongVersion), record(parent)]), sessionID: session.id)
        }
        archive.assets[1].parents = [asset]
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        }
    }

    @Test func completedLengthAnswerRetainsFrozenBoundaryAndBody() throws {
        let input = ref(.image), output = ref()
        let user = ChatMessage(parentID: nil, role: .user, text: "question")
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "original answer", attemptID: UUID())
        var session = ChatSession(title: "length boundary")
        session.messages = [user, answer]
        var finished = try attempt(session: session.id, user: user, assistant: answer, input: input, output: output)
        finished.response = .init(rawText: "original answer", finalText: "original answer", finishReason: .length)
        session.attempts = [finished]
        var state = ChatState(); state.sessions = [session]
        let selection = try ChatSessionArchiveSelection.make(state: state,
            archive: .init(assets: [record(input), record(output)]), sessionID: session.id)
        #expect(selection.chat.sessions[0].attempts == [finished])
        #expect(selection.chat.sessions[0].attempts[0].response?.finishReason == .length)
        #expect(selection.chat.sessions[0].attempts[0].messagesJSON == "[private frozen input]")
        #expect(selection.chat.sessions[0].messages == [user, answer])
        finished.status = .saving; state.sessions[0].attempts = [finished]
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state,
                archive: .init(assets: [record(input), record(output)]), sessionID: session.id)
        }
    }

    @Test func removedAndUpdatedKnowledgeSourcesUseExactArchivedReferences() throws {
        let removed = ref(), oldVersion = ref(), scoped = ref(), parent = ref()
        let current = WorkflowAssetReference(projectID: oldVersion.projectID, assetID: oldVersion.assetID,
            version: UUID(), kind: oldVersion.kind, sha256: oldVersion.sha256)
        let user = ChatMessage(parentID: nil, role: .user, text: "question",
            knowledgeExcerpts: [.init(source: oldVersion, name: "old version", text: "old",
                                      utf16Offset: 0, utf16Length: 3, page: nil, line: 1)])
        var session = ChatSession(title: "historical sources")
        session.messages = [user]
        session.knowledgeExcerpts = [.init(source: removed, name: "removed", text: "past",
                                           utf16Offset: 0, utf16Length: 4, page: nil, line: 1)]
        session.knowledgeScope = [scoped.assetID]
        var state = ChatState(); state.sessions = [session]
        state.knowledgeDocuments = [
            .init(material: .init(name: "updated", reference: current, textSnapshot: "new")),
            .init(material: .init(name: "scoped", reference: scoped, textSnapshot: "current scope"))
        ]
        let archive = WorkflowArchive(assets: [record(removed, parents: [parent]), record(oldVersion),
                                               record(scoped), record(parent)])
        let selection = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        #expect(selection.chat.sessions[0].knowledgeExcerpts == session.knowledgeExcerpts)
        #expect(selection.chat.sessions[0].messages == session.messages)
        #expect(selection.chat.knowledgeDocuments == [state.knowledgeDocuments![1]])
        #expect(Set(selection.archive.assets.map(\.reference)) == [removed, oldVersion, scoped, parent])
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state,
                archive: .init(assets: [record(oldVersion), record(scoped), record(parent)]), sessionID: session.id)
        }
    }

    @Test func externalPersonalMemoryUseIsProvenanceOnly() throws {
        let input = ref(.image), output = ref()
        let user = ChatMessage(parentID: nil, role: .user, text: "question")
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "answer", attemptID: UUID())
        var session = ChatSession(title: "personal owner")
        session.messages = [user, answer]
        session.memoryScopes = [.personal, .project(projectID)]
        var finished = try attempt(session: session.id, user: user, assistant: answer, input: input, output: output)
        let external = try ChatMemoryEntry.manual(text: "private owner value", scope: .personal)
        let local = try ChatMemoryEntry.manual(text: "local value", scope: .project(projectID))
        let localNext = try local.edited(text: "new local value")
        finished.memoryUses = [ChatMemoryUse(external), ChatMemoryUse(local), ChatMemoryUse(external)]
        session.attempts = [finished]
        var state = ChatState(); state.sessions = [session]; state.memoryEntries = [local, localNext]
        let archive = WorkflowArchive(assets: [record(input), record(output)])
        let selection = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        #expect(selection.unresolvedExternalMemoryUses == [ChatMemoryUse(external)])
        #expect(selection.chat.memoryEntries == [local, localNext])
        #expect(selection.chat.sessions[0].memoryScopes == [])
        #expect(selection.chat.sessions[0].attempts[0] == finished)
        #expect(selection.chat.sessions[0].attempts[0].messagesJSON == "[private frozen input]")
        let externalLater = try external.edited(text: "locally available later version")
        state.memoryEntries = [local, localNext, externalLater]
        let laterSelection = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        #expect(laterSelection.chat.memoryEntries == [local, localNext, externalLater])
        #expect(laterSelection.unresolvedExternalMemoryUses == [ChatMemoryUse(external)])
        let conflicting = try ChatMemoryEntry(id: external.id, text: "wrong local scope",
                                              scope: .project(projectID), source: .manual)
        state.memoryEntries = [local, localNext, conflicting]
        #expect(throws: (any Error).self) {
            try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        }
    }

    @Test func externalMemoryUsesDeduplicateInOrderAndRejectTheNextUniqueUse() throws {
        let input = ref(.image), output = ref()
        var uses = try (0..<4_096).map { index -> ChatMemoryUse in
            let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 1)))
            return ChatMemoryUse(try ChatMemoryEntry(id: id, text: "external \(index)",
                                                      scope: .personal, source: .manual))
        }
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        uses[1] = ChatMemoryUse(try ChatMemoryEntry(id: firstID, revision: 2,
                                                    text: "later external version", scope: .personal,
                                                    source: .manual))
        var session = ChatSession(title: "bounded external provenance")
        for batch in 0..<4 {
            let user = ChatMessage(parentID: nil, role: .user, text: "question \(batch)")
            let answer = ChatMessage(parentID: user.id, role: .assistant, text: "answer", attemptID: UUID())
            var finished = try attempt(session: session.id, user: user, assistant: answer,
                                       input: input, output: output)
            finished.memoryUses = Array(uses[(batch * 1_024)..<((batch + 1) * 1_024)])
            session.messages += [user, answer]
            session.attempts.append(finished)
        }
        let user = ChatMessage(parentID: nil, role: .user, text: "repeat")
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "answer", attemptID: UUID())
        var repeated = try attempt(session: session.id, user: user, assistant: answer,
                                   input: input, output: output)
        repeated.memoryUses = [uses[1], uses[0], uses[1]]
        session.messages += [user, answer]
        session.attempts.append(repeated)
        var state = ChatState(); state.sessions = [session]
        let archive = WorkflowArchive(assets: [record(input), record(output)])
        try state.validate()
        let selection = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
        #expect(selection.unresolvedExternalMemoryUses == uses)
        #expect(selection.chat.memoryEntries?.isEmpty == true)

        let overflowID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001001"))
        let overflow = ChatMemoryUse(try ChatMemoryEntry(id: overflowID, text: "next external use",
                                                          scope: .personal, source: .manual))
        state.sessions[0].attempts[4].memoryUses = [uses[1], uses[0], uses[1], overflow]
        try state.validate()
        do {
            _ = try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id)
            Issue.record("The 4097th unique external use must be rejected")
        } catch let issue as WorkflowIssue {
            #expect(issue.reason == "External personal-memory provenance exceeds the archive limit.")
        }
    }

    @Test func activeAttemptToolAssistanceAndPendingMemoryReject() throws {
        let source = ref()
        let user = ChatMessage(parentID: nil, role: .user, text: "question")
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        var session = ChatSession(title: "one")
        session.messages = [user, answer]; session.selectedLeafID = answer.id
        let input = ref(.image)
        var running = try attempt(session: session.id, user: user, assistant: answer, input: input, output: source)
        running.status = .running; session.attempts = [running]
        var state = ChatState(); state.sessions = [session]
        let archive = WorkflowArchive(assets: [record(source), record(input)])
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
        running.status = .completed; state.sessions[0].attempts = [running]
        #expect(try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id).archive.assets.count == 2)
        let memory = try ChatMemoryEntry.manual(text: "used", scope: .project(projectID))
        state.sessions[0].attempts[0].memoryUses = [ChatMemoryUse(memory)]
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
        state.memoryEntries = [try memory.edited(text: "later version")]
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
        state.memoryEntries = [memory]
        #expect(try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id).chat.memoryEntries == [memory])
        state.sessions[0].attempts[0].memoryUses = nil
        state.memoryEntries = nil
        state.sessions[0].toolActivities = [.init(request: .csv(source, columns: []))]
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
        state.sessions[0].toolActivities = nil
        let context = try ChatContextSource.capture(session: state.sessions[0], coveredMessageIDs: [user.id, answer.id])
        let record = try ChatAssistanceRecord(kind: .title, source: context, maximumOutputTokens: 16)
        var auxiliaryNode = running.node
        auxiliaryNode.parameters["maximumOutputTokens"] = .integer(16)
        state.sessions[0].assistanceExecutions = [.init(record: record, options: .init(), node: auxiliaryNode,
            messagesJSON: running.messagesJSON, inputs: [:], originalTags: [], memoryFingerprint: "fixture")]
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
        state.sessions[0].assistanceExecutions = nil
        let completed = try ChatAssistanceRecord(kind: .memory, source: context, endedAt: Date(),
            status: .completed, output: source, result: .memory(["fact"]), maximumOutputTokens: 16)
        var execution = ChatAssistanceExecution(record: completed, options: .init(memoryMode: .suggest,
            memoryTarget: .project(projectID)), node: auxiliaryNode, messagesJSON: running.messagesJSON,
            inputs: [:], originalTags: [], memoryFingerprint: "fixture")
        execution.pendingMemoryEntries = [try .init(text: "fact", scope: .project(projectID), source: .chat(context))]
        state.sessions[0].assistanceExecutions = [execution]
        #expect(throws: (any Error).self) { try ChatSessionArchiveSelection.make(state: state, archive: archive, sessionID: session.id) }
    }
}

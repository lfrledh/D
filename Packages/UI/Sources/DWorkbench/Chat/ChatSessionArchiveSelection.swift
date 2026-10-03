import Foundation

/// A logical, single-session projection. ProjectStore owns physical assets and publication.
/// Frozen messagesJSON and source snapshots are preserved exactly; historical model inputs
/// may therefore still contain private facts even though future memory reads start disabled.
public struct ChatSessionArchiveSelection: Sendable, Equatable {
    private struct MemoryUseKey: Hashable {
        let id: UUID
        let revision: UInt64
        let scope: ChatMemoryScope

        init(_ use: ChatMemoryUse) {
            id = use.id; revision = use.revision; scope = use.scope
        }
    }

    public let chat: ChatState
    public let archive: WorkflowArchive
    /// Frozen personal-memory use identities whose content is owned outside this ChatState.
    /// These are provenance only; no missing memory entry is included or reconstructed.
    public let unresolvedExternalMemoryUses: [ChatMemoryUse]

    public static func make(state: ChatState, archive: WorkflowArchive,
                            sessionID: UUID) throws -> Self {
        try state.validate()
        guard [1, 2].contains(archive.version), archive.assets.count <= 32_768,
              let session = state.sessions.first(where: { $0.id == sessionID }) else {
            throw WorkflowIssue("The selected chat session or workflow archive is invalid.")
        }
        guard session.attempts.allSatisfy({
                  $0.status != .running && $0.status != .saving &&
                  ($0.status != .completed ||
                   ($0.response?.toolCalls.isEmpty == true &&
                    ($0.response?.finishReason == .stop || $0.response?.finishReason == .length)))
              }),
              (session.knowledgeReranks ?? []).allSatisfy({ $0.status != .running }),
              (session.toolActivities ?? []).allSatisfy({
                  $0.status != .running && ($0.status == .interrupted || $0.endedAt != nil)
              }),
              (session.assistanceExecutions ?? []).allSatisfy({
                  $0.record.status != .pending && $0.record.status != .running &&
                  $0.record.endedAt != nil && $0.pendingMemoryEntries == nil
              }) else {
            throw WorkflowIssue("Finish or cancel active chat work and memory saves before archiving this session.")
        }

        var selected = session
        // Re-enabling memory is an explicit decision in the restored project.
        selected.memoryScopes = []
        var chat = ChatState()
        chat.version = state.version
        chat.revision = state.revision
        chat.selectedSessionID = sessionID
        chat.sessions = [selected]

        let excerpts = (session.knowledgeExcerpts ?? []) +
            session.messages.flatMap { $0.knowledgeExcerpts ?? [] } +
            (session.knowledgeReranks ?? []).flatMap(\.excerpts)
        let excerptSources = Set(excerpts.map(\.source))
        let scopedIDs = Set(session.knowledgeScope ?? [])
        let documents = state.knowledgeDocuments ?? []
        chat.knowledgeDocuments = documents.filter {
            scopedIDs.contains($0.id) || excerptSources.contains($0.material.reference)
        }

        // Attempt receipts already include inherited summary memory uses. Keep every
        // version of an actually used identity, including later revocation/forgetting.
        let allMemories = state.memoryEntries ?? []
        var localVersions: [UUID: (scope: ChatMemoryScope, revisions: Set<UInt64>, scopesAgree: Bool)] = [:]
        for entry in allMemories {
            if var local = localVersions[entry.id] {
                local.scopesAgree = local.scopesAgree && local.scope == entry.scope
                local.revisions.insert(entry.revision)
                localVersions[entry.id] = local
            } else {
                localVersions[entry.id] = (entry.scope, [entry.revision], true)
            }
        }
        var useScopes: [UUID: ChatMemoryScope] = [:]
        var usedIDs = Set<UUID>()
        var unresolved: [ChatMemoryUse] = []
        var unresolvedKeys = Set<MemoryUseKey>()
        for attempt in session.attempts {
            for use in attempt.memoryUses ?? [] {
                if let scope = useScopes[use.id], scope != use.scope {
                    throw WorkflowIssue("A frozen memory use has no matching identity, scope, and version.")
                }
                useScopes[use.id] = use.scope
                usedIDs.insert(use.id)
                if let local = localVersions[use.id] {
                    guard local.scopesAgree, local.scope == use.scope else {
                        throw WorkflowIssue("A frozen memory use has no matching identity, scope, and version.")
                    }
                    if local.revisions.contains(use.revision) { continue }
                }
                if use.scope == .personal {
                    let key = MemoryUseKey(use)
                    if !unresolvedKeys.contains(key) {
                        guard unresolvedKeys.count < 4_096 else {
                            throw WorkflowIssue("External personal-memory provenance exceeds the archive limit.")
                        }
                        unresolvedKeys.insert(key)
                        unresolved.append(use)
                    }
                } else {
                    throw WorkflowIssue("A frozen memory use has no matching identity, scope, and version.")
                }
            }
        }
        chat.memoryEntries = allMemories.filter { usedIDs.contains($0.id) }
        try chat.validate()

        var roots: [WorkflowAssetReference] = []
        roots += session.attachments.map(\.reference)
        if let draft = session.pendingSpeechDraft { roots.append(draft.reference) }
        for message in session.messages {
            roots += message.attachments.map(\.reference)
            roots += (message.knowledgeExcerpts ?? []).map(\.source)
        }
        roots += excerpts.map(\.source)
        roots += (chat.knowledgeDocuments ?? []).map { $0.material.reference }
        for attempt in session.attempts {
            roots += attempt.inputs.values.flatMap { $0.datum?.assetReferences ?? [] }
            if let output = attempt.output { roots.append(output) }
        }
        for execution in session.assistanceExecutions ?? [] {
            roots += execution.inputs.values.flatMap { $0.datum?.assetReferences ?? [] }
            if let output = execution.record.output { roots.append(output) }
        }
        for activity in session.toolActivities ?? [] {
            roots += activity.request.parents
            if let output = activity.output { roots.append(output) }
        }
        for rerank in session.knowledgeReranks ?? [] {
            if let output = rerank.output { roots.append(output) }
        }
        for artifact in session.artifacts ?? [] {
            if let source = artifact.source { roots.append(source) }
            if let output = artifact.output { roots.append(output) }
        }

        let messageByID = Dictionary(uniqueKeysWithValues: session.messages.map { ($0.id, $0) })
        let attemptByID = Dictionary(uniqueKeysWithValues: session.attempts.map { ($0.id, $0) })
        let revisionByID = Dictionary(uniqueKeysWithValues:
            (session.contextChoices?.revisions ?? []).map { ($0.id, $0) })
        for record in archive.assets where record.operationID == "d.chat.save-final" &&
            record.metadata["chatSessionID"] == sessionID.uuidString {
            guard let messageText = record.metadata["chatMessageID"],
                  let messageID = UUID(uuidString: messageText),
                  let message = messageByID[messageID], message.role == .assistant else { continue }
            let attemptID = record.metadata["chatAttemptID"].flatMap(UUID.init(uuidString:))
            let revisionID = record.metadata["chatRevisionID"].flatMap(UUID.init(uuidString:))
            guard record.metadata["chatAttemptID"] == message.attemptID?.uuidString,
                  attemptID == message.attemptID,
                  attemptID == nil || attemptByID[attemptID!]?.assistantMessageID == messageID,
                  record.metadata["chatRevisionID"] == revisionID?.uuidString,
                  revisionID == nil || revisionByID[revisionID!]?.messageID == messageID,
                  record.reference.assetID == (revisionID ?? messageID),
                  record.stepID == (revisionID ?? attemptID ?? messageID),
                  record.metadata["importSourceSHA256"] == message.importedSource?.sourceSHA256,
                  record.metadata["importSourceIndex"] == message.importedSource.map({ String($0.sourceIndex) }) else {
                throw WorkflowIssue("A saved answer has mismatched message or version provenance.")
            }
            roots.append(record.reference)
        }

        for record in archive.assets where record.metadata["chatSessionID"] == sessionID.uuidString {
            if record.operationID == "d.chat.save-field" {
                guard let messageID = record.metadata["chatMessageID"].flatMap(UUID.init(uuidString:)),
                      messageByID[messageID]?.role == .assistant,
                      let answerID = record.metadata["answerAssetID"].flatMap(UUID.init(uuidString:)),
                      answerID == messageID || revisionByID[answerID]?.messageID == messageID,
                      record.parents.count == 1, record.parents[0].assetID == answerID else {
                    throw WorkflowIssue("A saved field has mismatched answer provenance.")
                }
                roots.append(record.reference)
            } else if record.operationID == "d.chat.quote" {
                guard let sourceID = record.metadata["sourceID"].flatMap(UUID.init(uuidString:)),
                      record.metadata["sourceKind"] == "document" || messageByID[sourceID] != nil else {
                    throw WorkflowIssue("A saved quotation has mismatched conversation provenance.")
                }
                roots.append(record.reference)
            }
        }

        guard Set(archive.assets.map { $0.reference.assetID }).count == archive.assets.count else {
            throw WorkflowIssue("Workflow asset identities are duplicated.")
        }
        let records = Dictionary(uniqueKeysWithValues: archive.assets.map { ($0.reference.assetID, $0) })
        var visited = Set<UUID>(), visiting = Set<UUID>()
        for root in roots {
            var stack: [(WorkflowAssetReference, Bool)] = [(root, false)]
            while let (reference, leaving) = stack.popLast() {
                guard let record = records[reference.assetID], record.reference == reference else {
                    throw WorkflowIssue("A chat asset reference is missing or points to another version.")
                }
                if leaving {
                    visiting.remove(reference.assetID)
                    visited.insert(reference.assetID)
                    continue
                }
                guard !visiting.contains(reference.assetID) else {
                    throw WorkflowIssue("Chat asset provenance contains a cycle.")
                }
                if visited.contains(reference.assetID) { continue }
                visiting.insert(reference.assetID)
                stack.append((reference, true))
                for parent in record.parents.reversed() { stack.append((parent, false)) }
            }
        }

        var projected = WorkflowArchive(revision: archive.revision, assets:
            archive.assets.filter { visited.contains($0.reference.assetID) })
        projected.version = archive.version
        return .init(chat: chat, archive: projected, unresolvedExternalMemoryUses: unresolved)
    }
}

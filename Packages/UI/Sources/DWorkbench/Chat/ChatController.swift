import DInference
import Foundation
import Observation

@MainActor @Observable public final class ChatController {
    public private(set) var state = ChatState()
    public private(set) var isLoaded = false
    public private(set) var isRunning = false
    public private(set) var phase = ""
    public private(set) var error: String?
    public private(set) var saveIssue: String?
    public private(set) var activeSessionID: UUID?
    public private(set) var activeAttemptID: UUID?
    public private(set) var pendingSaveAttemptID: UUID?
    /// Incomplete numeric edits survive view/category changes in this owner.
    /// Valid values persist in configuration; these transient edits are not cold-start state.
    public var parameterText: [String: String] = [:]
    public var invalidParameterFields: Set<String> = []
    public func hasInvalidParameterText(sessionID: UUID) -> Bool {
        invalidParameterFields.contains { $0.hasPrefix(sessionID.uuidString + ":") }
    }
    public let store: ProjectStore
    @ObservationIgnored private let allowsSubmission: @MainActor () -> Bool
    @ObservationIgnored private let makeServices: @MainActor () throws -> WorkflowServices
    @ObservationIgnored private var services: WorkflowServices?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writeTail: Task<Void, Error>?
    @ObservationIgnored private var diskRevision: UInt64 = 0
    @ObservationIgnored private var mutation: UInt64 = 0
    @ObservationIgnored private var savedMutation: UInt64 = 0
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var debounceGeneration: UInt64 = 0

    public init(store: ProjectStore, allowsSubmission: @escaping @MainActor () -> Bool = { true },
                makeServices: @escaping @MainActor () throws -> WorkflowServices) {
        self.store = store; self.allowsSubmission = allowsSubmission; self.makeServices = makeServices
    }
    public var selectedSession: ChatSession? { state.sessions.first { $0.id == state.selectedSessionID } }
    public var selectedPath: [ChatMessage] { (try? selectedSession?.path(to: selectedSession?.selectedLeafID)) ?? [] }

    public func load() async {
        guard !isLoaded else { return }
        do {
            let loaded = try await store.chatState()
            state = loaded; diskRevision = loaded.revision; isLoaded = true
            for i in state.sessions.indices {
                for j in state.sessions[i].attempts.indices where [.running, .saving].contains(state.sessions[i].attempts[j].status) {
                    state.sessions[i].attempts[j].status = .interrupted
                    state.sessions[i].attempts[j].issue = "上次运行中断；已保留部分文字，不会自动重跑。"
                    changed()
                }
            }
            if mutation != savedMutation { try await flush() }
        } catch { error = error.localizedDescription }
    }
    private func requireLoaded() throws {
        guard isLoaded else { throw WorkflowIssue(error ?? "聊天记录尚未读取，不能覆盖原件。") }
        guard saveIssue == nil else { throw WorkflowIssue("聊天记录保存失败，请先重试保存。") }
    }
    private func index(_ id: UUID) throws -> Int {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }) else { throw WorkflowIssue("对话不存在。") }
        return i
    }
    private static func derivedTitle(_ source: String, characterLimit: Int = .max, suffix: String = "") -> String {
        let byteLimit = 512 - suffix.utf8.count
        var title = "", byteCount = 0
        for character in source.prefix(characterLimit) {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= byteLimit else { break }
            title.append(character)
            byteCount += characterBytes
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = "新对话" }
        return title + suffix
    }
    private func changed(checkpoint: Bool = false) {
        mutation &+= 1
        if checkpoint && debounce != nil { return }
        debounce?.cancel()
        debounceGeneration &+= 1
        let generation = debounceGeneration
        debounce = Task { [weak self] in
            defer { if self?.debounceGeneration == generation { self?.debounce = nil } }
            do { try await Task.sleep(for: .milliseconds(checkpoint ? 2_000 : 350)); try await self?.flush() }
            catch is CancellationError {} catch { self?.saveIssue = error.localizedDescription }
        }
    }
    public func flush() async throws {
        guard isLoaded else { throw WorkflowIssue(error ?? "聊天记录尚未读取。") }
        let preceding = writeTail
        let task = Task { @MainActor [self] in
            _ = try? await preceding?.value
            guard mutation != savedMutation else { return }
            guard diskRevision < UInt64.max else { throw WorkflowIssue("聊天记录版本已达上限。") }
            let snapshot = state, captured = mutation
            let revision = try await store.saveChatState(snapshot, expectedRevision: diskRevision)
            diskRevision = revision; savedMutation = captured; state.revision = revision; saveIssue = nil
        }
        writeTail = task
        do { try await task.value } catch { saveIssue = error.localizedDescription; throw error }
    }
    /// Backup includes durable chat state only. A live or unpublished response must
    /// finish/save first; recheck after the actor hop used by sidecar publication.
    public func prepareForBackup() async throws {
        func requireDurableBoundary() throws {
            guard !isRunning else { throw WorkflowIssue("聊天仍在生成或停止中，请待资源释放后再备份。") }
            guard pendingSaveAttemptID == nil else {
                throw WorkflowIssue("聊天回答尚未写入项目，请先在文字页重试保存；原记录和生成结果仍保留。")
            }
        }
        try requireDurableBoundary()
        try await flush()
        try requireDurableBoundary()
    }
    @discardableResult public func newSession(title: String = "新对话") throws -> UUID {
        try requireLoaded()
        guard state.sessions.count < 512, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 512 else { throw WorkflowIssue("会话标题无效或数量已达上限。") }
        let session = ChatSession(title: title)
        state.sessions.append(session); state.selectedSessionID = session.id; changed(); return session.id
    }
    public func selectSession(_ id: UUID) throws { try requireLoaded(); _ = try index(id); state.selectedSessionID = id; changed() }
    public func rename(_ id: UUID, title: String) throws {
        try requireLoaded(); guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512 else { throw WorkflowIssue("会话标题无效。") }
        state.sessions[try index(id)].title = title; changed()
    }
    public func archive(_ id: UUID) throws {
        try requireLoaded(); guard activeSessionID != id else { throw WorkflowIssue("当前会话仍在运行，请等待其停止后归档。") }
        state.sessions[try index(id)].archived = true; changed()
    }
    public func updateDraft(_ text: String, sessionID: UUID) throws {
        try requireLoaded(); guard text.utf8.count <= 1_048_576 else { throw WorkflowIssue("草稿超过1MiB。") }
        state.sessions[try index(sessionID)].draft = text; changed()
    }
    public func updateConfiguration(_ node: WorkflowNode, sessionID: UUID) throws {
        try requireLoaded(); guard [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38].contains(node.operationID),
                                   node.parameters["modelID"]?.string?.isEmpty == false else { throw WorkflowIssue("请选择支持有序消息的明确文字模型。") }
        var chatNode = node
        chatNode.parameters["outputMode"] = .text("response")
        chatNode.parameters["task"] = .text("")
        chatNode.parameters["messagesJSON"] = .text("")
        try WorkflowRegistry.standard.validate(chatNode)
        state.sessions[try index(sessionID)].configuration = chatNode; changed()
    }
    public func setSystemPrompt(_ prompt: String, sessionID: UUID) throws {
        try requireLoaded(); guard prompt.utf8.count <= 65_536 else { throw WorkflowIssue("系统提示超过64KiB。") }
        state.sessions[try index(sessionID)].systemPrompt = prompt; changed()
    }
    public func setPreset(_ preset: ChatPromptPreset) throws {
        try requireLoaded(); guard !preset.name.isEmpty, preset.name.utf8.count <= 256, preset.prompt.utf8.count <= 65_536 else { throw WorkflowIssue("提示预设无效。") }
        var candidate = state
        if let i = candidate.presets.firstIndex(where: { $0.id == preset.id }) { candidate.presets[i] = preset }
        else { candidate.presets.append(preset) }
        try candidate.validate(); state = candidate; changed()
    }
    public func removePreset(_ id: UUID) throws { try requireLoaded(); state.presets.removeAll { $0.id == id }; changed() }
    public func addAttachment(_ reference: WorkflowAssetReference, name: String, sessionID: UUID) async throws -> UUID {
        try requireLoaded()
        guard [.text, .image, .video].contains(reference.kind), !name.isEmpty, name.utf8.count <= 512 else { throw WorkflowIssue("附件类型或名称无效。") }
        let snapshot: String?
        if reference.kind == .text {
            let bytes = try await store.workflowData(reference)
            guard bytes.count <= 524_288, let text = String(data: bytes, encoding: .utf8) else { throw WorkflowIssue("TXT/MD 来源必须是不超过512KiB的 UTF-8。") }
            snapshot = text
        } else { _ = try await store.workflowData(reference); snapshot = nil }
        let attachment = ChatAttachment(name: name, reference: reference, textSnapshot: snapshot)
        let i = try index(sessionID)
        guard state.sessions[i].attachments.count < 32 else { throw WorkflowIssue("一次最多32个附件。") }
        state.sessions[i].attachments.append(attachment); changed(); return attachment.id
    }
    public func removeAttachment(_ id: UUID, sessionID: UUID) throws {
        try requireLoaded(); let i = try index(sessionID)
        guard state.sessions[i].attachments.contains(where: { $0.id == id }) else { throw WorkflowIssue("附件不存在。") }
        state.sessions[i].attachments.removeAll { $0.id == id }; changed()
    }
    public func selectLeaf(_ id: UUID, sessionID: UUID) throws {
        try requireLoaded(); let i = try index(sessionID)
        _ = try state.sessions[i].path(to: id)
        state.sessions[i].selectedLeafID = id; changed()
    }
    @discardableResult public func editUserMessage(_ id: UUID, text: String, sessionID: UUID) throws -> UUID {
        try requireLoaded(); guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_048_576 else { throw WorkflowIssue("消息为空或超过1MiB。") }
        let i = try index(sessionID)
        guard let old = state.sessions[i].messages.first(where: { $0.id == id && $0.role == .user }) else { throw WorkflowIssue("只能编辑已有用户消息。") }
        let sibling = ChatMessage(parentID: old.parentID, role: .user, text: text, attachments: old.attachments)
        state.sessions[i].messages.append(sibling); state.sessions[i].selectedLeafID = sibling.id; changed(); return sibling.id
    }
    @discardableResult public func forkSession(_ id: UUID, leafID: UUID? = nil) throws -> UUID {
        try requireLoaded(); guard state.sessions.count < 512 else { throw WorkflowIssue("会话数量已达上限。") }
        let source = state.sessions[try index(id)]
        let leaf = leafID ?? source.selectedLeafID
        let path = try source.path(to: leaf)
        if let activeAttemptID, path.contains(where: { $0.attemptID == activeAttemptID }) {
            throw WorkflowIssue("这条路径仍在生成，请等待停止后再分叉。")
        }
        var fork = ChatSession(title: Self.derivedTitle(source.title, suffix: " · 分支"))
        fork.messages = path; fork.attempts = source.attempts.filter { a in path.contains(where: { $0.attemptID == a.id }) }.map { a in
            // Attempt provenance remains tied to its originating session. A fork's copied
            // immutable history is not eligible for retry or mutation of that attempt.
            var copy = ChatAttempt(id: a.id, sessionID: fork.id, userMessageID: a.userMessageID,
                               assistantMessageID: a.assistantMessageID, node: a.node,
                               messagesJSON: a.messagesJSON, inputs: a.inputs, systemPrompt: a.systemPrompt,
                               createdAt: a.createdAt, status: a.status)
            copy.rawText = a.rawText; copy.response = a.response; copy.output = a.output; copy.issue = a.issue
            return copy
        }
        fork.selectedLeafID = leaf; fork.configuration = source.configuration; fork.systemPrompt = source.systemPrompt
        fork.draft = source.draft; fork.attachments = source.attachments
        fork.originSessionID = id; fork.originLeafID = leaf
        state.sessions.append(fork); state.selectedSessionID = fork.id; changed(); return fork.id
    }

    private struct FormMessage: Encodable {
        let role: String
        let parts: [FormPart]
        let reasoningContent: String?
        let toolCalls: [TextToolCall]?
    }
    private struct FormPart: Encodable { let type: String; let text: String?; let index: Int? }
    private func prepared(_ path: [ChatMessage], attempts: [ChatAttempt], prompt: String, attachments: [ChatAttachment], system: String,
                          node source: WorkflowNode) async throws -> (WorkflowNode, String, [String: WorkflowValue]) {
        var messages: [FormMessage] = []
        var images: [WorkflowAssetReference] = [], videos: [WorkflowAssetReference] = []
        if !system.isEmpty { messages.append(.init(role: "system", parts: [.init(type: "text", text: system, index: nil)], reasoningContent: nil, toolCalls: nil)) }
        for entry in path + [ChatMessage(parentID: path.last?.id, role: .user, text: prompt, attachments: attachments)] {
            var parts: [FormPart] = []
            var reasoning: String?
            if entry.role == .user {
                for item in entry.attachments {
                    _ = try await store.workflowData(item.reference)
                    switch item.reference.kind {
                    case .text:
                        guard let text = item.textSnapshot else { throw WorkflowIssue("文字附件缺少冻结快照。") }
                        parts.append(.init(type: "text", text: "[Source material: \(item.name)]\n\(text)\n[/Source material]", index: nil))
                    case .image:
                        parts.append(.init(type: "image", text: nil, index: images.count)); images.append(item.reference)
                    case .video:
                        parts.append(.init(type: "video", text: nil, index: videos.count)); videos.append(item.reference)
                    default: throw WorkflowIssue("附件类型不能用于文字聊天。")
                    }
                }
                parts.append(.init(type: "text", text: entry.text, index: nil))
            } else {
                guard let attemptID = entry.attemptID,
                      let attempt = attempts.first(where: { $0.id == attemptID }),
                      attempt.status == .completed, let response = attempt.response,
                      response.toolCalls.isEmpty, response.finishReason != .toolCalls,
                      response.finishReason != .incomplete,
                      let final = response.finalText, !final.isEmpty else {
                    throw WorkflowIssue("所选路径含未完成或待处理工具调用；请从此前用户消息分叉或缩短上下文。")
                }
                parts.append(.init(type: "text", text: final, index: nil))
                reasoning = response.reasoningText
            }
            messages.append(.init(role: entry.role.rawValue, parts: parts, reasoningContent: reasoning, toolCalls: nil))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(messages)
        guard bytes.count <= 1_048_576 else { throw WorkflowIssue("完整聊天消息超过1MiB；请显式开启新会话或分叉较短路径。") }
        let limit = source.parameters["maximumPromptTokens"]?.integer ?? 0
        let estimate = (bytes.count + 2) / 3 + images.count * 1024 + videos.count * 4096
        guard limit > 0, estimate <= limit else { throw WorkflowIssue("保守估计输入约\(estimate) token，超过所选上限\(limit)；这不是精确分词。请显式开启新会话或分叉较短路径。") }
        var node = source
        node.parameters["task"] = .text("")
        node.parameters["messagesJSON"] = .text(String(decoding: bytes, as: UTF8.self))
        try WorkflowRegistry.standard.validate(node)
        func port(_ refs: [WorkflowAssetReference], kind: WorkflowDataKind) -> WorkflowValue? {
            guard !refs.isEmpty else { return nil }
            return .data(.list(element: .asset(kind), items: refs.map { .init(id: UUID().uuidString, value: .asset($0)) }))
        }
        var inputs: [String: WorkflowValue] = [:]
        if let value = port(images, kind: .image) { inputs["images"] = value }
        if let value = port(videos, kind: .video) { inputs["video"] = value }
        return (node, String(decoding: bytes, as: UTF8.self), inputs)
    }

    public func send(sessionID: UUID) async throws {
        try requireLoaded()
        guard !hasInvalidParameterText(sessionID: sessionID) else {
            throw WorkflowIssue("回答参数仍有未完成或无效输入，请先修正。")
        }
        guard allowsSubmission(), !isRunning, pendingSaveAttemptID == nil else { throw WorkflowIssue("已有聊天推理或待保存结果；请等待或重试保存。其他会话可以继续编辑。") }
        let i = try index(sessionID), session = state.sessions[i]
        if session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let user = try session.path(to: session.selectedLeafID).last, user.role == .user {
            try await regenerate(user.id, sessionID: sessionID)
            return
        }
        guard !session.archived, let node = session.configuration,
              !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowIssue("请填写消息并选择模型。") }
        let path = try session.path(to: session.selectedLeafID)
        guard path.last?.role != .user else { throw WorkflowIssue("所选路径已有待回复用户消息，请重试该消息或选择已完成路径。") }
        let prepared = try await prepared(path, attempts: session.attempts, prompt: session.draft, attachments: session.attachments,
                                          system: session.systemPrompt, node: node)
        let user = ChatMessage(parentID: session.selectedLeafID, role: .user, text: session.draft, attachments: session.attachments)
        try await launch(sessionID: sessionID, user: user, prepared: prepared,
                         systemPrompt: session.systemPrompt, expectedLeafID: session.selectedLeafID, clearDraft: true)
    }
    public func regenerate(_ userMessageID: UUID, sessionID: UUID) async throws {
        try requireLoaded()
        guard !hasInvalidParameterText(sessionID: sessionID) else {
            throw WorkflowIssue("回答参数仍有未完成或无效输入，请先修正。")
        }
        guard allowsSubmission(), !isRunning, pendingSaveAttemptID == nil else { throw WorkflowIssue("已有聊天推理或待保存结果。") }
        let session = state.sessions[try index(sessionID)]
        guard !session.archived, let node = session.configuration,
              let user = session.messages.first(where: { $0.id == userMessageID && $0.role == .user }) else { throw WorkflowIssue("需要已有用户消息和模型。") }
        let prior = try session.path(to: user.parentID)
        let prepared = try await prepared(prior, attempts: session.attempts, prompt: user.text, attachments: user.attachments,
                                          system: session.systemPrompt, node: node)
        try await launch(sessionID: sessionID, user: user, prepared: prepared,
                         systemPrompt: session.systemPrompt, expectedLeafID: session.selectedLeafID, clearDraft: false)
    }
    private func launch(sessionID: UUID, user: ChatMessage,
                        prepared: (WorkflowNode, String, [String: WorkflowValue]),
                        systemPrompt: String, expectedLeafID: UUID?, clearDraft: Bool) async throws {
        guard !hasInvalidParameterText(sessionID: sessionID) else {
            throw WorkflowIssue("回答参数仍有未完成或无效输入，请先修正。")
        }
        guard allowsSubmission(), !isRunning, pendingSaveAttemptID == nil else {
            throw WorkflowIssue("另一次聊天推理已开始；请等待资源释放后重试。")
        }
        let i = try index(sessionID)
        let firstMessageTitle = clearDraft && !state.sessions[i].messages.contains(where: { $0.role == .user })
            ? Self.derivedTitle(user.text, characterLimit: 80) : nil
        let attemptID = UUID(), assistantID = UUID()
        let assistant = ChatMessage(id: assistantID, parentID: user.id, role: .assistant, text: "", attemptID: attemptID)
        let attempt = ChatAttempt(id: attemptID, sessionID: sessionID, userMessageID: user.id,
                                  assistantMessageID: assistantID, node: prepared.0, messagesJSON: prepared.1,
                                  inputs: prepared.2, systemPrompt: systemPrompt)
        if !state.sessions[i].messages.contains(where: { $0.id == user.id }) { state.sessions[i].messages.append(user) }
        state.sessions[i].messages.append(assistant); state.sessions[i].attempts.append(attempt)
        if state.sessions[i].selectedLeafID == expectedLeafID { state.sessions[i].selectedLeafID = assistantID }
        if clearDraft {
            if state.sessions[i].draft == user.text && state.sessions[i].attachments == user.attachments {
                state.sessions[i].draft = ""; state.sessions[i].attachments = []
            }
            if let firstMessageTitle { state.sessions[i].title = firstMessageTitle }
        }
        changed(); cancelRequested = false; error = nil; isRunning = true; activeSessionID = sessionID; activeAttemptID = attemptID; phase = "正在保存冻结输入…"
        runTask = Task { [self] in
            defer { isRunning = false; activeSessionID = nil; activeAttemptID = nil; runTask = nil
                    if pendingSaveAttemptID == nil { services = nil } }
            do {
                try await flush() // Immutable attempt is durable before model admission.
                if cancelRequested { throw CancellationError() }
                let service = try makeServices(); services = service
                service.progress = { [weak self] value in self?.phase = value }
                service.languagePreviewChanged = { [weak self] stepID, text in
                    guard let self, self.isRunning, self.activeAttemptID == stepID, !text.isEmpty,
                          let si = self.state.sessions.firstIndex(where: { $0.id == sessionID }),
                          let ai = self.state.sessions[si].attempts.firstIndex(where: { $0.id == attemptID }),
                          self.state.sessions[si].attempts[ai].status == .running else { return }
                    self.state.sessions[si].attempts[ai].rawText = text
                    self.changed(checkpoint: true)
                }
                if cancelRequested { throw CancellationError() }
                try service.beginPlan()
                let result = try await service.executeCall(.init(node: prepared.0, stepID: attemptID, inputs: prepared.2))
                guard case .outputs(let values) = result, let raw = values["raw"]?.asset ?? values["output"]?.asset else { throw WorkflowIssue("文字输出缺少已发布原文。") }
                try await finishAttempt(sessionID: sessionID, attemptID: attemptID, reference: raw)
                phase = "已完成"; try await flush()
            } catch {
                if services?.hasPendingSaves == true { pendingSaveAttemptID = attemptID }
                if let si = state.sessions.firstIndex(where: { $0.id == sessionID }),
                   let ai = state.sessions[si].attempts.firstIndex(where: { $0.id == attemptID }) {
                    let refs = (try? await store.workflowAssets(forStepID: attemptID)) ?? []
                    if let raw = refs.first, let response = try? await services?.readLanguageResponse(raw) {
                        state.sessions[si].attempts[ai].output = raw
                        state.sessions[si].attempts[ai].response = response
                        state.sessions[si].attempts[ai].rawText = response.rawText
                        state.sessions[si].attempts[ai].status = response.finishReason == .stop && response.toolCalls.isEmpty ? .completed : .partial
                    } else {
                        state.sessions[si].attempts[ai].status = !state.sessions[si].attempts[ai].rawText.isEmpty ? .partial : (error is CancellationError ? .cancelled : .failed)
                    }
                    state.sessions[si].attempts[ai].issue = error.localizedDescription
                    changed()
                }
                self.error = error.localizedDescription; phase = "已停止"
                do { try await flush() } catch { saveIssue = error.localizedDescription }
            }
        }
    }
    private func finishAttempt(sessionID: UUID, attemptID: UUID, reference: WorkflowAssetReference) async throws {
        guard let si = state.sessions.firstIndex(where: { $0.id == sessionID }),
              let ai = state.sessions[si].attempts.firstIndex(where: { $0.id == attemptID }) else { throw WorkflowIssue("尝试记录已丢失。") }
        let response = try await services?.readLanguageResponse(reference)
        let raw = try await store.workflowText(reference)
        state.sessions[si].attempts[ai].output = reference
        state.sessions[si].attempts[ai].response = response ?? TextResponse(rawText: raw, finalText: raw, finishReason: .stop)
        state.sessions[si].attempts[ai].rawText = raw
        if let response = state.sessions[si].attempts[ai].response {
            state.sessions[si].attempts[ai].status = response.finishReason == .stop && response.toolCalls.isEmpty ? .completed : .partial
        }
        changed()
    }
    public func cancel() async {
        guard isRunning else { return }
        cancelRequested = true
        phase = "正在取消并释放资源…"
        await services?.cancel()
        await runTask?.value
    }
    public func waitForCompletion() async { await runTask?.value }
    public func retrySave() async {
        guard !isRunning, pendingSaveAttemptID != nil || saveIssue != nil else { return }
        let hadPendingPublication = pendingSaveAttemptID != nil
        do {
            if let id = pendingSaveAttemptID {
                guard let session = state.sessions.first(where: { $0.attempts.contains(where: { $0.id == id }) }),
                      let attempt = session.attempts.first(where: { $0.id == id }), let services else {
                    throw WorkflowIssue("待保存聊天结果已失去原始保存上下文。")
                }
                isRunning = true; defer { isRunning = false }
                let values = try await services.retryQuickPublications(.init(node: attempt.node, stepID: id, inputs: attempt.inputs))
                guard let raw = values["raw"]?.asset ?? values["output"]?.asset else {
                    throw WorkflowIssue("保存恢复未返回已发布文字结果。")
                }
                try await finishAttempt(sessionID: session.id, attemptID: id, reference: raw)
                pendingSaveAttemptID = nil; self.services = nil
            }
            saveIssue = nil; try await flush()
            if hadPendingPublication { error = nil }
        } catch {
            var terminalSaveFailure = false
            if let id = pendingSaveAttemptID, services?.hasPendingSaves != true {
                terminalSaveFailure = true
                if let si = state.sessions.firstIndex(where: { $0.attempts.contains(where: { $0.id == id }) }),
                   let ai = state.sessions[si].attempts.firstIndex(where: { $0.id == id }) {
                    let refs = (try? await store.workflowAssets(forStepID: id)) ?? []
                    if let raw = refs.first, let response = try? await services?.readLanguageResponse(raw) {
                        state.sessions[si].attempts[ai].output = raw
                        state.sessions[si].attempts[ai].response = response
                        state.sessions[si].attempts[ai].rawText = response.rawText
                    }
                    state.sessions[si].attempts[ai].status = .failed
                    state.sessions[si].attempts[ai].issue = error.localizedDescription
                    changed()
                }
                pendingSaveAttemptID = nil; services = nil
                do { try await flush(); saveIssue = nil }
                catch { saveIssue = error.localizedDescription }
            }
            if !terminalSaveFailure { saveIssue = error.localizedDescription }
            self.error = error.localizedDescription
        }
    }
    public func prepareForTermination() async throws {
        guard isLoaded else { return }
        guard !isRunning, pendingSaveAttemptID == nil else { throw WorkflowIssue("聊天仍在运行或有待保存结果。") }
        try await flush()
    }
    public func exportSelectedPath(sessionID: UUID, markdown: Bool = true) throws -> String {
        try requireLoaded(); let session = state.sessions[try index(sessionID)]
        let path = try session.path(to: session.selectedLeafID)
        return path.map { message in
            let body: String
            if let id = message.attemptID, let attempt = session.attempts.first(where: { $0.id == id }) {
                body = attempt.response?.finalText ?? attempt.rawText
            } else { body = message.text }
            return markdown ? "## \(message.role == .user ? "User" : "Assistant")\n\n\(body)" : "\(message.role == .user ? "User" : "Assistant"):\n\(body)"
        }.joined(separator: "\n\n")
    }
    public func saveAssistantFinal(_ messageID: UUID, sessionID: UUID) async throws -> WorkflowAssetReference {
        try requireLoaded(); let session = state.sessions[try index(sessionID)]
        guard let message = session.messages.first(where: { $0.id == messageID && $0.role == .assistant }),
              let attemptID = message.attemptID,
              let attempt = session.attempts.first(where: { $0.id == attemptID }),
              attempt.status == .completed, let final = attempt.response?.finalText, !final.isEmpty else {
            throw WorkflowIssue("只能保存已完成的助手最终正文。")
        }
        return try await store.publishWorkflowAsset(data: Data(final.utf8), mediaType: "text/plain", name: "聊天回答",
                                                    parents: attempt.output.map { [$0] } ?? [], operationID: "d.chat.save-final",
                                                    stepID: attemptID, details: ["chatSessionID": sessionID.uuidString,
                                                                                "chatMessageID": messageID.uuidString,
                                                                                "chatAttemptID": attemptID.uuidString],
                                                    assetID: messageID).record.reference
    }
}

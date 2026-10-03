import AppKit
import DInference
import Foundation
import DWorkbench
import SwiftUI
import Testing
@testable import UI

private actor ChatPresentationNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Presentation fixture must not run inference")
    }
}

private actor ChatPresentationStreamEngine: InferenceEngine {
    private var outcomeWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        let text = String(repeating: "流式文字与 Unicode 👩🏽‍🎨\n", count: 100)
        return .init(id: request.id, events: AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text)); continuation.finish()
        }, cancel: { await self.release() }, outcome: {
            await self.waitForRelease()
            return .cancelled
        })
    }
    private func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { outcomeWaiter = $0 }
    }
    func release() {
        released = true
        outcomeWaiter?.resume(); outcomeWaiter = nil
    }
}

private final class ChatPresentationMemorySettings: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite("Chat presentation boundaries")
@MainActor struct ChatPresentationTests {
    private let fixtureRoot = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)

    private func renderFixture(_ chat: ChatController, model: WorkbenchModel, width: CGFloat,
                               inspector: Bool = false, scrolledUp: Bool = false,
                               inspect: (NSView) -> Void = { _ in }) -> [String: CGRect] {
        var rectangles: [String: CGRect] = [:]
        let view = ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}, initialInspectorVisible: inspector,
            initiallyFollowsBottom: !scrolledUp, initiallyHasNewContent: scrolledUp)
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        inspect(host)
        if let directory = ProcessInfo.processInfo.environment["D_CHAT_PRESENTATION_EVIDENCE"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let name = chat.selectedSession?.title ?? "empty"
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(name.replacingOccurrences(of: "/", with: "_") + "-\(Int(width)).png")
                do { try png.write(to: output, options: .withoutOverwriting) }
                catch { Issue.record("Fixture image write failed: \(error)") }
            }
        }
        return rectangles
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func horizontallyInside(_ rectangle: CGRect?, width: CGFloat) -> Bool {
        guard let rectangle else { return false }
        return rectangle.width > 0 && rectangle.minX >= -1 && rectangle.maxX <= width + 1
    }

    private func node() throws -> WorkflowNode {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["outputMode"] = .text("response")
        node.parameters["task"] = .text("")
        node.parameters["messagesJSON"] = .text("[]")
        return node
    }

    private func attempt(sessionID: UUID, user: ChatMessage, assistant: ChatMessage,
                         status: ChatAttempt.Status, raw: String, node: WorkflowNode) -> ChatAttempt {
        var value = ChatAttempt(id: assistant.attemptID!, sessionID: sessionID, userMessageID: user.id,
            assistantMessageID: assistant.id, node: node,
            messagesJSON: "[]", inputs: [:], systemPrompt: "", status: status)
        value.rawText = raw
        return value
    }

    private func fixture(_ state: ChatState,
                         engine: any InferenceEngine = ChatPresentationNoInference(),
                         prepare: ((ProjectStore) async throws -> ChatState)? = nil) async throws
        -> (ChatController, WorkbenchModel, ProjectStore, URL) {
        let root = fixtureRoot.appendingPathComponent("chat-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"), name: "Chat fixture")
        let savedState = try await prepare?(store) ?? state
        if !savedState.sessions.isEmpty { _ = try await store.saveChatState(savedState, expectedRevision: 0) }
        let runtime = WorkbenchSession(engine: engine, backendID: "presentation.fixture",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let chat = ChatController(store: store) {
            WorkflowServices(store: store, session: runtime) { _, identity in
                .init(identity: identity, reference: .init(directory: root, revision: identity),
                      backendID: "fixture.text", operationID: WorkflowModelRoutes.qwen35,
                      textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024,
                                            profile: TextExecutionCapability.qwen35VLMProfile))
            }
        }
        await chat.load()
        let project = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "presentation.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: ChatPresentationMemorySettings())
        return (chat, WorkbenchModel(projectSession: project), store, root)
    }

    private func close(_ store: ProjectStore, root: URL) async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func emptyConversationRealViewFixture() async throws {
        let (chat, model, store, root) = try await fixture(ChatState())
        #expect(chat.selectedSession == nil)
        let layout = renderFixture(chat, model: model, width: 560)
        #expect(horizontallyInside(layout["empty-conversation"], width: 560))
        #expect(layout["composer"] == nil)
        try await close(store, root: root)
    }

    @Test func longMarkdownRealViewFixture() async throws {
        let source = "# 长回答\n\n| A | B |\n|---|---|\n" +
            String(repeating: "| 中文段落 | `code` 和 **强调** |\n", count: 80)
        let session = try answeredSession(raw: source, status: .completed)
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        #expect(chat.selectedPath.count == 2)
        let layout = renderFixture(chat, model: model, width: 900)
        #expect(horizontallyInside(layout["topbar"], width: 900))
        #expect(horizontallyInside(layout["transcript"], width: 900))
        #expect(horizontallyInside(layout["composer"], width: 900))
        #expect(layout["message-\(session.messages[1].id.uuidString)"] != nil)
        #expect(layout["attempt-status-\(session.attempts[0].id.uuidString)"] != nil)
        #expect(layout["composer"]!.minY >= layout["transcript"]!.maxY - 1)
        try await close(store, root: root)
    }

    @Test func streamingMessageRealViewFixture() async throws {
        var session = ChatSession(title: "流式回答")
        session.configuration = try node()
        session.draft = "请流式回答"
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let engine = ChatPresentationStreamEngine()
        let (chat, model, store, root) = try await fixture(state, engine: engine)
        try await chat.send(sessionID: session.id)
        for _ in 0..<30 where chat.selectedSession?.attempts.first?.rawText.isEmpty != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.selectedSession?.attempts.first?.status == .running)
        #expect(chat.selectedSession?.attempts.first?.rawText.isEmpty == false)
        let layout = renderFixture(chat, model: model, width: 620, scrolledUp: true)
        #expect(horizontallyInside(layout["transcript"], width: 620))
        #expect(horizontallyInside(layout["bottom-button"], width: 620))
        if let attemptID = chat.selectedSession?.attempts.first?.id {
            #expect(layout["attempt-status-\(attemptID.uuidString)"] != nil)
        }
        #expect(!ChatScrollPosition.followsBottom(
            previous: .init(offset: 200, distanceToBottom: 800),
            current: .init(offset: 200, distanceToBottom: 900), wasFollowing: false))
        await engine.release()
        await chat.waitForCompletion()
        try await close(store, root: root)
    }

    @Test func attachmentMessageRealViewFixture() async throws {
        let (chat, model, store, root) = try await fixture(ChatState(), prepare: { store in
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==")!
            let published = try await store.publishWorkflowAsset(data: png, mediaType: "image/png",
                metadata: .init(width: 1, height: 1), name: "草图.png", operationID: "d.asset.import")
            let attachment = ChatAttachment(name: "草图.png", reference: published.record.reference)
            var session = ChatSession(title: "附件与检查器")
            session.messages = [ChatMessage(parentID: nil, role: .user, text: "请看这张图", attachments: [attachment])]
            session.selectedLeafID = session.messages[0].id
            session.attachments = [attachment]
            var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
            return state
        })
        #expect(chat.selectedSession?.attachments.count == 1)
        let layout = renderFixture(chat, model: model, width: 1_300, inspector: true)
        #expect(horizontallyInside(layout["inspector-pane"], width: 1_300))
        #expect(layout["inspector-pane"]?.width == ChatPresentationLayout.inspectorWidth)
        #expect(horizontallyInside(layout["composer"], width: 1_300))
        if let attachmentID = chat.selectedSession?.attachments.first?.id {
            #expect(layout["attachment-\(attachmentID.uuidString)"] != nil)
        }
        try await close(store, root: root)
    }

    @Test func narrowPartialMessageRealViewFixture() async throws {
        var session = try answeredSession(raw: "已保留的部分回答", status: .partial)
        session.attempts[0].issue = "保存失败；回答仍保留"
        let sibling = ChatMessage(parentID: nil, role: .user, text: "修改后的提问")
        session.messages.append(sibling)
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        #expect(chat.selectedSession?.attempts.first?.issue == "保存失败；回答仍保留")
        #expect(chat.selectedSession?.messages.count == 3)
        let layout = renderFixture(chat, model: model, width: 320) { host in
            let pane = descendants(host).first { $0.accessibilityIdentifier() == "chat-sessions-host" }
            #expect(pane != nil && pane?.isHiddenOrHasHiddenAncestor == true)
        }
        #expect(horizontallyInside(layout["transcript"], width: 320))
        #expect(horizontallyInside(layout["composer"], width: 320))
        #expect(layout["attempt-issue-\(session.attempts[0].id.uuidString)"] != nil)
        #expect(layout["branch-menu-\(session.messages[0].id.uuidString)"] != nil)
        #expect(ChatPresentationText.branchSummary(sibling, you: "你", assistant: "助手") == "修改后的提问")
        try await close(store, root: root)
    }

    private func answeredSession(raw: String, status: ChatAttempt.Status) throws -> ChatSession {
        var session = ChatSession(title: "回答夹具")
        let user = ChatMessage(parentID: nil, role: .user, text: "请回答")
        let assistant = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let configuration = try node()
        session.configuration = configuration
        session.messages = [user, assistant]
        session.attempts = [attempt(sessionID: session.id, user: user, assistant: assistant,
            status: status, raw: raw, node: configuration)]
        session.selectedLeafID = assistant.id
        return session
    }

    @Test func literalSourceRemainsAvailableDuringStreamingAndParseDelay() async {
        let final = "# Answer\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let original = "<think>reasoning</think>\n" + final
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: true,
            showingRaw: false, parsed: nil, document: nil) == final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: nil, document: nil) == final)
        let document = await ChatMarkdownPresentation.parse(final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: true, parsed: final, document: document) == original)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: final, document: document) == nil)
    }

    @Test func emptyHTMLRenderFallsBackToLiteralWhileMarkdownRenders() async {
        let html = "<div>保留这段回答</div>"
        let empty = await ChatMarkdownPresentation.parse(html)
        #expect(empty == .empty)
        #expect(ChatMarkdownPresentation.literalText(rendered: html, raw: html, streaming: false,
            showingRaw: false, parsed: html, document: empty) == html)

        let markdown = "# 回答\n\n正常 Markdown"
        let rendered = await ChatMarkdownPresentation.parse(markdown)
        #expect(rendered != .empty)
        #expect(ChatMarkdownPresentation.literalText(rendered: markdown, raw: markdown, streaming: false,
            showingRaw: false, parsed: markdown, document: rendered) == nil)
    }

    @Test func everyModelRunControlSharesNumericAndSaveAdmission() {
        var session = ChatSession()
        session.configuration = WorkflowNode(operationID: "d.model.qwen35-9b", title: "Qwen")
        let invalid = Set([session.id.uuidString + ":temperature"])
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: invalid))
        session.draft = "发送"
        #expect(!ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: invalid))
        #expect(ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        session.draft = " "
        #expect(ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allowsSend(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: true,
            hasSaveIssue: false, invalidFields: []))
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: true, invalidFields: []))
        session.archived = true
        #expect(!ChatRunAdmission.allows(session, isRunning: false, hasPendingSave: false,
            hasSaveIssue: false, invalidFields: []))
    }

    @Test func markdownCannotLoadImagesOrOpenModelLinks() async {
        #expect(!ChatMarkdownPresentation.config.imageConfig.enabled)
        let action = OpenURLAction { ChatMarkdownPresentation.discardURL($0) }
        let accepted = await withCheckedContinuation { continuation in
            action(URL(string: "https://example.invalid/model")!) { continuation.resume(returning: $0) }
        }
        #expect(!accepted)
    }

    @Test func sharedAssetDropRequiresExactStoreInstance() {
        let project = UUID(), original = UUID(), copy = UUID()
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(!ChatAssetDropScope.accepts(projectID: UUID(), instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: project))
    }

    @Test func sidePanesCollapseBeforeConversationIsClipped() {
        #expect(!ChatPresentationLayout.showsSidebar(width: 600, requested: true))
        #expect(!ChatPresentationLayout.showsSidebar(width: 920, requested: true))
        #expect(!ChatPresentationLayout.showsSidebar(width: 952, requested: true))
        #expect(ChatPresentationLayout.showsSidebar(width: 953, requested: true))
        #expect(!ChatPresentationLayout.showsInspector(width: 1_080, requested: true, sidebar: true))
        #expect(!ChatPresentationLayout.showsInspector(width: 1_273, requested: true, sidebar: true))
        #expect(ChatPresentationLayout.showsInspector(width: 1_274, requested: true, sidebar: true))
        #expect(!ChatPresentationLayout.showsInspector(width: 1_000, requested: true, sidebar: false))
        #expect(!ChatPresentationLayout.showsInspector(width: 1_032, requested: true, sidebar: false))
        #expect(ChatPresentationLayout.showsInspector(width: 1_033, requested: true, sidebar: false))
        #expect(ChatPresentationLayout.dismissesNarrowPanel(.inspector, width: 1_300,
            sidebarRequested: true, inspectorRequested: true))
        #expect(!ChatPresentationLayout.dismissesNarrowPanel(.inspector, width: 1_080,
            sidebarRequested: true, inspectorRequested: true))
        #expect(ChatPresentationLayout.dismissesNarrowPanel(.sessions, width: 953,
            sidebarRequested: true, inspectorRequested: false))
        #expect(ChatPresentationLayout.sidebarWidth == 240)
        #expect(ChatPresentationLayout.inspectorWidth == 320)
        #expect(ChatPresentationLayout.messageWidth == 760)
        #expect(ChatPresentationLayout.minimumBodyWidth == 712)
    }

    @Test func narrowRenameAndPreviewWaitForPanelDismissal() {
        enum Detail: String, Identifiable {
            case rename, preview
            var id: Self { self }
        }
        var sheets = ChatSheetQueue<Detail>()
        sheets.openNarrow(.sessions)
        sheets.present(.rename)
        #expect(sheets.narrowPanel == nil && sheets.detail == nil)
        #expect(sheets.narrowSheetVisible)
        #expect(sheets.pendingDetail == .rename)
        sheets.didDismissNarrowPanel()
        #expect(sheets.detail == .rename && sheets.pendingDetail == nil && !sheets.narrowSheetVisible)
        sheets.detail = nil
        sheets.openNarrow(.inspector)
        sheets.present(.preview)
        #expect(sheets.narrowPanel == nil && sheets.detail == nil)
        #expect(sheets.narrowSheetVisible)
        sheets.didDismissNarrowPanel()
        #expect(sheets.detail == .preview && sheets.pendingDetail == nil && !sheets.narrowSheetVisible)
    }

    @Test func streamingGrowthDoesNotOverrideUserScrollPosition() {
        let atBottom = ChatScrollPosition(offset: 600, distanceToBottom: 0)
        let grewWithoutScrolling = ChatScrollPosition(offset: 600, distanceToBottom: 400)
        #expect(ChatScrollPosition.followsBottom(previous: atBottom, current: grewWithoutScrolling,
            wasFollowing: true))
        let scrolledUp = ChatScrollPosition(offset: 350, distanceToBottom: 650)
        #expect(!ChatScrollPosition.followsBottom(previous: grewWithoutScrolling, current: scrolledUp,
            wasFollowing: true))
        let grewAgain = ChatScrollPosition(offset: 350, distanceToBottom: 900)
        #expect(!ChatScrollPosition.followsBottom(previous: scrolledUp, current: grewAgain,
            wasFollowing: false))
        let returnedToBottom = ChatScrollPosition(offset: 1_250, distanceToBottom: 0)
        #expect(ChatScrollPosition.followsBottom(previous: grewAgain, current: returnedToBottom,
            wasFollowing: false))
    }

    @Test func delayedRestoreCannotApplyToAnotherVisitToSameSession() {
        let a = UUID(), b = UUID(), anchor = UUID()
        let first = ChatScrollRestoration(sessionID: a, followsBottom: false, anchor: anchor)
        let other = ChatScrollRestoration(sessionID: b, followsBottom: true, anchor: nil)
        let returnVisit = ChatScrollRestoration(sessionID: a, followsBottom: false, anchor: UUID())
        #expect(first.isCurrent(sessionID: a, pending: first))
        #expect(!first.isCurrent(sessionID: b, pending: other))
        #expect(!first.isCurrent(sessionID: a, pending: returnVisit))
        #expect(!first.isCurrent(sessionID: a, pending: nil))
        #expect(first.anchor == anchor && !first.followsBottom)
    }

    @Test func paneResizeKeepsNativeEditorAndExplicitHidingReleasesInput() throws {
        func pane(_ visible: Bool) -> some View {
            ChatPaneHost(content: TextSourcesQuestionEditor(value: "", editEpoch: 0,
                isEditable: true, accessibilityIdentifier: "pane-editor", onEdit: { _ in }),
                visible: visible, identifier: "pane-host")
        }
        let host = NSHostingView(rootView: pane(true))
        host.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("pinyin", selectedRange: .init(location: 6, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        host.frame.size.width = 240
        host.rootView = pane(true)
        settle()
        #expect(descendants(host).contains { $0 === editor })
        #expect(editor.hasMarkedText() && window.firstResponder === editor)
        host.rootView = pane(false)
        settle()
        #expect(editor.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder !== editor)
        host.rootView = pane(true)
        settle()
        #expect(descendants(host).contains { $0 === editor })
        #expect(!editor.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder !== editor)
    }

    @Test func branchesUseReadableTextAndEmptyFallback() {
        let root = ChatMessage(parentID: nil, role: .user,
            text: "第一段\n第二段，有足够长的摘要内容用于验证菜单裁剪不会暴露 UUID。")
        let empty = ChatMessage(parentID: root.id, role: .assistant, text: "  \n ")
        let summary = ChatPresentationText.branchSummary(root, you: "你", assistant: "助手")
        #expect(summary.hasPrefix("第一段 第二段"))
        #expect(summary.count <= 44)
        #expect(!summary.contains(root.id.uuidString))
        #expect(ChatPresentationText.branchSummary(empty, you: "你", assistant: "助手") == "助手")
    }
}

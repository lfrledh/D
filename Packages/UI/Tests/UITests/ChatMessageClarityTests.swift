import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite("Message clarity boundaries", .serialized) @MainActor
struct ChatMessageClarityTests {
    @Test func formalLanguageResourcesLoadAndChangeWithoutMissingMessageLabels() throws {
        let store = UILanguageStore(preferredLanguages: ["en"])
        let keys = ["copyMessage", "copyAnswer", "copyCurrent", "copied", "editMessage", "regenerate", "regenerateHelp", "read", "readHelp", "more", "quote", "fork", "generation", "editAnswer", "reproduce", "saveAsset", "artifact", "fields", "raw", "viewRaw", "copyRaw", "details", "detailsTitle", "notSaved", "preview", "unparsed", "length", "invalidFormat", "notRecorded", "context", "candidates", "sender", "time", "displayedVersion", "edited", "originalVersion", "recordedModel", "model", "modelRevision", "precision", "parameters", "state", "technical", "generating", "stopped", "partial", "failed", "emptyBody", "toolsUnexecuted", "copyCode", "copyTable", "reasonLoading", "reasonSaving", "reasonBusy", "reasonArchived", "reasonModel", "reasonParameters", "reasonNoQuestion", "reasonSpeech"]
        for locale in ["en", "zh-Hans"] {
            try store.select(locale)
            for key in keys {
                let value = store.text("chat.clarity." + key, fallback: "__missing__")
                #expect(!value.isEmpty && value != "__missing__", "Missing loaded message label: \(locale) / \(key)")
            }
            #expect(store.diagnostics.isEmpty)
        }
        try store.select("en")
        #expect(store.text("chat.clarity.copyAnswer", fallback: "missing") == "Copy answer")
        #expect(store.text("chat.reasoning", fallback: "missing") == "Reasoning")
        let english = ChatMarkdownPresentation.config(for: .init(), language: store)
        #expect(english.codeBlockConfig.copyLabel == "Copy code")
        try store.select("zh-Hans")
        #expect(ChatMarkdownPresentation.config(for: .init(), language: store).codeBlockConfig.copyLabel != english.codeBlockConfig.copyLabel)
    }

    func fixture() -> (ChatSession, ChatMessage, ChatAttempt) {
        var s = ChatSession(title: "Fixture")
        let user = ChatMessage(parentID: nil, role: .user, text: "Question")
        var a = ChatAttempt(sessionID: s.id, userMessageID: user.id, assistantMessageID: UUID(),
            node: .init(operationID: WorkflowModelRoutes.qwen35, title: "Fixture"), messagesJSON: "[]", inputs: [:], systemPrompt: "", status: .completed)
        a.rawText = "<think>private reasoning</think>answer"
        a.response = .init(rawText: a.rawText, reasoningText: "private reasoning", finalText: "answer", finishReason: .stop)
        let m = ChatMessage(id: a.assistantMessageID, parentID: user.id, role: .assistant, text: "", attemptID: a.id)
        s.messages = [user, m]; s.attempts = [a]; s.selectedLeafID = m.id
        return (s, m, a)
    }
    @Test func commandRejectsIdentityChangesButReadsAdvancingStream() {
        var (s, m, a) = fixture()
        let capture = ChatMessageCommandTarget(session: s, message: m, attempt: a)
        #expect(capture.isCurrent(selectedSession: s.id, session: s))
        #expect(!capture.isCurrent(selectedSession: UUID(), session: s))
        s.selectedLeafID = m.parentID
        #expect(!capture.isCurrent(selectedSession: s.id, session: s))
        s.selectedLeafID = m.id
        let revision = ChatTextRevision(messageID: m.id, text: "manual")
        var choices = ChatContextChoices(); choices.revisions = [revision]; choices.adoptedRevisionIDs = [revision.id]; s.contextChoices = choices
        #expect(!capture.isCurrent(selectedSession: s.id, session: s))
        s.contextChoices = nil
        a.status = .running; a.response = nil; a.rawText = "preview"; s.attempts = [a]
        let live = ChatMessageCommandTarget(session: s, message: m, attempt: a)
        #expect(live.isCurrent(selectedSession: s.id, session: s, displayedAttempt: a))
        a.rawText += " next"
        #expect(live.isCurrent(selectedSession: s.id, session: s, displayedAttempt: a))
        #expect(!live.isCurrent(selectedSession: s.id, session: s, displayedAttempt: a, requiresUnchangedValue: true))
    }
    @Test func mainStatusAndSaveFailureRemainIndependent() {
        let (_, _, original) = fixture()
        #expect(ChatMessageNotices.keys(attempt: original, edited: false, pendingSave: false).isEmpty)
        #expect(ChatMessageNotices.keys(attempt: original, edited: false, pendingSave: true) == ["notSaved"])
        var value = original; value.status = .failed; value.response = nil; value.rawText = "partial bytes"
        let keys = ChatMessageNotices.keys(attempt: value, edited: false, pendingSave: true)
        #expect(keys.contains("failed") && keys.contains("unparsed") && keys.contains("notSaved"))
        let edited = ChatMessageNotices.keys(attempt: value, edited: true, pendingSave: false)
        #expect(edited.contains("failed") && edited.contains("edited") && !edited.contains("unparsed"))
        value.status = .partial; value.response = .init(rawText: "limited", finalText: "limited", finishReason: .length)
        #expect(ChatMessageNotices.keys(attempt: value, edited: false, pendingSave: false).contains("length"))
        value.status = .completed; value.outputFormat = .init(kind: .json)
        #expect(ChatMessageNotices.keys(attempt: value, edited: false, pendingSave: false).contains("invalidFormat"))
    }
    @Test func menuKeepsCommandsAndFixedPrimaryOrder() {
        let ids = ["copy", "favorite", "quote", "fork", "context", "generate", "new-candidate", "compare", "adopt", "adopt-partial", "candidates", "versions", "reproduce", "save", "workflow", "artifact", "fields", "speak", "pause-reading", "resume-reading", "stop-reading", "sources", "raw", "details"]
        var executed: [String] = []
        let commands = ids.map { id in ChatActionMenuItem(id: id, title: id) { executed.append(id) } }
        let menu = ChatMessageMenuOrganization.organize(commands, contextTitle: "Context", generationTitle: "Generate", user: false)
        #expect(menu.filter { !$0.isSeparator }.map(\.id) == ["favorite", "quote", "fork", "context", "generation", "save", "workflow", "artifact", "fields", "speak", "pause-reading", "resume-reading", "stop-reading", "sources", "raw", "details"])
        #expect(menu.first { $0.id == "generation" }?.children?.map(\.id) == ["generate", "new-candidate", "compare", "adopt", "adopt-partial", "candidates", "versions", "reproduce"])
        #expect(ChatMessageMenuOrganization.primaryIDs(user: true) == ["copy", "edit"])
        #expect(ChatMessageMenuOrganization.primaryIDs(user: false) == ["copy", "new-candidate", "speak"])
        #expect(ChatMessageMenuOrganization.primaryIDs(user: false, compact: true) == ["copy"])
        var valid = false
        let guarded = commands[0].validated { valid }
        guarded.action?(); #expect(executed.isEmpty && !guarded.isCurrent())
        valid = true; guarded.action?(); #expect(executed == ["copy"])
    }
    @Test func displayedManualCopyAndOriginalOutputStaySeparate() throws {
        var (s, m, a) = fixture()
        let revision = ChatTextRevision(messageID: m.id, text: "Edited é 👩🏽‍🎨")
        var choices = ChatContextChoices(); choices.revisions = [revision]; choices.adoptedRevisionIDs = [revision.id]; s.contextChoices = choices
        #expect(ChatMessageContent.answerText(message: m, attempt: a, selectedAnswer: s.selectedAnswer(messageID: m.id)) == revision.text)
        #expect(ChatChannelPresentation(a).rawText == a.rawText)
        #expect(s.attempts == [a])
        let view = ChatMessageContent(message: m, attempt: a, selectedAnswer: s.selectedAnswer(messageID: m.id), onPreview: { _ in })
        #expect(view.recordedReasoning == "private reasoning")
    }
    @Test func independentBodyAndToolGeometry() async throws {
        for user in [false, true] {
            var frames: [String: CGRect] = [:]
            func record<V: View>(_ name: String, _ content: V) -> some View {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("clarity-test")) } action: { frames[name] = $0 }
            }
            let root = ChatBubbleLayout(user: user) {
                ChatMessageStack(user: user) {
                    record("bubble", Text("好").padding(.horizontal, 14).padding(.vertical, 12))
                    record("tools", Color.clear.frame(width: user ? 92 : 124, height: 28))
                    record("footer", VStack(spacing: 0) { EmptyView() })
                }
            }.coordinateSpace(name: "clarity-test")
            let host = NSHostingView(rootView: root)
            host.frame = .init(x: 0, y: 0, width: 600, height: 120)
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let body = try #require(frames["bubble"]), tools = try #require(frames["tools"])
            #expect(body.width < 80)
            #expect(abs(tools.minY - body.maxY - 6) < 0.5)
            #expect(tools.height == 28 && tools.width == (user ? 92 : 124))
            #expect(abs((user ? body.maxX - tools.maxX : body.minX - tools.minX)) < 0.5)
            #expect((frames["footer"]?.height ?? -1) == 0)
        }
    }
}

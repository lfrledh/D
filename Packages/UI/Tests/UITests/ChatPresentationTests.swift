import AppKit
import DInference
import Foundation
import DWorkbench
import SwiftUI
import Testing
import XCTest
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

private actor ChatPresentationGatedStreamEngine: InferenceEngine {
    private var continuation: AsyncThrowingStream<InferenceOutput, Error>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var drained = false
    private var completedResponse: TextResponse?
    private(set) var cancellationSeen = false
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        let pair = AsyncThrowingStream<InferenceOutput, Error>.makeStream()
        continuation = pair.continuation
        return .init(id: request.id, events: pair.stream,
            cancel: { await self.cancel() }, outcome: {
                await self.waitForDrain()
                return await self.result()
            })
    }
    func emit(_ text: String) { continuation?.yield(.textDelta(text)) }
    private func cancel() { cancellationSeen = true; continuation?.finish() }
    private func waitForDrain() async {
        if drained { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func result() -> RunOutcome {
        if let completedResponse { return .completed(.init(textResponse: completedResponse)) }
        return .cancelled
    }
    func drain(response: TextResponse? = nil) {
        completedResponse = response
        drained = true; continuation?.finish()
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
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
    @Test func sidebarRevealCancellationAndOwnerDisableHideNativeReceiver() async throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        func pane(open: Bool, enabled: Bool = true) -> some View {
            WorkbenchSidebar(leading: true, expanded: open, title: "Fixture", identifier: "fixture-toggle",
                hostIdentifier: "fixture-host", toggle: {}) {
                    TextSourcesQuestionEditor(value: "保留输入", editEpoch: 0, isEditable: true, onEdit: { _ in })
                }.disabled(!enabled)
        }
        let host = NSHostingView(rootView: pane(open: true))
        host.frame = .init(x: 0, y: 0, width: 260, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        }
        try await settle()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(window.makeFirstResponder(editor))
        host.rootView = pane(open: true, enabled: false); try await settle()
        #expect(editor.isHiddenOrHasHiddenAncestor && window.firstResponder !== editor)
        host.rootView = pane(open: false); try await settle()
        host.rootView = pane(open: true); try await settle()
        // Close before the pending reveal completes; it must not reopen an old receiver.
        host.rootView = pane(open: false); try await settle()
        try await Task.sleep(for: .milliseconds(800)); try await settle()
        #expect(editor.isHiddenOrHasHiddenAncestor)
        host.rootView = pane(open: true)
        try await settle()
        #expect(editor.isHiddenOrHasHiddenAncestor, "An expired reveal must not bypass the new opening transition")
        // Default morph is 200ms: native content must be ready before 300ms,
        // without the previous 700ms reveal wait and subsequent title fade.
        try await Task.sleep(for: .milliseconds(160)); host.layoutSubtreeIfNeeded()
        #expect(descendants(host).contains { $0 === editor })
        #expect(!editor.isHiddenOrHasHiddenAncestor && editor.string == "保留输入")
        #expect(window.firstResponder !== editor)
    }

    @Test func quickSidebarsStayOpenAcrossCategoriesAtMinimumWindow() async throws {
        var state = ChatState(); let session = ChatSession(title: "Shared sidebar fixture")
        state.sessions = [session]; state.selectedSessionID = session.id
        let (_, model, store, root) = try await fixture(state)
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("No inference permitted") }
        await quick.load()
        let sidebars = WorkbenchSidebarState(); sidebars.trailing = true
        let host = NSHostingView(rootView: QuickGenerationView(quick: quick, model: model,
            selectedResults: .constant([:]), onChooseModel: {}, onSettingsToCanvas: { _ in },
            onResultToCanvas: { _ in }, onValueToCanvas: { _ in })
            .environment(\.workbenchSidebars, sidebars))
        host.frame = .init(x: 0, y: 0, width: 1080, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        var previousLeft: NSView?, previousRight: NSView?
        for category: QuickCategory in [.image, .video, .audio, .text] {
            quick.selectCategory(category)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
            let left = try #require(descendants(host).first { $0.accessibilityIdentifier() == "quick-settings-host" })
            let right = try #require(descendants(host).first { $0.accessibilityIdentifier() == "quick-assets-host" })
            #expect(!left.isHiddenOrHasHiddenAncestor && !right.isHiddenOrHasHiddenAncestor)
            let leftFrame = left.convert(left.bounds, to: host), rightFrame = right.convert(right.bounds, to: host)
            #expect(leftFrame.width == 260 && rightFrame.width == 288)
            #expect(rightFrame.minX - leftFrame.maxX >= 432)
            if let previousLeft, let previousRight { #expect(left === previousLeft && right === previousRight) }
            previousLeft = left; previousRight = right
        }
        #expect(quick.state.runs.isEmpty)
        try await quick.flush(); try await close(store, root: root)
    }

    @Test func sharedSidebarsCoexistAndRetainInputWhenCollapsed() async throws {
        let session = try answeredSession(raw: "保留阅读正文", status: .completed)
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        let sidebars = WorkbenchSidebarState(); sidebars.trailing = true
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {})
            .observingLayout { rectangles[$0] = $1 }.environment(\.workbenchSidebars, sidebars))
        host.frame = .init(x: 0, y: 0, width: 1080, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let left = try #require(descendants(host).first { $0.accessibilityIdentifier() == "chat-sessions-host" })
        let right = try #require(descendants(host).first { $0.accessibilityIdentifier() == "chat-inspector-host" })
        let editor = try #require(descendants(left).compactMap { $0 as? NSTextView }.first {
            $0.accessibilityIdentifier() == "chat-system-\(session.id.uuidString)"
        })
        let composer = try #require(descendants(host).compactMap { $0 as? FileDropTextView }.first)
        #expect(!left.isHiddenOrHasHiddenAncestor && !right.isHiddenOrHasHiddenAncestor)
        for key in ["composer-send", "paths"] {
            let control = try #require(rectangles[key])
            #expect(!control.intersects(try #require(rectangles["sessions-pane"])))
            #expect(!control.intersects(try #require(rectangles["inspector-pane"])))
        }
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("pinyin", selectedRange: .init(location: 6, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        // The other pane can close and reopen without touching this editor or IME.
        sidebars.trailing = false; settle()
        #expect(right.isHiddenOrHasHiddenAncestor && !left.isHiddenOrHasHiddenAncestor)
        sidebars.trailing = true
        try await Task.sleep(for: .milliseconds(800)); settle()
        #expect(editor.hasMarkedText() && window.firstResponder === editor)
        sidebars.leading = false; settle()
        #expect(left.isHiddenOrHasHiddenAncestor && !right.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder !== editor)
        sidebars.leading = true
        try await Task.sleep(for: .milliseconds(800)); settle()
        #expect(descendants(host).contains { $0 === editor })
        #expect(descendants(host).contains { $0 === composer })
        #expect(!left.isHiddenOrHasHiddenAncestor && !right.isHiddenOrHasHiddenAncestor)
        try await close(store, root: root)
    }

    @Test func completeComposerGrowsFromShortDraftWithoutReplacingInput() async throws {
        var session = ChatSession(title: "Composer size")
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}).observingLayout { rectangles[$0] = $1 })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        for size in [CGSize(width: 1280, height: 820), CGSize(width: 1080, height: 580)] {
            host.frame.size = size; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let editor = try #require(descendants(host).compactMap { $0 as? FileDropTextView }.first)
            let scroll = try #require(editor.enclosingScrollView)
            #expect(scroll.frame.height >= 25 && scroll.frame.height <= 36)
            #expect(try #require(rectangles["composer-capsule"]).height <= 56)
            window.makeFirstResponder(editor)
            editor.insertText("Short draft", replacementRange: .init(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            #expect(scroll.frame.height <= 36)
            let shortPlate = try #require(rectangles["composer-capsule"])
            #expect(ChatComposerShape(multiline: false).path(in: shortPlate) == Capsule().path(in: shortPlate))
            let longDraft = String(repeating: "Long draft line\n", count: 40)
            editor.insertText(longDraft,
                replacementRange: .init(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            #expect(descendants(host).compactMap { $0 as? FileDropTextView }.first === editor)
            #expect(scroll.frame.height > 100 && scroll.frame.height <= 180)
            let composer = try #require(rectangles["composer"])
            #expect(composer.contains(try #require(rectangles["composer-send"])))
            let capsule = try #require(rectangles["composer-capsule"])
            let outline = ChatComposerShape(multiline: true).path(in: capsule)
            #expect(outline.contains(CGPoint(x: capsule.minX + 12, y: capsule.minY + 12)))
            #expect(!Capsule().path(in: capsule).contains(CGPoint(x: capsule.minX + 12, y: capsule.minY + 12)),
                    "Multiline text must no longer be surrounded by giant capsule ends")
            for key in ["composer-editor", "composer-send"] {
                let bounds = try #require(rectangles[key])
                for point in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                              CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                    #expect(outline.contains(point), "Native editor and action corners must stay inside the continuous rounded outline")
                }
            }
            #expect(editor.frame.height > scroll.contentView.bounds.height + 1)
            editor.breakUndoCoalescing()
            let undo = try #require(editor.undoManager)
            undo.beginUndoGrouping()
            editor.insertText("", replacementRange: .init(location: 0, length: editor.string.utf16.count))
            undo.endUndoGrouping()
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            #expect(scroll.frame.height <= 36)
            #expect(editor.frame.height <= scroll.contentView.bounds.height + 1,
                    "A shortened draft must release the old document height and overlay gutter")
            #expect(abs(scroll.contentView.bounds.minY) <= 1)
            let clip = scroll.contentView
            let right = clip.convert(NSPoint(x: clip.bounds.maxX - 2, y: clip.bounds.minY + 12), to: host.superview)
            #expect(host.hitTest(right) === editor, "Right-edge typing must recover after shrinking")
            undo.undo()
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            #expect(editor.string == longDraft && editor.frame.height > scroll.contentView.bounds.height + 1)
            undo.redo()
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            #expect(editor.string.isEmpty && editor.frame.height <= scroll.contentView.bounds.height + 1)
        }
        try await chat.flush(); try await close(store, root: root)
    }

    @Test func closedConversationPreservesDraftAndRestoresEditableComposer() async throws {
        var session = ChatSession(title: "Deleted input")
        session.draft = "Preserved draft"
        var choices = ChatContextChoices(); choices.deletedAt = Date(); session.contextChoices = choices
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}).observingLayout { rectangles[$0] = $1 })
        host.frame = .init(x: 0, y: 0, width: 1080, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        }
        try await settle()
        #expect(rectangles["composer-readonly"] != nil)
        #expect(descendants(host).compactMap { $0 as? FileDropTextView }.isEmpty,
                "Do not advertise a normal input field that silently rejects typing")
        #expect(chat.selectedSession?.contextChoices?.deletedAt != nil && chat.selectedSession?.draft == session.draft)
        try chat.setDeleted(false, sessionID: session.id); try await settle()
        let editor = try #require(descendants(host).compactMap { $0 as? FileDropTextView }.first)
        #expect(editor.isEditable && editor.string == session.draft)
        try chat.setArchived(true, sessionID: session.id); try await settle()
        #expect(descendants(host).compactMap { $0 as? FileDropTextView }.isEmpty)
        try chat.setArchived(false, sessionID: session.id); try await settle()
        #expect(try #require(descendants(host).compactMap { $0 as? FileDropTextView }.first).isEditable)
        #expect(chat.selectedSession?.draft == session.draft && chat.state.sessions.count == 1)
        try chat.setArchived(true, sessionID: session.id)
        // A fixture-only closed store gives a deterministic save failure without
        // changing disk permissions or touching any user project.
        try await store.close()
        do { try await chat.flush(); Issue.record("Expected closed-store save failure") } catch {}
        #expect(chat.saveIssue != nil)
        try await settle()
        #expect(rectangles["composer-retry-save"] != nil)
        try FileManager.default.removeItem(at: root)
    }

    @Test func composerFileDropHitRegionInCompleteHost() async throws {
        var session = ChatSession(title: "Drop geometry")
        session.draft = "落点测试：左侧区域｜右侧区域。保留这段草稿，不发送。"
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state, withWorkflowOwner: true)
        for hiddenWorkflow in [false, true] {
            let content = ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
                onSavedAsset: { _ in }, onAssetsChanged: {})
            let host = NSHostingView(rootView: ChatBottomCompositionFixture(chat: chat, model: model,
                content: AnyView(content), includesHiddenWorkflow: hiddenWorkflow, libraryStore: nil))
            host.frame = .init(x: 0, y: 0, width: 1057, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let editor = try #require(descendants(host).compactMap { $0 as? FileDropTextView }.first)
            let clip = try #require(editor.enclosingScrollView?.contentView)
            if hiddenWorkflow {
                let canvas = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
                #expect(canvas.isHiddenOrHasHiddenAncestor,
                    "Inactive workflow must be natively hidden; opacity/hit-testing alone leaves drag destinations active")
            }
            #expect(editor.registeredDraggedTypes.contains(.fileURL), "Hit receiver must actually register file URLs; direct method calls bypass this prerequisite")
            for x in [CGFloat(2), clip.bounds.width * 0.25, clip.bounds.width * 0.5, clip.bounds.width - 2] {
                let local = NSPoint(x: clip.bounds.minX + x, y: clip.bounds.minY + 12)
                let inParent = clip.convert(local, to: host.superview)
                let hit = host.hitTest(inParent)
                #expect(hit === editor, "Visible composer point must hit its file receiver, hiddenWorkflow=\(hiddenWorkflow), x=\(x), hit=\(String(describing: hit)), clip=\(clip.bounds), editor=\(editor.frame), content=\(String(describing: editor.enclosingScrollView?.contentSize))")
            }
            #expect(chat.selectedSession?.draft == session.draft)
            #expect(chat.selectedSession?.attachments.isEmpty == true && chat.selectedSession?.messages.isEmpty == true)
        }
        _ = await model.projectSession.requestClose()
        try await close(store, root: root)
    }

    @Test func inactiveWorkflowRetainsNativeViewportAndRestoresReceivers() async throws {
        let (_, model, store, root) = try await fixture(ChatState(), withWorkflowOwner: true)
        let tags = ModelNodeTagStore()
        func pane(_ visible: Bool) -> some View {
            RetainedContentHost(content: WorkflowHostView(model: model, nodeTags: tags),
                visible: visible, identifier: "workflow-retained-surface",
                fallbackSize: CGSize(width: 760, height: 500))
        }
        let host = NSHostingView(rootView: pane(true))
        host.frame = .init(x: 0, y: 0, width: 1057, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        try await settle()
        let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
        let scroll = try #require(probe.enclosingScrollView)
        let receivers = descendants(host).filter { !$0.registeredDraggedTypes.isEmpty }
        #expect(!receivers.isEmpty && receivers.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        // Exercise the existing viewport callback, not a second navigation state.
        probe.onWheel(12, .init(x: 120, y: 100), scroll.contentView.bounds.origin, scroll.contentView.bounds.size)
        try await settle()
        scroll.contentView.scroll(to: .init(x: 300, y: 400)); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let documentSize = try #require(scroll.documentView).frame.size
        let offset = scroll.contentView.bounds.origin
        let graph = model.projectSession.workflow?.graph
        for visible in [false, true] {
            host.rootView = pane(visible); try await settle()
            #expect(descendants(host).contains { $0 === probe })
            #expect(receivers.allSatisfy { receiver in descendants(host).contains { $0 === receiver } })
            #expect(receivers.allSatisfy { !$0.registeredDraggedTypes.isEmpty })
            #expect(receivers.allSatisfy { $0.isHiddenOrHasHiddenAncestor == !visible })
            #expect(try #require(scroll.documentView).frame.size == documentSize)
            #expect(abs(scroll.contentView.bounds.minX - offset.x) < 1)
            #expect(abs(scroll.contentView.bounds.minY - offset.y) < 1)
            #expect(model.projectSession.workflow?.graph == graph)
        }
        _ = await model.projectSession.requestClose()
        try await close(store, root: root)
    }

    @Test func libraryAttachmentCopiesFromExplicitInstanceWithoutSending() async throws {
        var session = ChatSession(title: "Destination"); session.draft = "保留草稿"
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, _, destination, destinationRoot) = try await fixture(state)
        let (_, _, source, sourceRoot) = try await fixture(ChatState())
        do {
            let file = sourceRoot.appendingPathComponent("source.txt")
            let bytes = Data("跨项目原件 👩🏽‍🎨".utf8); try bytes.write(to: file)
            let published = try await source.importWorkflowFile(at: file)
            let original = await source.snapshot()
            let choice = try #require(try await ChatProjectAttachmentChoice.load(from: source).first)
            await #expect(throws: (any Error).self) { try await choice.adopt(in: chat, sessionID: session.id) }
            #expect(chat.selectedSession?.attachments.isEmpty == true)
            try await choice.adopt(in: chat, sessionID: session.id, from: source)
            let attachment = try #require(chat.selectedSession?.attachments.first)
            #expect(attachment.reference.projectID != published.record.reference.projectID)
            #expect(try await destination.workflowData(attachment.reference) == bytes)
            #expect(await source.snapshot() == original)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(chat.selectedSession?.draft == session.draft && chat.selectedSession?.attempts.isEmpty == true)
            try await chat.flush()
            #expect(try await destination.chatState().sessions == chat.state.sessions)
            try await close(source, root: sourceRoot); try await close(destination, root: destinationRoot)
        } catch {
            try? await close(source, root: sourceRoot); try? await close(destination, root: destinationRoot); throw error
        }
    }

    @Test func publishedProjectAttachmentPreservesOwnerDraftAndVersion() async throws {
        var session = ChatSession(title: "Asset recipient")
        session.draft = "保留草稿 👩🏽‍🎨"
        let other = ChatSession(title: "Other conversation")
        var state = ChatState(); state.sessions = [session, other]; state.selectedSessionID = session.id
        let (chat, _, store, root) = try await fixture(state)
        do {
            let before = await store.snapshot()
            #expect(try await ChatProjectAttachmentChoice.load(from: store).isEmpty)
            #expect(await store.snapshot() == before)
            let file = root.appendingPathComponent("result.txt")
            let bytes = Data("Reading corner".utf8)
            try bytes.write(to: file)
            let published = try await store.importWorkflowFile(at: file)
            let choices = try await ChatProjectAttachmentChoice.load(from: store)
            let choice = try #require(choices.first { $0.reference == published.record.reference })
            try chat.selectSession(other.id)
            await #expect(throws: (any Error).self) { try await choice.adopt(in: chat, sessionID: session.id) }
            try chat.selectSession(session.id)
            let wrongInstance = ChatProjectAttachmentChoice(name: choice.name, reference: choice.reference, instanceID: UUID())
            await #expect(throws: (any Error).self) { try await wrongInstance.adopt(in: chat, sessionID: session.id) }
            #expect(chat.selectedSession?.attachments.isEmpty == true)
            try await choice.adopt(in: chat, sessionID: session.id)
            #expect(chat.selectedSession?.draft == session.draft)
            #expect(chat.selectedSession?.attachments.map(\.reference) == [published.record.reference])
            #expect(chat.selectedSession?.attempts.isEmpty == true)
            #expect(chat.state.sessions.first { $0.id == other.id }?.attachments.isEmpty == true)
            try await chat.flush()
            let saved = try await store.chatState()
            #expect(saved.sessions.first { $0.id == session.id }?.attachments.map(\.reference) == [published.record.reference])
            #expect(try Data(contentsOf: file) == bytes)
            try await close(store, root: root)
        } catch { try? await close(store, root: root); throw error }
    }

    @Test func replayRequiresRecordedSeedAndSafeSessionButNotCurrentDraftSettings() {
        var session = ChatSession()
        var node = WorkflowNode(operationID: "d.model.qwen35-9b", title: "Qwen")
        node.parameters["seed"] = .text("18446744073709551614")
        let attempt = ChatAttempt(sessionID: session.id, userMessageID: UUID(), assistantMessageID: UUID(),
            node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "old", status: .completed)
        // An absent current configuration must not replace or invalidate a recorded request.
        session.configuration = nil
        #expect(ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: true,
            hasPendingSave: false, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: true, hasSaveIssue: false))
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: true))
        #expect(!ChatRunAdmission.allowsReplay(ChatSession(), attempt: attempt, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
        node.parameters.removeValue(forKey: "seed")
        let oldUnseeded = ChatAttempt(sessionID: session.id, userMessageID: UUID(), assistantMessageID: UUID(),
            node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "old", status: .completed)
        #expect(!ChatRunAdmission.allowsReplay(session, attempt: oldUnseeded, isRunning: false,
            hasPendingSave: false, hasSaveIssue: false))
    }

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

    fileprivate func node() throws -> WorkflowNode {
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["outputMode"] = .text("response")
        node.parameters["task"] = .text("")
        node.parameters["messagesJSON"] = .text("[]")
        return node
    }

    fileprivate func attempt(sessionID: UUID, user: ChatMessage, assistant: ChatMessage,
                         status: ChatAttempt.Status, raw: String, node: WorkflowNode) -> ChatAttempt {
        var value = ChatAttempt(id: assistant.attemptID!, sessionID: sessionID, userMessageID: user.id,
            assistantMessageID: assistant.id, node: node,
            messagesJSON: "[]", inputs: [:], systemPrompt: "", status: status)
        value.rawText = raw
        return value
    }

    #if DEBUG
    @Test func categoryPickerFramedPreviewDoesNotInvalidateWorkbench() async throws {
        let root = fixtureRoot.appendingPathComponent("category-drag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: ChatPresentationNoInference(), backendID: "presentation.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: ChatPresentationMemorySettings())
        await project.createProject(at: root.appendingPathComponent("Drag.dproject"))
        let fixtureStore = try #require(project.currentStore)
        var navigation = QuickCreationState(); navigation.navigation = QuickNavigationState(selected: .text)
        try await fixtureStore.saveQuickCreationState(navigation, expectedRevision: 0)
        await project.enableProjectQuick(); await project.openWorkflow()
        do {
        let quick = try #require(project.projectQuick)
        let chat = try #require(project.chat)
        let model = WorkbenchModel(projectSession: project)
        let library = ModelLibraryModel(library: try await ModelLibrary(stateDirectory: root.appendingPathComponent("models")))
        let host = NSHostingView(rootView: DualWorkbenchView(model: model, quickModel: model,
            quick: quick, library: library, nodeTags: ModelNodeTagStore(), metadata: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            WorkbenchCategoryUpdateProbe.workbenchBody = nil
            WorkbenchCategoryUpdateProbe.retainedUpdate = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let receiver = try #require(descendants(host).compactMap { $0 as? WorkbenchCategoryDragView }.first)
        var rootUpdates = 0, retainedUpdates = 0
        WorkbenchCategoryUpdateProbe.workbenchBody = { rootUpdates += 1 }
        WorkbenchCategoryUpdateProbe.retainedUpdate = { retainedUpdates += 1 }
        let before = chat.state
        let selection = quick.category
        // Deliberate hosting measurement of the real receiver callback path.
        // This does not claim native mouse routing or desktop frame rate.
        receiver.onPreview(0)
        var presentations: [CGFloat] = []
        for tick in 1...36 {
            let position = tick <= 24 ? CGFloat(tick) / 8 : 3 - CGFloat(tick - 24) / 6
            receiver.onPreview(position)
            try await Task.sleep(for: .milliseconds(16))
            presentations.append(receiver.presentationSelection)
        }
        #expect(Set(presentations.map { Int($0 * 100) }).count >= 20)
        #expect(rootUpdates == 0 && retainedUpdates == 0)
        #expect(quick.category == selection && chat.state == before)
        print("CATEGORY_PREVIEW injections=36 root=\(rootUpdates) retained=\(retainedUpdates) intermediate=\(Set(presentations.map { Int($0 * 100) }).count)")
        receiver.onPreview(nil); receiver.onCommit(1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(quick.category == QuickCategory.allCases[1])
        #expect(rootUpdates > 0)
        #expect(chat.state == before)
        } catch { await project.closeProject(); throw error }
        await project.closeProject()
    }

    #endif

    fileprivate func fixture(_ state: ChatState,
                         engine: any InferenceEngine = ChatPresentationNoInference(),
                         withWorkflowOwner: Bool = false,
                         prepare: ((ProjectStore) async throws -> ChatState)? = nil) async throws
        -> (ChatController, WorkbenchModel, ProjectStore, URL) {
        let root = fixtureRoot.appendingPathComponent("chat-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "presentation.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: ChatPresentationMemorySettings())
        let store: ProjectStore
        if withWorkflowOwner {
            await project.createProject(at: root.appendingPathComponent("Fixture.dproject"))
            store = try #require(project.currentStore)
            #expect(project.chat == nil, "The fixture must have only one chat writer")
        } else {
            store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"), name: "Chat fixture")
        }
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
        if withWorkflowOwner {
            await project.openWorkflow()
            #expect(project.workflow != nil)
            #expect(project.chat == nil)
        }
        return (chat, WorkbenchModel(projectSession: project), store, root)
    }

    fileprivate func close(_ store: ProjectStore, root: URL) async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }

    @Test func continuousStreamKeepsComposerStopReachableUntilDrain() async throws {
        var session = ChatSession(title: "可控连续流")
        session.configuration = try node(); session.draft = "保持原输入 👩🏽‍🎨"
        var closed = ChatSession(title: "Archived reference"); closed.archived = true
        var state = ChatState(); state.sessions = [session, closed]; state.selectedSessionID = session.id
        let engine = ChatPresentationGatedStreamEngine()
        let (chat, model, store, root) = try await fixture(state, engine: engine)
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: ChatWorkbenchView(chat: chat, model: model,
            onChooseModel: {}, onSavedAsset: { _ in }, onAssetsChanged: {})
            .observingLayout { rectangles[$0] = $1 })
        host.frame = .init(x: 0, y: 0, width: 900, height: 640)
        host.layoutSubtreeIfNeeded()
        try await chat.send(sessionID: session.id)
        for _ in 0..<100 {
            if await engine.submissions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.submissions == 1)
        // Host exists before admission and stays mounted across multiple publications.
        for i in 0..<12 {
            await engine.emit("第\(i)段 é 👩🏽‍🎨\n")
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        #expect(chat.selectedSession?.attempts.first?.rawText.contains("第11段") == true)
        let composer = rectangles["composer"]
        let stop = rectangles["composer-stop"]
        #expect(stop != nil, "Stop must be a stable primary action beside the input, not transcript chrome")
        if let stop, let composer { #expect(composer.contains(stop)) }
        let withInspector = renderFixture(chat, model: model, width: 1_057, inspector: true)
        let pane = try #require(withInspector["inspector-pane"])
        let visibleStop = try #require(withInspector["composer-stop"])
        #expect(!visibleStop.intersects(pane))
        #expect(horizontallyInside(visibleStop, width: 1_057))
        try chat.selectSession(closed.id)
        rectangles.removeAll()
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let closedComposer = try #require(rectangles["composer-readonly"])
        #expect(closedComposer.contains(try #require(rectangles["composer-stop"])),
                "Browsing a closed conversation must retain global cancellation")
        try chat.selectSession(session.id)
        let cancelling = Task { await chat.cancel() }
        for _ in 0..<100 {
            if await engine.cancellationSeen { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.cancellationSeen)
        #expect(chat.isRunning, "Cancellation must remain busy until the execution drains")
        var repeatedCancelReturned = false
        let secondCancellation = Task { await chat.cancel(); repeatedCancelReturned = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!repeatedCancelReturned, "Repeated cancellation must also wait for drain")
        #expect(chat.canStopGeneration && chat.isCancelling)
        await engine.drain(); await cancelling.value; await secondCancellation.value
        #expect(!chat.isRunning && !chat.isCancelling && !chat.canStopGeneration)
        #expect(chat.selectedSession?.attempts.first?.status == .partial)
        #expect(chat.selectedSession?.attempts.first?.rawText.contains("第11段") == true)
        try await chat.flush(); try await close(store, root: root)
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

    @Test func mediumWindowInspectorDoesNotCoverPrimaryActions() async throws {
        var session = try answeredSession(raw: "Keep the original answer", status: .completed)
        session.draft = "Unsent 中文 👩🏽‍🎨"
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        let layout = renderFixture(chat, model: model, width: 1_057, inspector: true)
        let inspector = try #require(layout["inspector-pane"])
        for key in ["composer-send", "change-model", "paths"] {
            let control = try #require(layout[key])
            #expect(horizontallyInside(control, width: 1_057))
            #expect(!control.intersects(inspector), "\(key) must remain outside the inspector")
        }
        #expect(chat.selectedSession?.draft == session.draft)
        try await close(store, root: root)
    }

    fileprivate func answeredSession(raw: String, status: ChatAttempt.Status) throws -> ChatSession {
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

    @Test func markdownLinksRequireConfirmationAndCannotLoadImages() async {
        #expect(!ChatMarkdownPresentation.config.imageConfig.enabled)
        var proposed: [URL] = []
        let action = OpenURLAction { url in
            ChatMarkdownPresentation.requestURL(url) { proposed.append($0) }
        }
        for address in ["file:///tmp/private.txt", "javascript:alert(1)", "data:text/plain,secret",
                        "d://execute", "https://user:secret@example.invalid/", "/relative"] {
            let accepted = await withCheckedContinuation { continuation in
                action(URL(string: address)!) { continuation.resume(returning: $0) }
            }
            #expect(!accepted)
        }
        #expect(proposed.isEmpty)
        let safe = URL(string: "https://example.invalid/model?input=hello#section")!
        let handled = await withCheckedContinuation { continuation in
            action(safe) { continuation.resume(returning: $0) }
        }
        #expect(handled)
        #expect(proposed == [safe]) // Handled by confirmation; no browser is called here.
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
        // Even the original cannot disambiguate a legacy payload by itself.
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: project))
    }

    @Test func sidePanesCollapseBeforeConversationIsClipped() {
        // The new floating panels reserve a 16-point gap, not the former divider.
        #expect(!ChatPresentationLayout.showsSidebar(width: 707, requested: true))
        #expect(ChatPresentationLayout.showsSidebar(width: 708, requested: true))
        #expect(!ChatPresentationLayout.showsInspector(width: 1011, requested: true, sidebar: true))
        #expect(ChatPresentationLayout.showsInspector(width: 1012, requested: true, sidebar: true))
        #expect(!ChatPresentationLayout.showsInspector(width: 735, requested: true, sidebar: false))
        #expect(ChatPresentationLayout.showsInspector(width: 736, requested: true, sidebar: false))
        #expect(ChatPresentationLayout.dismissesNarrowPanel(.inspector, width: 1_300,
            sidebarRequested: true, inspectorRequested: true))
        #expect(!ChatPresentationLayout.dismissesNarrowPanel(.inspector, width: 960,
            sidebarRequested: true, inspectorRequested: true))
        #expect(ChatPresentationLayout.messageWidth == 760)
        #expect(ChatPresentationLayout.minimumBodyWidth == 432)
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

    @Test func delayedBottomRestoreUsesCurrentSiblingWithoutChangingHistory() throws {
        let question = ChatMessage(parentID: nil, role: .user, text: "Question")
        let first = ChatMessage(parentID: question.id, role: .assistant, text: "First")
        let second = ChatMessage(parentID: question.id, role: .assistant, text: "Second")
        var captured = ChatSession(title: "Restore branch")
        captured.messages = [question, first, second]; captured.selectedLeafID = first.id
        captured.draft = "保留 👩🏽‍🎨"
        let restore = ChatScrollRestoration(sessionID: captured.id, followsBottom: true, anchor: nil)
        var state = ChatState(); state.sessions = [captured]; state.selectedSessionID = captured.id
        // This is the state change across the restoration task's yield, not a
        // fabricated scroll gesture or a claim of native window acceptance.
        state.sessions[0].selectedLeafID = second.id
        let beforeResolve = state
        let current = try #require(restore.currentSession(in: state, pending: restore))
        let path = try current.path(to: current.selectedLeafID)
        #expect(captured.selectedLeafID == first.id)
        #expect(current.selectedLeafID == second.id && path.last?.id == second.id)
        #expect(!path.contains { $0.id == first.id })
        #expect(current.messages == captured.messages && current.draft == captured.draft)
        #expect(state == beforeResolve)
        #expect(restore.currentSession(in: state, pending: nil) == nil)
        state.selectedSessionID = UUID()
        #expect(restore.currentSession(in: state, pending: restore) == nil)
    }

    @Test func realWorkbenchResizePreservesInspectorComposition() async throws {
        let session = try answeredSession(raw: "正文", status: .completed)
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        let (chat, model, store, root) = try await fixture(state)
        var rectangles: [String: CGRect] = [:]
        let view = ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}, initialInspectorVisible: true,
            initialSettingsVisible: true)
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        host.frame = .init(x: 0, y: 0, width: 1300, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first {
            $0.accessibilityIdentifier() == "chat-system-\(session.id.uuidString)"
        })
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("pinyin", selectedRange: .init(location: 6, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        for width: CGFloat in [1290, 1273, 1057, 1000, 993, 1300] {
            window.setContentSize(.init(width: width, height: 700))
            settle()
            #expect(descendants(host).contains { $0 === editor })
            #expect(!editor.isHiddenOrHasHiddenAncestor)
            #expect(editor.hasMarkedText() && window.firstResponder === editor)
            if width - 32 >= 1012 {
                let pane = try #require(rectangles["inspector-pane"])
                for key in ["composer-send", "change-model", "paths"] {
                    let control = try #require(rectangles[key])
                    #expect(!control.intersects(pane), "\(key) covered at \(width)")
                }
            }
        }
        try await close(store, root: root)
    }

    @Test func offscreenNativeWindowResizeFocusControl() {
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 1300, height: 700))
        editor.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("pinyin", selectedRange: .init(location: 6, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        for width: CGFloat in [1273, 1000, 1300] {
            window.setContentSize(.init(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(editor.hasMarkedText() && window.firstResponder === editor)
        }
    }

    @Test func paneResizeKeepsNativeEditorAndExplicitHidingReleasesInput() throws {
        func pane(_ visible: Bool) -> some View {
            RetainedContentHost(content: TextSourcesQuestionEditor(value: "", editEpoch: 0,
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

    @Test func readingSnapshotOutlivesViewStateButNotOwnerOrPath() throws {
        let owner = NSObject(), otherOwner = NSObject()
        let state = ChatReadingStateStore()
        var session = try answeredSession(raw: "Stable answer", status: .completed)
        let message = try #require(session.messages.last)
        var point = ChatReadingPoint(messageID: message.id, offset: 503, width: 600, height: 3600)
        point.leafID = session.selectedLeafID; point.outputBytes = session.attempts[0].rawText.utf8.count
        point.revisionID = session.selectedAnswer(messageID: message.id)?.revisionID
        state.bind(owner)
        state[session.id] = .init(followsBottom: false, hasNewContent: false,
            anchor: message.id, readingPoint: point, leafID: session.selectedLeafID)
        // Recreated presentation resolves the longer-lived snapshot, not a new empty dictionary.
        #expect(state.state(for: session, owner: owner)?.readingPoint?.offset == 503)
        #expect(state.state(for: ChatSession(), owner: owner) == nil)
        var branch = session; branch.selectedLeafID = session.messages.first?.id
        #expect(state.state(for: branch, owner: owner) == nil)
        session.attempts[0].rawText += " new output"
        #expect(state.state(for: session, owner: owner)?.readingPoint == nil)
        #expect(state.state(for: session, owner: owner)?.followsBottom == false)
        // Same persisted IDs in a different controller/Store must not share UI state.
        #expect(state.state(for: session, owner: otherOwner) == nil)
        #expect(state[session.id] == nil)
        state[session.id] = .init(followsBottom: true, hasNewContent: false,
            anchor: message.id, readingPoint: nil, leafID: session.selectedLeafID)
        #expect(state.state(for: session, owner: otherOwner)?.followsBottom == true)
        state.reset()
        #expect(state[session.id] == nil)
        weak var released: NSObject?
        do {
            let temporary = NSObject(); released = temporary; state.bind(temporary)
            state[session.id] = .init(followsBottom: false, hasNewContent: false,
                anchor: nil, readingPoint: nil, leafID: session.selectedLeafID)
        }
        #expect(released == nil && state[session.id] == nil)
    }

    @Test func readingPointRejectsChangedPathRevisionAndOutput() throws {
        var session = try answeredSession(raw: "Original saved answer", status: .completed)
        let message = try #require(session.messages.last)
        var point = ChatReadingPoint(messageID: message.id, offset: 500, width: 600, height: 3600)
        point.leafID = session.selectedLeafID
        point.revisionID = session.selectedAnswer(messageID: message.id)?.revisionID
        point.outputBytes = session.attempts[0].rawText.utf8.count
        #expect(point.matches(session))
        var otherPoint = point; otherPoint.revisionID = UUID()
        #expect(!otherPoint.matches(session))
        otherPoint = point; otherPoint.leafID = UUID()
        #expect(!otherPoint.matches(session))
        session.attempts[0].rawText += " More output"
        #expect(!point.matches(session))
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

// XCTest owns the AppKit event loop; Swift Testing may exit during native tracking.
@MainActor final class ChatDynamicBottomHostingTests: XCTestCase {
    func testReadingMarkerPreservesTwoInternalPositions() throws {
        // Component geometry only. Real session navigation is an ordinary-App gate.
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let document = FlippedDocument(frame: .init(x: 0, y: 0, width: 600, height: 4000))
        let marker = NSView(frame: .init(x: 0, y: 80, width: 600, height: 3600))
        document.addSubview(marker)
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        let owner = ChatReadingMarkers(), sessionID = UUID(), messageID = UUID()
        owner.register(marker, messageID: messageID, sessionID: sessionID)
        for target in [CGFloat(500), 1200] {
            scroll.contentView.scroll(to: .init(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            let point = try XCTUnwrap(owner.capture(sessionID: sessionID, path: [messageID]))
            XCTAssertGreaterThan(point.offset, 100)
            scroll.contentView.scroll(to: .init(x: 0, y: 80))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertTrue(owner.restore(point, sessionID: sessionID))
            let restored = try XCTUnwrap(owner.capture(sessionID: sessionID, path: [messageID]))
            XCTAssertEqual(restored.offset, point.offset, accuracy: 0.5)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, target, accuracy: 0.5)
            XCTAssertFalse(owner.restore(point, sessionID: UUID()), "Never restore another session's marker")
            marker.frame.size.width = 500
            scroll.contentView.scroll(to: .init(x: 0, y: 80))
            XCTAssertFalse(owner.restore(point, sessionID: sessionID), "A temporary layout mismatch must not consume restoration")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 80, accuracy: 0.5)
            marker.frame.size.width = 600
            marker.frame.size.height = 3000
            XCTAssertFalse(owner.restore(point, sessionID: sessionID))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 80, accuracy: 0.5)
            marker.frame.size.height = 3600
            XCTAssertTrue(owner.restore(point, sessionID: sessionID))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, target, accuracy: 0.5)
            let unreachable = ChatReadingPoint(messageID: messageID, offset: 9000, width: point.width, height: point.height)
            XCTAssertFalse(owner.restore(unreachable, sessionID: sessionID), "A clamped scroll is not restoration")
        }
        scroll.contentView.scroll(to: .init(x: 0, y: 1200))
        XCTAssertFalse(try XCTUnwrap(owner.alignTop(messageID: messageID, sessionID: sessionID)).isAligned)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 80, accuracy: 0.5)
        let aligned = try XCTUnwrap(owner.alignTop(messageID: messageID, sessionID: sessionID))
        XCTAssertTrue(aligned.isAligned)
        XCTAssertEqual(aligned.messageSize, marker.frame.size)
        XCTAssertEqual(aligned.viewportSize, scroll.contentView.bounds.size)
        // A subsequent layout shift must be observed, not assumed already aligned.
        marker.frame.origin.y += 100
        XCTAssertFalse(try XCTUnwrap(owner.alignTop(messageID: messageID, sessionID: sessionID)).isAligned)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 180, accuracy: 0.5)
        XCTAssertTrue(try XCTUnwrap(owner.alignTop(messageID: messageID, sessionID: sessionID)).isAligned)
        XCTAssertNil(owner.alignTop(messageID: UUID(), sessionID: sessionID))
        marker.frame.size.height = 0
        let unavailable = ChatReadingPoint(messageID: messageID, offset: 500, width: 600, height: 3600)
        XCTAssertFalse(owner.restore(unavailable, sessionID: sessionID), "Unlaid-out markers must not consume restoration")
    }

    func testCompletedShortStreamCanJumpPastAdoptedListAndEmptyCancellation() async throws {
        try await exerciseCompletedStream(replay: false)
    }

    func testReplayedSiblingFollowsCompletedStreamWithoutChangingHistory() async throws {
        try await exerciseCompletedStream(replay: true)
    }

    func testReplayedSiblingFollowsNativeListAtCompactHeight() async throws {
        try await exerciseCompletedStream(replay: true, nativeHistory: true)
    }

    func testNativeListAtCompactHeightWithHiddenWorkflowAndParentDependency() async throws {
        try await exerciseCompletedStream(replay: true, nativeHistory: true, hiddenWorkflow: true)
    }

    func testNativeListWithHiddenSharedLibraryProjection() async throws {
        try await exerciseCompletedStream(replay: true, nativeHistory: true,
            hiddenWorkflow: true, sharedLibrary: true)
    }

    private func exerciseCompletedStream(replay: Bool, nativeHistory: Bool = false,
                                         hiddenWorkflow: Bool = false, sharedLibrary: Bool = false) async throws {
        let fixture = ChatPresentationTests()
        var modelNode = try fixture.node()
        modelNode.parameters["seed"] = .text("4202")
        var session = ChatSession(title: "Dynamic bottom regression")
        session.configuration = modelNode
        let first = ChatMessage(parentID: nil, role: .user, text: "List reading corner tips")
        let partial = ChatMessage(parentID: first.id, role: .assistant, text: "", attemptID: UUID())
        let second = ChatMessage(parentID: partial.id, role: .user, text: "Give five tips")
        let cancelled = ChatMessage(parentID: second.id, role: .assistant, text: "", attemptID: UUID())
        // Fixed generated list from bottom-reproduced.json (2026-10-05): the
        // final item is short, unlike the earlier equal-length synthetic fixture.
        let nativeList = "1. Maximize vertical space by installing adjustable wall shelves to store books without consuming valuable floor area.\n2. Utilize an ottoman or storage stool to hide spare reading materials while providing a comfortable, plush seat.\n3. Hang a small book ladder on the wall or near a window to display favorite titles at eye level.\n4. Use a floor-to-ceiling bookcase with sliding doors to keep the collection organized and out of sight when not in use.\n5. Repurpose a sturdy box or crate as a movable side table for holding a current read or a cup of tea.\n6. Choose a multi-functional piece of furniture, such as a daybed, that can serve as both a reading chair and guest seating.\n7. Install a pocket organizer system on the inside of a closet door to hold lighter novels or magazines.\n8. Create a designated \"reading nook\" in an alcove or under a staircase using a bench and a single overhead shelf.\n9. Hang a fabric hanging organizer from a rod or hook to display paperbacks and readers in a tiered fashion.\n10. Use under-bed storage bins to stash books you plan to read later, keeping the immediate area clutter-free.\n11. Add a"
        let list = nativeHistory ? nativeList : (1...11).map { "\($0). Use adjustable shelves and comfortable lighting for a small reading corner with books and seating." }.joined(separator: "\n")
        var earlier = fixture.attempt(sessionID: session.id, user: first, assistant: partial,
            status: .partial, raw: list, node: modelNode)
        earlier.response = .init(rawText: list, finalText: list, finishReason: .length)
        var stopped = fixture.attempt(sessionID: session.id, user: second, assistant: cancelled,
            status: .cancelled, raw: "", node: modelNode)
        stopped.issue = "已停止；已接收的文字已保留。"
        session.messages = [first, partial, second, cancelled]; session.attempts = [earlier, stopped]
        let adopted = ChatTextRevision(messageID: partial.id, text: list)
        session.contextChoices = .init()
        session.contextChoices?.revisions = [adopted]; session.contextChoices?.adoptedRevisionIDs = [adopted.id]
        session.selectedLeafID = cancelled.id; session.draft = "Reply only OK."
        var replaySource: ChatAttempt?
        if replay {
            let prompt = ChatMessage(parentID: cancelled.id, role: .user, text: "Reply only OK.")
            let oldAnswer = ChatMessage(parentID: prompt.id, role: .assistant, text: "", attemptID: UUID())
            let messages = #"[{"role":"user","parts":[{"type":"text","text":"Reply only OK."}]}]"#
            var replayNode = modelNode
            replayNode.parameters["messagesJSON"] = .text(messages)
            var old = ChatAttempt(id: oldAnswer.attemptID!, sessionID: session.id,
                userMessageID: prompt.id, assistantMessageID: oldAnswer.id, node: replayNode,
                messagesJSON: messages,
                inputs: [:], systemPrompt: "", status: .completed)
            old.rawText = "OK"
            old.response = .init(rawText: "OK", finalText: "OK", finishReason: .stop)
            session.messages += [prompt, oldAnswer]; session.attempts.append(old)
            session.selectedLeafID = oldAnswer.id
            session.draft = "保留会话草稿 👩🏽‍🎨"
            replaySource = old
        }
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        if nativeHistory {
            state.sessions += [ChatSession(title: "Reading corner lighting"),
                               ChatSession(title: "集中验收"), ChatSession(title: "新对话")]
        }
        let engine = ChatPresentationGatedStreamEngine()
        let (chat, model, store, root) = try await fixture.fixture(state, engine: engine,
            withWorkflowOwner: nativeHistory)
        func closeFixture() async throws {
            if nativeHistory {
                let closed = await model.projectSession.requestClose()
                XCTAssertTrue(closed)
                if closed { try FileManager.default.removeItem(at: root) }
            } else { try await fixture.close(store, root: root) }
        }
        var frames: [String: CGRect] = [:]
        let content = ChatWorkbenchView(chat: chat, model: model, onChooseModel: {},
            onSavedAsset: { _ in }, onAssetsChanged: {}, initialInspectorVisible: true,
            initialSettingsVisible: true, initiallyFollowsBottom: replay, initiallyHasNewContent: !replay)
            .observingLayout { frames[$0] = $1 }
        let host: NSView
        if nativeHistory {
            host = NSHostingView(rootView: ChatBottomCompositionFixture(chat: chat, model: model,
                content: AnyView(content), includesHiddenWorkflow: hiddenWorkflow,
                libraryStore: sharedLibrary ? try SharedLibraryStore() : nil))
        } else { host = NSHostingView(rootView: content) }
        host.frame = .init(x: 0, y: 0, width: 1057, height: nativeHistory ? 520 : 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        do {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if let replaySource {
            try await chat.reproduce(replaySource.id, sessionID: session.id)
        } else {
            try await chat.send(sessionID: session.id)
        }
        for _ in 0..<100 {
            if await engine.submissions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let startedCount = await engine.submissions
        XCTAssertEqual(startedCount, 1)
        await engine.emit("O")
        for _ in 0..<100 {
            if chat.selectedSession?.attempts.last?.rawText == "O" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(chat.selectedSession?.attempts.last?.rawText == "O" && chat.isRunning ? true : nil,
            "Controlled stream did not expose its in-flight state")
        host.layoutSubtreeIfNeeded()
        print("D_DYNAMIC_BOTTOM", "in-flight O observed, host layout updated")
        await engine.emit("K")
        await engine.drain(response: .init(rawText: "OK", finalText: "OK", finishReason: .stop))
        await chat.waitForCompletion()
        XCTAssertTrue(chat.selectedSession?.attempts.last?.status == .completed)
        XCTAssertTrue(chat.selectedSession?.attempts.last?.rawText == "OK")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let viewportBefore = try XCTUnwrap(frames["transcript"])
        let scrollCandidates = Self.descendants(host).compactMap { $0 as? NSScrollView }.filter {
            let frame = host.convert($0.bounds, from: $0)
            return abs(frame.minX - viewportBefore.minX) < 4 && abs(frame.minY - viewportBefore.minY) < 4
                && abs(frame.width - viewportBefore.width) < 4 && abs(frame.height - viewportBefore.height) < 4
                && !$0.isHiddenOrHasHiddenAncestor
        }
        let scroll = try XCTUnwrap(scrollCandidates.count == 1 ? scrollCandidates.first : nil,
            "Transcript scroll view must be unique, found \(scrollCandidates.count)")
        if replay {
            func distanceToBottom() -> CGFloat {
                (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.minY
                    - scroll.contentView.bounds.height
            }
            for _ in 0..<100 {
                if distanceToBottom() <= 28 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard distanceToBottom() <= 28 else {
                throw WorkflowIssue("Replay fixture did not follow its completed sibling to the bottom: \(distanceToBottom())")
            }
            print("D_DYNAMIC_BOTTOM", "replay followed completed sibling", distanceToBottom())
            XCTAssertEqual(chat.selectedSession?.messages.count, 7)
            XCTAssertEqual(chat.selectedSession?.attempts.last?.replayedAttemptID, replaySource?.id)
            XCTAssertEqual(chat.selectedSession?.draft, session.draft)
            XCTAssertEqual(chat.selectedSession?.attempts.dropLast(), session.attempts[...])
            // The former direct scrollWheel helper did not move this host.
            // Real wheel/leave-bottom/session/search behavior is covered by the
            // ordinary-App procedure referenced in CHAT_FEATURE_LEDGER. Here
            // verify automatic following of a real controller replay; the
            // non-following case below independently exercises explicit Bottom.
        }
        let beforeOffset = scroll.contentView.bounds.minY
        let beforeDistance = try XCTUnwrap(scroll.documentView).frame.height
            - beforeOffset - scroll.contentView.bounds.height
        if !replay {
            XCTAssertGreaterThan(beforeDistance, 28, "Fixture must actually start away from Bottom")
            let rect = try XCTUnwrap(frames["bottom-button"])
            let target = NSAccessibilityElement()
            target.setAccessibilityIdentifier("chat-bottom-button")
            target.setAccessibilityFrame(window.convertToScreen(host.convert(rect, to: nil)))
            print("D_DYNAMIC_BOTTOM", "before click", rect, "offset", beforeOffset, "distance", beforeDistance)
            _ = try XCTUnwrap(HostingControlClick.send(to: target, in: host) ? true : nil,
                "Bottom event not delivered")
            print("D_DYNAMIC_BOTTOM", "click returned")
        }
        try await Task.sleep(for: .milliseconds(600))
        // Sample a stable final layout, not independently cached rectangles from
        // either side of an actor suspension. Never select the smallest distance.
        var previousSample: [CGRect] = []
        var stableSamples = 0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let id = try XCTUnwrap(chat.selectedSession?.messages.last?.id)
            let sample = [try XCTUnwrap(frames["message-" + id.uuidString]),
                          try XCTUnwrap(frames["transcript"]), scroll.contentView.bounds]
            stableSamples = sample == previousSample ? stableSamples + 1 : 0
            previousSample = sample
            if stableSamples >= 2 { break }
        }
        XCTAssertGreaterThanOrEqual(stableSamples, 2, "Final geometry must settle before checking the unchanged bottom requirement")
        let finalCount = await engine.submissions
        XCTAssertEqual(finalCount, 1)
        XCTAssertTrue(chat.selectedSession?.attempts.prefix(2) == [earlier, stopped][...])
        XCTAssertTrue(chat.selectedSession?.contextChoices?.adopted[partial.id] == list)
        let finalID = try XCTUnwrap(chat.selectedSession?.messages.last?.id)
        let finalRect = try XCTUnwrap(frames["message-" + finalID.uuidString])
        let viewport = try XCTUnwrap(frames["transcript"])
        XCTAssertTrue(finalRect.intersects(viewport), "Completed answer must be visible after following or Bottom")
        let afterOffset = scroll.contentView.bounds.minY
        let afterDistance = try XCTUnwrap(scroll.documentView).frame.height
            - afterOffset - scroll.contentView.bounds.height
        print("D_DYNAMIC_BOTTOM", "final offset", afterOffset, "distance", afterDistance,
              "last", finalRect, "viewport", viewport, "document", scroll.documentView!.frame,
              "clip", scroll.contentView.bounds, "documentRect", scroll.contentView.documentRect)
        if !replay { XCTAssertGreaterThan(afterOffset, beforeOffset) }
        // LazyVStack's native document height remains an estimate (the fixed
        // fixture reports 287.5 spare points while the actual last row is exactly
        // bottom-aligned). Assert the visible last row in the same coordinate
        // space instead of treating that estimate as laid-out content.
        XCTAssertLessThanOrEqual(abs(viewport.maxY - finalRect.maxY), 28,
            "The last answer's bottom must reach the transcript viewport")
        } catch {
            await engine.drain()
            await chat.waitForCompletion()
            try? await chat.flush()
            try? await closeFixture()
            throw error
        }
        try await chat.flush(); try await closeFixture()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

// This comparison changes one hosting boundary only. It is not a replacement
// App or a native acceptance gate: both sides use the same controlled stream.
@MainActor private struct ChatBottomCompositionFixture: View {
    let chat: ChatController
    let model: WorkbenchModel
    let content: AnyView
    let includesHiddenWorkflow: Bool
    let libraryStore: SharedLibraryStore?
    private let libraryState = SharedLibraryBrowserState()
    private var libraryEntries: [SharedLibraryBrowserEntry] {
        SharedLibraryProjection.entries(models: model.projectSession.explicitModelChoices,
            readiness: model.projectSession.explicitModelReadiness,
            tools: model.projectSession.workflow?.tools ?? [],
            projects: model.manifest.map { [$0] } ?? [], language: nil)
    }
    private let tags = ModelNodeTagStore()
    var body: some View {
        if includesHiddenWorkflow {
            ZStack {
                content
                RetainedContentHost(content: WorkflowHostView(model: model, nodeTags: tags, libraryContent: libraryStore.map { store in
                    { _, close in AnyView(SharedLibraryBrowser(entries: libraryEntries, store: store,
                        compact: true, state: libraryState,
                        onUse: { _ in XCTFail("Hidden library must not execute") },
                        onAdd: { _ in XCTFail("Hidden library must not add") },
                        onPreview: { _ in XCTFail("Hidden library must not preview") },
                        onPrepare: { _ in XCTFail("Hidden library must not prepare") },
                        onImport: { XCTFail("Hidden library must not import") }, onClose: close)) }
                }), visible: false, identifier: "workflow-retained-surface",
                    fallbackSize: CGSize(width: 760, height: 500))
                    .accessibilityHidden(true)
            }
            .onChange(of: chat.selectedSession?.configuration?.parameters["modelID"]?.string) { _, _ in }
        } else { content }
    }
}

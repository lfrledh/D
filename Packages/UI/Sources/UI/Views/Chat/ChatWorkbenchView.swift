import AppKit
import DInference
import DWorkbench
import SwiftUI

enum ChatAssetDropScope {
    static func accepts(projectID: UUID, instanceID: UUID?,
                        manifestProjectID: UUID, manifestInstanceID: UUID) -> Bool {
        // A legacy payload needs the shared library's uniqueness resolution, even
        // when this Store is the original: a restored instance may also be open.
        projectID == manifestProjectID && instanceID == manifestInstanceID
    }
}

/// Shared presentation gate for every control that can start model work.
/// ChatController still performs the final admission check.
enum ChatRunAdmission {
    static func allowsReplay(_ session: ChatSession, attempt: ChatAttempt, isRunning: Bool,
                             hasPendingSave: Bool, hasSaveIssue: Bool) -> Bool {
        guard let seed = attempt.node.parameters["seed"]?.string, UInt64(seed) != nil else { return false }
        return !session.archived && session.contextChoices?.deletedAt == nil && !isRunning && !hasPendingSave && !hasSaveIssue &&
            attempt.sessionID == session.id && attempt.status != .running && attempt.status != .saving
    }

    static func allows(_ session: ChatSession, isRunning: Bool, hasPendingSave: Bool,
                       hasSaveIssue: Bool, invalidFields: Set<String>) -> Bool {
        !session.archived && session.contextChoices?.deletedAt == nil && session.configuration != nil && !isRunning &&
        !hasPendingSave && !hasSaveIssue &&
        !invalidFields.contains(where: { $0.hasPrefix(session.id.uuidString + ":") })
    }

    static func allowsSend(_ session: ChatSession, isRunning: Bool, hasPendingSave: Bool,
                           hasSaveIssue: Bool, invalidFields: Set<String>) -> Bool {
        allows(session, isRunning: isRunning, hasPendingSave: hasPendingSave,
               hasSaveIssue: hasSaveIssue, invalidFields: invalidFields) &&
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ChatPresentationLayout {
    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 288
    static let messageWidth: CGFloat = 760
    // The transcript and composer each reserve 16 points on both sides.
    // Actions have their own compact rows; the body no longer needs room for
    // every attachment and submit button on a single line.
    static let minimumBodyWidth: CGFloat = 400 + 32
    static func showsSidebar(width: CGFloat, requested: Bool) -> Bool {
        requested && width >= minimumBodyWidth + sidebarWidth + 16
    }
    static func showsInspector(width: CGFloat, requested: Bool, sidebar: Bool) -> Bool {
        requested && width >= minimumBodyWidth + inspectorWidth + 16 + (sidebar ? sidebarWidth + 16 : 0)
    }
}

/// One outline is shared by the plate, border and whitespace hit region.
/// The native editor is never replaced when its content wraps onto another line.
struct ChatComposerShape: InsettableShape {
    var multiline: Bool
    private var insetAmount: CGFloat = 0
    init(multiline: Bool) { self.multiline = multiline }

    func path(in rect: CGRect) -> Path {
        if multiline {
            return RoundedRectangle(cornerRadius: 20, style: .continuous)
                .inset(by: insetAmount).path(in: rect)
        }
        return Capsule().inset(by: insetAmount).path(in: rect)
    }
    func inset(by amount: CGFloat) -> ChatComposerShape {
        var result = self; result.insetAmount += amount; return result
    }
}

private enum ChatInspectorTab: String, CaseIterable { case artifacts, sources }
private enum ChatPreparationTab: String, CaseIterable { case settings, assets, conversations, tools }

enum ChatNarrowPanel: String, Identifiable {
    case sessions, inspector
    var id: Self { self }
}

extension ChatPresentationLayout {
    static func dismissesNarrowPanel(_ panel: ChatNarrowPanel, width: CGFloat,
                                     sidebarRequested: Bool, inspectorRequested: Bool) -> Bool {
        let sidebar = showsSidebar(width: width, requested: sidebarRequested)
        switch panel {
        case .sessions: return sidebar
        case .inspector: return showsInspector(width: width, requested: inspectorRequested, sidebar: sidebar)
        }
    }
}

private enum ChatDetail: Identifiable {
    case edit(ChatEdit), preview(WorkflowAssetReference)
    case projectAttachments(UUID)
    case request(ChatAttempt)
    case message(ChatSession, ChatMessage, ChatAttempt?), raw(UUID, String), searchHit(ChatSearchHit)
    case comparison(UUID, UUID), presetImport([ChatPromptPreset], Data)
    case conversationImport(Data, String)
    case quote(UUID, ChatQuoteSource), artifact(ChatArtifactContent), fields([ChatAnswerField])
    case knowledgeDirectory(UUID, URL, ChatKnowledgeDirectoryInventory, Bool)
    var id: String {
        switch self {
        case .edit(let edit): "edit-\(edit.id)"
        case .request(let attempt): "request-\(attempt.id)"
        case .message(let session, let message, _): "message-detail-\(session.id)-\(message.id)"
        case .raw(let id, _): "raw-output-\(id)"
        case .searchHit(let hit): "search-\(hit.sessionID)-\(hit.messageID?.uuidString ?? "title")-\(hit.revisionID?.uuidString ?? "original")"
        case .projectAttachments(let owner): "project-attachments-\(owner)"
        case .preview(let reference): "preview-\(reference.assetID)"
        case .comparison(let session, let attempt): "compare-\(session)-\(attempt)"
        case .presetImport: "preset-import"
        case .conversationImport: "conversation-import"
        case .knowledgeDirectory(let owner, let url, _, _): "knowledge-directory-\(owner)-\(url.path)"
        case .artifact(let value): "artifact-\(value.id)-\(value.revision)"
        case .fields(let values): "fields-\(values.first?.answer.assetID.uuidString ?? "empty")"
        case .quote(let session, let source): "quote-\(session)-\(source.id)"
        }
    }
}

struct ChatSearchJump: Equatable {
    let sessionID: UUID
    let messageID: UUID
    let ticket = UUID()
}

enum ChatContextSessionList {
    static func visible(_ sessions: [ChatSession], archived: Bool, deleted: Bool,
                        favoritesOnly: Bool, tag: String) -> [ChatSession] {
        sessions.enumerated().filter { pair in
            let item = pair.element
            return item.archived == archived && (item.contextChoices?.deletedAt != nil) == deleted &&
                (tag.isEmpty || item.contextChoices?.tags.contains(tag) == true) &&
                (!favoritesOnly || item.contextChoices?.favoriteMessageIDs.isEmpty == false)
        }.sorted { lhs, rhs in
            let left = lhs.element.contextChoices?.pinned == true
            let right = rhs.element.contextChoices?.pinned == true
            return left == right ? lhs.offset > rhs.offset : left
        }.map { $0.element }
    }
}

/// These commands are used by the hosted controls and by the presentation fixture.
@MainActor enum ChatContextCommands {
    static func open(_ hit: ChatSearchHit, in chat: ChatController) throws -> ChatSearchJump? {
        guard let session = chat.state.sessions.first(where: { $0.id == hit.sessionID }),
              session.contextChoices?.deletedAt == nil else { throw WorkflowIssue("对话已删除或不存在。") }
        guard ChatHistorySearch.isCurrent(hit, in: session) else { throw WorkflowIssue("搜索命中的内容已变化，请重新搜索。", code: "chat.error.searchChanged") }
        try chat.selectSession(session.id)
        guard let messageID = hit.messageID else { return nil }
        // An ancestor is already visible; changing the leaf would discard the rest of this path.
        if !chat.selectedPath.contains(where: { $0.id == messageID }) {
            try chat.selectLeaf(messageID, sessionID: session.id)
        }
        return .init(sessionID: session.id, messageID: messageID)
    }

    static func adopt(_ text: String, messageID: UUID, sessionID: UUID,
                      in chat: ChatController, origin: ChatTextRevision.Origin? = nil) throws {
        guard chat.state.selectedSessionID == sessionID else {
            throw WorkflowIssue("请返回原对话后再采用此回答。")
        }
        guard let session = chat.selectedSession,
              let attemptID = session.messages.first(where: { $0.id == messageID && $0.role == .assistant })?.attemptID,
              canAdopt(session.attempts.first(where: { $0.id == attemptID }), in: chat) else {
            throw WorkflowIssue("回答仍在运行、待保存或等待工具完成，不能采用。")
        }
        _ = try chat.adoptAnswer(messageID, text: text, sessionID: sessionID, origin: origin)
    }

    static func choices(_ session: ChatSession, mutate: (inout ChatContextChoices) -> Void,
                        in chat: ChatController) throws {
        guard let current = chat.state.sessions.first(where: { $0.id == session.id }) else {
            throw WorkflowIssue("对话不存在。")
        }
        var value = current.contextChoices ?? .init()
        mutate(&value)
        try chat.updateContextChoices(value, sessionID: session.id)
    }

    static func canAdopt(_ attempt: ChatAttempt?, in chat: ChatController) -> Bool {
        guard let attempt, attempt.status != .running, attempt.status != .saving,
              !chat.isRunning, chat.pendingSaveAttemptID == nil, chat.saveIssue == nil,
              attempt.response?.toolCalls.isEmpty != false,
              attempt.response?.finishReason != .toolCalls,
              attempt.response?.finishReason != .incomplete else { return false }
        return !(attempt.response?.finalText ?? attempt.rawText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func selectVersion(_ revisionID: UUID?, messageID: UUID, sessionID: UUID,
                              in chat: ChatController) throws {
        guard chat.state.selectedSessionID == sessionID,
              let session = chat.selectedSession,
              let attemptID = session.messages.first(where: { $0.id == messageID && $0.role == .assistant })?.attemptID,
              canAdopt(session.attempts.first(where: { $0.id == attemptID }), in: chat) else {
            throw WorkflowIssue("请等待回答完成并返回原对话后再选择版本。")
        }
        try chat.selectAnswerRevision(revisionID, messageID: messageID, sessionID: sessionID)
    }
}

enum ChatContextRowStatus: String, Equatable {
    case currentQuestion, excluded, summarized, adopted, included

    static func forMessage(_ message: ChatMessage, in session: ChatSession, summaryUses: [ChatContextSummary] = []) -> Self {
        if message.role == .user && session.selectedLeafID == message.id &&
            session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .currentQuestion
        }
        if session.contextChoices?.excludedMessageIDs.contains(message.id) == true { return .excluded }
        if summaryUses.contains(where: { $0.source.coveredMessageIDs.contains(message.id) }) { return .summarized }
        if session.contextChoices?.adopted[message.id] != nil { return .adopted }
        return .included
    }

    var canExclude: Bool { self != .currentQuestion }
    var english: String {
        switch self {
        case .currentQuestion: "Current question · still sent"
        case .excluded: "Excluded"
        case .summarized: "Replaced by reviewed summary"
        case .adopted: "Adopted"
        case .included: "Included"
        }
    }
    var chinese: String {
        switch self {
        case .currentQuestion: "本次问题，仍会发送"
        case .excluded: "已排除"
        case .summarized: "由已审核摘要代替"
        case .adopted: "已采用人工版本"
        case .included: "纳入"
        }
    }
}

struct ChatSheetQueue<Detail: Identifiable> {
    var narrowPanel: ChatNarrowPanel?
    var detail: Detail?
    private(set) var pendingDetail: Detail?
    private(set) var narrowSheetVisible = false

    init() {}

    mutating func openNarrow(_ panel: ChatNarrowPanel) {
        narrowPanel = panel
        narrowSheetVisible = true
    }

    mutating func present(_ item: Detail) {
        if narrowSheetVisible {
            pendingDetail = item
            narrowPanel = nil
        } else {
            detail = item
        }
    }

    mutating func didDismissNarrowPanel() {
        guard narrowPanel == nil else { return }
        narrowSheetVisible = false
        if let pendingDetail {
            detail = pendingDetail
            self.pendingDetail = nil
        }
    }
}

struct ChatScrollPosition: Equatable {
    let offset: CGFloat
    let distanceToBottom: CGFloat

    static func followsBottom(previous: Self, current: Self, wasFollowing: Bool) -> Bool {
        guard abs(previous.offset - current.offset) > 1 else { return wasFollowing }
        return current.distanceToBottom <= 28
    }
}

struct ChatSessionScrollState {
    var followsBottom: Bool
    var hasNewContent: Bool
    var anchor: UUID?
    var readingPoint: ChatReadingPoint?
    var leafID: UUID?
}

/// Owned by the existing presentation facade, not the conditional chat view. No project I/O,
/// native view ownership or model history retention. Rebinding a controller drops old snapshots.
@MainActor final class ChatReadingStateStore {
    private weak var owner: AnyObject?
    private var snapshots: [UUID: ChatSessionScrollState] = [:]
    weak var markers: ChatReadingMarkers?

    func bind(_ owner: AnyObject) {
        guard self.owner !== owner else { return }
        reset(); self.owner = owner
    }
    func reset() { owner = nil; snapshots.removeAll(); markers = nil }
    func isOwned(by owner: AnyObject) -> Bool { self.owner === owner }
    func state(for session: ChatSession, owner: AnyObject) -> ChatSessionScrollState? {
        bind(owner)
        guard var saved = snapshots[session.id], saved.leafID == session.selectedLeafID,
              saved.anchor.map({ id in ((try? session.path(to: session.selectedLeafID)) ?? []).contains { $0.id == id } }) ?? true else { return nil }
        // A changed output invalidates exact internal geometry, not the user's intent to
        // stay away from Bottom. Restore only the still-current message anchor in that case.
        if saved.readingPoint?.matches(session) == false { saved.readingPoint = nil }
        return saved
    }
    subscript(sessionID: UUID) -> ChatSessionScrollState? {
        get { owner == nil ? nil : snapshots[sessionID] }
        set { if owner != nil { snapshots[sessionID] = newValue } }
    }
    func capture(_ chat: ChatController) {
        guard owner === chat, let session = chat.selectedSession,
              var saved = state(for: session, owner: chat), !saved.followsBottom,
              var point = markers?.capture(sessionID: session.id, path: chat.selectedPath.map(\.id)) else { return }
        point.leafID = session.selectedLeafID
        point.revisionID = session.selectedAnswer(messageID: point.messageID)?.revisionID
        point.outputBytes = session.messages.first { $0.id == point.messageID }?.attemptID
            .flatMap { id in session.attempts.first { $0.id == id } }?.rawText.utf8.count ?? 0
        saved.anchor = point.messageID; saved.readingPoint = point
        snapshots[session.id] = saved
    }
}

/// Ephemeral view geometry, never project data or a continuously bound scroll target.
struct ChatReadingPoint {
    let messageID: UUID
    let offset: CGFloat
    let width: CGFloat
    let height: CGFloat
    var leafID: UUID?
    var revisionID: UUID?
    var outputBytes: Int = 0

    func matches(_ session: ChatSession) -> Bool {
        let message = session.messages.first { $0.id == messageID }
        let bytes = message?.attemptID.flatMap { id in session.attempts.first { $0.id == id } }?.rawText.utf8.count ?? 0
        return session.selectedLeafID == leafID && message != nil
            && session.selectedAnswer(messageID: messageID)?.revisionID == revisionID && bytes == outputBytes
    }
}

@MainActor final class ChatReadingMarkers {
    private struct Key: Hashable { let sessionID: UUID; let messageID: UUID }
    private struct Entry { weak var view: NSView? }
    private var entries: [Key: Entry] = [:]

    func register(_ view: NSView, messageID: UUID, sessionID: UUID) {
        entries[Key(sessionID: sessionID, messageID: messageID)] = Entry(view: view)
    }

    func capture(sessionID: UUID, path: [UUID]) -> ChatReadingPoint? {
        entries = entries.filter { $0.value.view != nil }
        for id in path {
            guard let entry = entries[Key(sessionID: sessionID, messageID: id)],
                  let view = entry.view, view.window != nil,
                  let scroll = view.enclosingScrollView else { continue }
            let rect = view.convert(view.bounds, to: nil)
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            // Window coordinates have an upward y axis. Keep the first visible
            // message and its internal reading point, including a small top gap.
            guard rect.intersects(viewport), rect.height > 0 else { continue }
            return .init(messageID: id, offset: rect.maxY - viewport.maxY,
                         width: rect.width, height: rect.height)
        }
        return nil
    }

    struct TopAlignment: Equatable {
        let offset: CGFloat
        let messageSize: CGSize
        let viewportSize: CGSize
        var isAligned: Bool { abs(offset) <= 0.5 }
    }

    /// Reports geometry before correction so a later layout can confirm that the
    /// explicit search stayed aligned, rather than treating a scroll call as success.
    func alignTop(messageID: UUID, sessionID: UUID) -> TopAlignment? {
        guard let view = entries[Key(sessionID: sessionID, messageID: messageID)]?.view,
              view.window != nil, let scroll = view.enclosingScrollView else { return nil }
        scroll.layoutSubtreeIfNeeded()
        let rect = view.convert(view.bounds, to: nil)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        guard !rect.isEmpty, !viewport.isEmpty, rect.minY.isFinite, rect.maxY.isFinite,
              viewport.minY.isFinite, viewport.maxY.isFinite else { return nil }
        let measured = TopAlignment(offset: rect.maxY - viewport.maxY,
            messageSize: rect.size, viewportSize: viewport.size)
        if !measured.isAligned { _ = align(offset: 0, rect: rect, in: scroll) }
        return measured
    }

    /// Called only after Reader has made the saved message available. It neither
    /// changes focus nor responds to a link's focus/geometry notifications.
    func restore(_ point: ChatReadingPoint, sessionID: UUID) -> Bool {
        guard let entry = entries[Key(sessionID: sessionID, messageID: point.messageID)],
              let view = entry.view, view.window != nil,
              let scroll = view.enclosingScrollView else { return false }
        scroll.layoutSubtreeIfNeeded()
        let rect = view.convert(view.bounds, to: nil)
        let clip = scroll.contentView
        let viewport = clip.convert(clip.bounds, to: nil)
        guard !rect.isEmpty, !viewport.isEmpty, rect.minY.isFinite, rect.maxY.isFinite,
              viewport.minY.isFinite, viewport.maxY.isFinite else { return false }
        // A remounted Markdown view may still have its temporary literal-text size.
        // Do not consume the bounded restoration while layout is incomplete. Permanent
        // reflow keeps Reader's message anchor after that bounded attempt expires.
        guard abs(rect.width - point.width) < 1, abs(rect.height - point.height) < 1 else { return false }
        return align(offset: point.offset, rect: rect, in: scroll)
    }

    private func align(offset: CGFloat, rect: CGRect, in scroll: NSScrollView) -> Bool {
        let clip = scroll.contentView
        let viewport = clip.convert(clip.bounds, to: nil)
        guard !rect.isEmpty, !viewport.isEmpty, rect.minY.isFinite, rect.maxY.isFinite,
              viewport.minY.isFinite, viewport.maxY.isFinite, offset.isFinite else { return false }
        let delta = offset - (rect.maxY - viewport.maxY)
        let before = clip.bounds.origin.y
        var proposed = clip.bounds
        proposed.origin.y += clip.isFlipped ? delta : -delta
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        let movement = clip.bounds.origin.y - before
        let reached = rect.maxY - viewport.maxY + (clip.isFlipped ? movement : -movement)
        return abs(reached - offset) <= 0.5
    }
}

private struct ChatReadingMarker: NSViewRepresentable {
    let owner: ChatReadingMarkers
    let sessionID: UUID
    let messageID: UUID
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {
        owner.register(view, messageID: messageID, sessionID: sessionID)
    }
}

#if DEBUG
/// The existing layout probe measures offscreen fixtures. This bounded trace
/// supplies the missing command/callback order in an ordinary diagnostic App.
/// It observes only IDs, counts and geometry; never message text or input state.
@MainActor private enum ChatScrollTrace {
    static let enabled = ProcessInfo.processInfo.environment["D_CHAT_SCROLL_TRACE"] == "1"
        && UUID(uuidString: ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"] ?? "") != nil
    private static var count = 0
    static var canRecord: Bool { enabled && count <= 512 }
    static func write(_ values: [String: Any]) {
        guard canRecord else { return }
        var row = count == 512 ? ["event": "limit", "incomplete": true] : values
        row["sequence"] = count
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        count += 1
        guard let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return }
        NSLog("D_CHAT_SCROLL_TRACE %@", text)
    }
}
#endif

private enum ChatLayoutSpace { static let name = "chat-presentation-layout" }

extension View {
    @ViewBuilder
    func chatMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        if let probe {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatLayoutSpace.name)) }
                action: { probe(id, $0) }
        } else { self }
    }
}


struct ChatScrollRestoration: Equatable {
    let ticket = UUID()
    let sessionID: UUID
    let followsBottom: Bool
    let anchor: UUID?

    func isCurrent(sessionID: UUID?, pending: Self?) -> Bool {
        sessionID == self.sessionID && pending?.ticket == ticket
    }

    func currentSession(in state: ChatState, pending: Self?) -> ChatSession? {
        guard isCurrent(sessionID: state.selectedSessionID, pending: pending) else { return nil }
        return state.sessions.first { $0.id == sessionID }
    }
}

enum ChatPresentationText {
    static func branchSummary(_ message: ChatMessage, you: String, assistant: String) -> String {
        let summary = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String((summary.isEmpty ? (message.role == .user ? you : assistant) : summary).prefix(44))
    }
}

/// Presentation for a Store-owned chat. Lead owns construction, loading, and
/// model selection; this view never constructs a second controller or backend.
@MainActor
struct ChatWorkbenchView: View {
    @Bindable var chat: ChatController
    let model: WorkbenchModel
    let onChooseModel: () -> Void
    let onOpenLibrary: () -> Void
    let onImportAsset: () -> Void
    let importTargetTitle: String
    let onSavedAsset: (WorkflowAssetReference) -> Void
    let onRetainTemporary: ((WorkflowAssetReference, Bool, UUID) async throws -> Void)?
    let onAssetsChanged: () -> Void
    let onSavedValue: ((WorkflowDatum, UUID) async throws -> Void)?
    let onResolveSharedAsset: ((UUID, UUID?, UUID) async throws -> (ProjectStore, WorkflowAssetReference, String))?

    @Environment(\.dLanguageStore) private var language
    @State private var commandScope = WorkbenchCommandScope()
    @State private var search = ""
    @State private var showArchived = false
    @State private var showDeleted = false
    @State private var favoritesOnly = false
    @State private var selectedTag = ""
    @State private var searchJump: ChatSearchJump?
    @State private var inspectedAttemptID: UUID?
    @State private var showContextPreview = false
    @State private var lastBodyWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWorkbenchSettings) private var openSettings
    @State private var organizationExpanded = false
    @State private var organizationRequest = 0
    @State private var speechExpanded = false
    @Environment(\.workbenchContentVisible) private var workspaceVisible
    @State private var enteringMessages: Set<UUID> = []
    @State private var emptyDraftSession = ChatSession()
    @State private var composerEditorHeight: CGFloat = 0
    @State private var composerFocusRequest: UUID?
    @Environment(\.workbenchSidebars) private var sharedSidebars
    @State private var localSidebars = WorkbenchSidebarState()
    private var sidebars: WorkbenchSidebarState { sharedSidebars ?? localSidebars }
    private var showSidebar: Bool {
        get { sidebars.leading }
        nonmutating set { sidebars.leading = newValue }
    }
    @State private var preparationTab: ChatPreparationTab = .settings
    @State private var sourceSelections: [UUID: ChatSourceSelection] = [:]
    private var showInspector: Bool {
        get { sidebars.trailing }
        nonmutating set { sidebars.trailing = newValue }
    }
    @State private var sidebarWasPresented = false
    @State private var inspectorTab: ChatInspectorTab = .artifacts
    @State private var sheets = ChatSheetQueue<ChatDetail>()
    @State private var followsBottom = true
    @State private var hasNewContent = false
    private let scrollStates: ChatReadingStateStore
    @State private var readingMarkers = ChatReadingMarkers()
    @State private var visibleMessageID: UUID?
    @State private var userScrollingTranscript = false
    @State private var scrollRestoration: ChatScrollRestoration?
    @State private var issues: [UUID: String] = [:]
    @State private var issueCodes: [UUID: String] = [:]
    @State private var globalIssue: String?
    @State private var newPresetName = ""
    @State private var filePanelBusy = false
    @State private var ocrImport = false
    private var textWorkspaceActions: AnyView
    private var openToolsRequest: ChatToolsNavigationRequest?
    private var onToolsOpened: (UUID) -> Void
    private var layoutProbe: ((String, CGRect) -> Void)?

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    init(chat: ChatController, model: WorkbenchModel,
         onChooseModel: @escaping () -> Void,
         onOpenLibrary: @escaping () -> Void = {},
         onImportAsset: @escaping () -> Void = {},
         importTargetTitle: String = "",
         openToolsRequest: ChatToolsNavigationRequest? = nil,
         onToolsOpened: @escaping (UUID) -> Void = { _ in },
         onSavedAsset: @escaping (WorkflowAssetReference) -> Void,
         onRetainTemporary: ((WorkflowAssetReference, Bool, UUID) async throws -> Void)? = nil,
         onAssetsChanged: @escaping () -> Void,
         onSavedValue: ((WorkflowDatum, UUID) async throws -> Void)? = nil,
         onResolveSharedAsset: ((UUID, UUID?, UUID) async throws -> (ProjectStore, WorkflowAssetReference, String))? = nil,
         textWorkspaceActions: AnyView = AnyView(EmptyView()),
         initialPreparationTab: String = "settings",
         initialInspectorVisible: Bool = false,
         initialSettingsVisible: Bool = false,
         initialContextPreviewVisible: Bool = false,
         initialInspectedAttemptID: UUID? = nil,
         initiallyFollowsBottom: Bool = true,
         initiallyHasNewContent: Bool = false) {
        self.textWorkspaceActions = textWorkspaceActions
        self.openToolsRequest = openToolsRequest
        self.onToolsOpened = onToolsOpened
        self.chat = chat; self.model = model; self.onChooseModel = onChooseModel
        self.onOpenLibrary = onOpenLibrary; self.onImportAsset = onImportAsset; self.importTargetTitle = importTargetTitle
        self.scrollStates = model.readingState(for: chat)
        self.onSavedAsset = onSavedAsset; self.onRetainTemporary = onRetainTemporary; self.onAssetsChanged = onAssetsChanged; self.onSavedValue = onSavedValue
        self.onResolveSharedAsset = onResolveSharedAsset
        let initialSidebars = WorkbenchSidebarState()
        initialSidebars.trailing = initialInspectorVisible
        _localSidebars = State(initialValue: initialSidebars)
        _inspectorTab = State(initialValue: initialInspectedAttemptID == nil ? .artifacts : .sources)
        // Compatibility for callers requesting the system-prompt editor: it now lives on the left.
        _preparationTab = State(initialValue: ChatPreparationTab(rawValue: initialPreparationTab) ?? .settings)
        _showContextPreview = State(initialValue: initialContextPreviewVisible)
        _inspectedAttemptID = State(initialValue: initialInspectedAttemptID)
        let saved = chat.selectedSession.flatMap { scrollStates.state(for: $0, owner: chat) }
        _followsBottom = State(initialValue: saved?.followsBottom ?? initiallyFollowsBottom)
        _hasNewContent = State(initialValue: saved?.hasNewContent ?? initiallyHasNewContent)
        _visibleMessageID = State(initialValue: saved?.anchor)
    }

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }
    private func newLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "chat." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }
    private var session: ChatSession? { chat.selectedSession }
    private func canRun(_ session: ChatSession) -> Bool {
        ChatRunAdmission.allows(session, isRunning: chat.isRunning,
            hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
            invalidFields: chat.invalidParameterFields)
    }
    private func report(_ message: String?, for sessionID: UUID?, code: String? = nil) {
        if let sessionID { issues[sessionID] = message; issueCodes[sessionID] = code }
        else { globalIssue = message }
    }
    private func visibleSessions(_ sessions: [ChatSession]) -> [ChatSession] {
        ChatContextSessionList.visible(sessions, archived: showArchived, deleted: showDeleted,
                                       favoritesOnly: favoritesOnly, tag: selectedTag)
    }
    private func searchHits(_ sessions: [ChatSession]) -> [ChatSearchHit] {
        guard !showDeleted else { return [] }
        #if DEBUG
        ChatRowUpdateProbe.searchQuery?()
        #endif
        return ChatHistorySearch.matches(in: visibleSessions(sessions), query: search)
    }
    private func allTags(_ sessions: [ChatSession]) -> [String] {
        Array(Set(sessions.filter { ($0.contextChoices?.deletedAt != nil) == showDeleted }
            .flatMap { $0.contextChoices?.tags ?? [] })).sorted()
    }

    @Environment(\.workbenchNavigationTop) private var navigationTop
    var body: some View {
        GeometryReader { geometry in
            let sidebarShown = showSidebar
            let inspectorShown = showInspector
            let shell = WorkbenchShellLayout(viewport: geometry.size, navigationTop: navigationTop,
                requested: sidebars.requestedWidths, leading: sidebarShown, trailing: inspectorShown)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                Group {
                    if !chat.isLoaded {
                        VStack(spacing: 0) {
                            HStack { Text(label("conversation", "对话")).font(.headline); Spacer(); textWorkspaceActions }.padding(8)
                            ContentUnavailableView(label("loadFailed", "聊天记录不可用"), systemImage: "exclamationmark.triangle",
                                description: Text(chat.error.map { ChatErrorText.display($0, language: language) } ?? label("loading", "正在读取聊天记录…")))
                        }
                    } else if let session {
                        conversation(session, width: geometry.size.width, height: geometry.size.height, sidebarShown: sidebarShown)
                    } else {
                        emptyConversation(width: geometry.size.width, sidebarShown: sidebarShown)
                    }
                }
                if chat.isLoaded {
                    if let session, session.archived || session.contextChoices?.deletedAt != nil {
                        closedComposer(session).chatMeasured("composer-readonly", probe: layoutProbe)
                    } else {
                        composer(session ?? emptyDraftSession, availableHeight: geometry.size.height)
                            .chatMeasured("composer", probe: layoutProbe)
                    }
                }
                }
                .frame(width: shell.center.width, height: shell.center.height)
                .workbenchMeasureLayout("chat-center")
                .transaction { $0.animation = nil }
                .chatMeasured("conversation", probe: layoutProbe)
                .position(x: shell.center.midX, y: shell.center.midY)
                .workbenchMorph(value: sidebarShown).workbenchMorph(value: inspectorShown)

                WorkbenchSidebar(leading: true, expanded: sidebarShown,
                    title: consistencyText(language, "tabs." + preparationTab.rawValue),
                    identifier: "chat-sessions-toggle", hostIdentifier: "chat-sessions-host",
                    toggle: { showSidebar.toggle(); sidebarWasPresented = showSidebar }) {
                        configurationPane
                    }.frame(width: shell.widths.leading, height: shell.panelHeight)
                    .chatMeasured("sessions-pane", probe: layoutProbe)
                    .position(x: shell.panel(leading: true).midX, y: shell.panel(leading: true).midY)
                WorkbenchSidebar(leading: false, expanded: inspectorShown,
                    title: consistencyText(language, inspectorTab == .artifacts ? "tabs.results" : "tabs.sources"),
                    identifier: "chat-inspector-toggle", hostIdentifier: "chat-inspector-host",
                    toggle: { showInspector.toggle() }) {
                        if let session { inspector(session) }
                        else { Text(label("noConversation", "尚未选择对话")).foregroundStyle(.secondary).padding() }
                    }.frame(width: shell.widths.trailing, height: shell.panelHeight)
                    .chatMeasured("inspector-pane", probe: layoutProbe)
                    .position(x: shell.panel(leading: false).midX, y: shell.panel(leading: false).midY)
            }
            // Pane content owns its clipping. The layout container must leave
            // room for each floating plate's outer shadow.
            .environment(\.workbenchPanelWidths, shell.widths)
            .onAppear { sidebarWasPresented = sidebarShown; lastBodyWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in lastBodyWidth = width }

        }
        .background(WorkbenchCommandWindow(scope: commandScope))
        .focusedSceneValue(\.workbenchChat, workspaceVisible ? chatCommands : nil)
        .coordinateSpace(name: ChatLayoutSpace.name)
        .environment(\.workbenchMenuContext, "chat:\(ObjectIdentifier(chat)):\(ObjectIdentifier(chat.store)):\(chat.state.selectedSessionID?.uuidString ?? "none")")
        .task(id: openToolsRequest) {
            if let openToolsRequest {
                guard openToolsRequest.matches(chat) else { onToolsOpened(openToolsRequest.id); return }
                showSidebar = true; preparationTab = .tools
                onToolsOpened(openToolsRequest.id)
            }
        }
        .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
        .onChange(of: ObjectIdentifier(chat)) { _, _ in sourceSelections = [:] }
        .onChange(of: chat.state.selectedSessionID) { _, _ in composerFocusRequest = nil }
        .onChange(of: ChatMessageAcceptance(owner: ObjectIdentifier(chat), session: chat.state.selectedSessionID,
            loaded: chat.isLoaded, visible: workspaceVisible, count: session?.messages.count ?? 0)) { before, after in
            enteringMessages = after.acceptsArrival(after: before) ? Set((session?.messages.suffix(after.count - before.count) ?? []).map(\.id)) : []
        }
        .preferredColorScheme(model.chatDisplaySettings.preferences.preferredColorScheme)
        .task {
            let preferences = model.chatDisplaySettings
            chat.onPersistedTerminal = { _ in
                if preferences.preferences.endSound == true { NSSound(named: "Glass")?.play() }
            }
            if !chat.isLoaded { await chat.load() }
        }
        .workbenchSheet(item: Binding(get: { sheets.detail }, set: { sheets.detail = $0 }), title: detailTitle) { item in
            switch item {
            case .edit(let edit): editSheet(edit)
            case .message(let owner, let message, let attempt):
                WorkbenchScrollView { messageDetails(message, session: owner, attempt: attempt).padding(20) }
            case .raw(_, let text):
                VStack(alignment: .leading, spacing: 12) {
                    Button(clarity("copyRaw"), systemImage: "doc.on.doc") { copy(text) }
                    WorkbenchScrollView { Text(text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(20)

            case .searchHit(let hit):
                VStack(alignment: .leading, spacing: 12) {
                    Text(label(hit.textVersion == .selected ? "searchSelectedVersion" : "searchOriginalVersion", "")).font(.caption)
                    Button(label("copy", "复制"), systemImage: "doc.on.doc") { copy(hit.sourceText) }
                    WorkbenchScrollView { Text(hit.sourceText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(20)
            case .request(let attempt):
                VStack(alignment: .leading) {
                    HStack {
                        Text(newLabel("requestDetails", english: "Message details", chinese: "消息详情")).font(.headline)
                        Spacer()
                        Button(newLabel("done", english: "Done", chinese: "完成")) { sheets.detail = nil }.keyboardShortcut(.cancelAction)
                    }.padding()
                    WorkbenchScrollView { requestInspectionPanel(attempt).padding(20) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

            case .projectAttachments(let owner):
                ChatProjectAttachmentSheet(chat: chat, sessionID: owner, resolveSession: {
                        guard let id = try composerOwner(owner, creating: true) else { throw CancellationError() }; return id
                    },
                    wording: { en, zh in newLabel(en, english: en, chinese: zh) },
                    close: { sheets.detail = nil })
            case .knowledgeDirectory(let owner, let url, let inventory, let scoped):
                ChatKnowledgeDirectorySheet(inventory: inventory, wording: { en, zh in newLabel(en, english: en, chinese: zh) },
                    importEntries: { entries in
                        guard chat.state.sessions.contains(where: { $0.id == owner }) else { throw WorkflowIssue("原会话已离开。") }
                        await importURLs(entries.map(\.url), sessionID: owner, knowledge: true, directoryEntries: entries)
                        if let issue = issues[owner] { throw WorkflowIssue(issue) }
                    }, close: { sheets.detail = nil })
                    .onDisappear { if scoped { url.stopAccessingSecurityScopedResource() } }
            case .artifact(let content):
                ChatArtifactEditor(content: content, mermaidDocument: ChatMermaidDocument.document,
                    onSave: { value in
                        let saved = try await chat.saveArtifact(value)
                        onAssetsChanged(); return saved
                    }, onClose: { sheets.detail = nil })

            case .fields(let choices):
                ChatAnswerFieldSheet(choices: choices, wording: { en, zh in newLabel(en, english: en, chinese: zh) },
                    onSave: { field, publication, useInWorkflow in
                        let activity = try chat.beginExternalActivity(); defer { chat.endExternalActivity(activity) }
                        let envelope = try await chat.saveAnswerField(field, assetID: publication)
                        try Task.checkCancellation()
                        if chat.isTemporary {
                            guard let source = envelope.fields?["source"]?.assetReferences.first, let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用。") }
                            if useInWorkflow, let onSavedValue { try await onSavedValue(envelope, activity) }
                            else { try await onRetainTemporary(source, false, activity) }
                        } else {
                            onAssetsChanged()
                            if useInWorkflow, let onSavedValue { try await onSavedValue(envelope, activity) }
                        }
                    }, onClose: { sheets.detail = nil })
            case .quote(let sessionID, let source):
                ChatQuoteSheet(chat: chat, sessionID: sessionID, source: source,
                    onSaved: { onAssetsChanged() }, onKeep: { reference, workflow, activity in
                        if chat.isTemporary {
                            guard let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用。") }
                            try await onRetainTemporary(reference, workflow, activity)
                        } else {
                            onAssetsChanged()
                            if workflow, let onSavedValue { try await onSavedValue(.asset(reference), activity) }
                        }
                    }, onClose: { sheets.detail = nil })
            case .comparison(let sessionID, let attemptID):
                WorkbenchScrollView {
                    ChatComparisonPanel(chat: chat, sessionID: sessionID, sourceAttemptID: attemptID,
                        onClose: { sheets.detail = nil })
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .presetImport(let presets, let data):
                VStack(alignment: .leading, spacing: 12) {
                    Text(newLabel("importPresetsTitle", english: "Import preset copies", chinese: "导入预设副本")).font(.headline)
                    Text(newLabel("importPresetsNote", english: "This creates new presets. It does not change any conversation or run a model.",
                        chinese: "将创建新预设，不改变现有会话，也不会运行模型。"))
                    WorkbenchScrollView {
                        ForEach(presets) { item in
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text(item.prompt).textSelection(.enabled)
                                if let configuration = item.configuration { Text(configuration.operationID).font(.caption) }
                            }.padding(.vertical, 6)
                        }
                    }
                    HStack {
                        Button(label("cancel", "取消")) { sheets.detail = nil }
                        Button(newLabel("importCopies", english: "Import copies", chinese: "导入副本")) {
                            perform(sessionID: chat.state.selectedSessionID) { try chat.importPresets(data); sheets.detail = nil }
                        }
                    }
                }.padding(20).frame(minWidth: 560, minHeight: 360)
            case .conversationImport(let data, let title):
                ChatConversationImportSheet(data: data, title: title,
                    onCancel: { sheets.detail = nil }, onAccept: { index, chosenTitle, allowingLosses, importID in
                        _ = try await chat.importConversation(data, title: chosenTitle, allowingLosses: allowingLosses,
                                                              importID: importID, selectedConversationIndex: index)
                        sheets.detail = nil
                    })
            case .preview(let preview):
                VStack(alignment: .leading) {
                    Button(label("close", "关闭")) { sheets.detail = nil }.keyboardShortcut(.cancelAction)
                    QuickAssetPreview(store: chat.store, reference: preview, compact: false)
                }.padding(20).frame(minWidth: 560, minHeight: 360)
            }
        }
    }

    private func emptyConversation(width: CGFloat, sidebarShown: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label("conversation", "对话")).font(.headline)
                Spacer()
                Button(workflowText(language, "quick.textWorkspace.newConversation"), systemImage: "plus") { createSession() }
                    .disabled(chat.saveIssue != nil).accessibilityIdentifier("chat-new-conversation")
                textWorkspaceActions
            }.padding(8)
            ChatEmptyConversationView(onNew: { createSession() }, showsNewButton: false)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .chatMeasured("empty-conversation", probe: layoutProbe)
    }

    private func refinement(_ key: String, _ en: String, _ zh: String) -> String {
        workflowText(language, "refinement.chat." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en)
    }

    /// One left pane: model/next-request controls by default, with the original
    /// conversation browser a directly reachable alternate (never a fifth pane).
    private var configurationPane: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarTabs(title: consistencyText(language, "BAR-LEFT"), selection: $preparationTab, choices: [
                (.settings, consistencyText(language, "TAB-CHAT-LEFT-SETTINGS")),
                (.assets, consistencyText(language, "TAB-CHAT-LEFT-ASSETS")),
                (.conversations, consistencyText(language, "TAB-CHAT-LEFT-CHATS")),
                (.tools, consistencyText(language, "TAB-CHAT-LEFT-TOOLS"))], helpPrefix: "TAB-CHAT-LEFT-")
            WorkbenchSidebarPages(selection: preparationTab, choices: ChatPreparationTab.allCases, identifier: "chat-left") { tab in
                switch tab {
                case .settings: configurationContent
                case .conversations: sidebar
                case .assets:
                    if let session { materialsContent(session) }
                case .tools:
                    if let session { toolsContent(session) }
                }
            }
        }
    }
    private var configurationContent: some View {
ScrollViewReader { proxy in
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let session, let node = session.configuration,
                           let definition = WorkflowRegistry.standard.operation(node.operationID)?.definition {
                            WorkbenchModelCard(definition: definition, modelID: node.parameters["modelID"]?.string,
                                choices: model.projectSession.explicitModelChoices, status: readiness(node.parameters["modelID"]?.string ?? ""),
                                change: onChooseModel, canChange: chat.isLoaded && session.contextChoices?.deletedAt == nil,
                                changeUnavailableReason: consistencyText(language, !chat.isLoaded ? "help.reason.loading" : "help.reason.deleted"))
                                .accessibilityIdentifier("chat-model-picker").chatMeasured("change-model", probe: layoutProbe)
                        } else { Button(label("changeModel", "更换模型"), action: onChooseModel).disabled(!chat.isLoaded || session?.contextChoices?.deletedAt != nil) }
                        if let session {
                            DisclosureGroup(newLabel("commonPresets", english: "Common presets", chinese: "常用预设")) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(chat.state.presets) { preset in
                                        Button(preset.name + " · " + (preset.configuration == nil
                                            ? newLabel("rulesOnly", english: "Rules only", chinese: "仅规则")
                                            : newLabel("rulesAndModel", english: "Rules + model settings", chinese: "规则＋模型设置"))) {
                                            perform(sessionID: session.id) { try chat.applyPreset(preset.id, sessionID: session.id) }
                                        }.disabled(!chat.isLoaded || session.archived || session.contextChoices?.deletedAt != nil || chat.saveIssue != nil)
                                    }
                                    Button(newLabel("manageCommonPresets", english: "Manage common presets…", chinese: "管理常用预设…")) { openSettings?("defaults") }.disabled(openSettings == nil)
                                }
                            }
                            settings(session).id(session.id.uuidString + ":settings")
                        }
                        else { Button(label("new", "新建")) { createSession() }.disabled(!chat.isLoaded || chat.saveIssue != nil) }
                    }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: organizationRequest) { _, _ in proxy.scrollTo("conversation-organization", anchor: .top) }
                }
    }
    private func materialsContent(_ session: ChatSession) -> some View {

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Button(layoutText(language, "importAsset"), action: onImportAsset).help(importTargetTitle)
                            Button(layoutText(language, "expandAssets"), action: onOpenLibrary)
                        }.padding(.horizontal, 12).padding(.vertical, 8)
                    WorkbenchScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            attachmentButtons(session)
                            ForEach(session.attachments) { item in attachmentRow(item, removable: true, sessionID: session.id) }
                            DisclosureGroup(newLabel("importOptions", english: "Import options", chinese: "导入选项")) {
                                Toggle(newLabel("importOCR", english: "Use local OCR for scanned PDFs on import", chinese: "导入扫描 PDF 时使用本地 OCR"), isOn: $ocrImport).font(.caption)
                            }
                            ChatKnowledgePanel(chat: chat, session: session, quote: { id in
                            perform(sessionID: session.id) { present(.quote(session.id, try chat.quoteSource(kind: .document, id: id, sessionID: session.id))) }
                        },
                                importDocuments: { Task { await chooseAttachments(for: session.id, knowledge: true) } },
                                importDirectory: { Task { await chooseKnowledgeDirectory(for: session.id) } },
                                preview: { present(.preview($0)) },
                                wording: { english, chinese in
                                    language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english
                                }).id(session.id.uuidString + ":knowledge")
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }

                    }
    }
    private func toolsContent(_ session: ChatSession) -> some View {

                    WorkbenchScrollView {
                        ChatToolsPanel(chat: chat, session: session,
                            chooseSearchCredential: { _ in openSettings?("network") },
                            openArtifact: { present(.artifact($0)) },
                            wording: { en, zh in newLabel(en, english: en, chinese: zh) })
                            .id(session.id.uuidString + ":tools").padding(16)
                    }

    }

    private var sidebar: some View {
        let sessions = chat.state.sessions, selected = chat.state.selectedSessionID
        return ChatSessionBrowser(projection: .init(owner: ObjectIdentifier(chat), sessions: sessions,
            selected: selected, query: search, archived: showArchived, deleted: showDeleted,
            favorites: favoritesOnly, tag: selectedTag, language: language?.effectiveLanguageIdentifier ?? "",
            filePanelBusy: filePanelBusy)) {
                sidebarContent(sessions, selected: selected, filePanelBusy: filePanelBusy)
            }.equatable()
    }

    private func sidebarContent(_ sessions: [ChatSession], selected: UUID?, filePanelBusy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label("history", "对话")).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Button(label("new", "新建"), systemImage: "plus") { createSession() }
                    .disabled(!chat.isLoaded || chat.saveIssue != nil)

            }
            Button(newLabel("importConversation", english: "Import conversation…", chinese: "导入会话…")) { Task { await importConversation() } }
                .disabled(filePanelBusy || !chat.isLoaded || chat.saveIssue != nil)
            TextField(newLabel("lexicalSearch", english: "Lexical search", chinese: "词法搜索"), text: $search)
                .textFieldStyle(WorkbenchGlassTextFieldStyle())
                .accessibilityIdentifier("chat-history-search")
                .help(label("searchHelp", ""))
                .disabled(showDeleted)
            HStack {
                Toggle(label("archived", "已归档"), isOn: $showArchived)
                Toggle(newLabel("deleted", english: "Deleted", chinese: "已删除"), isOn: $showDeleted)
                    .onChange(of: showDeleted) { _, _ in selectedTag = "" }
            }.controlSize(.small)
            HStack {
                Toggle(newLabel("favoritesOnly", english: "Favorites", chinese: "收藏"), isOn: $favoritesOnly)
                WorkbenchPicker(newLabel("tagFilter", english: "Tag", chinese: "标签"), selection: $selectedTag) {
                    WorkbenchChoice(newLabel("allTags", english: "All tags", chinese: "全部标签"), value:"")
                    WorkbenchChoiceForEach(allTags(sessions), id: \.self) { tag in WorkbenchChoice(tag, value:tag) }
                }.labelsHidden().accessibilityLabel(newLabel("tagFilter", english: "Filter by tag", chinese: "按标签筛选"))
            }.controlSize(.small)
            WorkbenchScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !search.isEmpty && !showDeleted {
                        Text(newLabel("lexicalResults", english: "Lexical matches in stored messages", chinese: "已保存消息的词法命中"))
                            .font(.caption).foregroundStyle(.secondary)
                        let hits = searchHits(sessions)
                        let titles = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) })
                        ForEach(hits.indices, id: \.self) { index in
                            let hit = hits[index]
                            Button {
                                do {
                                    if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID, captureReadingPoint: true) }
                                    searchJump = try ChatContextCommands.open(hit, in: chat)
                                    closeNarrowPanel()
                                    if hit.textVersion != nil { present(.searchHit(hit)) }
                                } catch {
                                    report(error.localizedDescription, for: hit.sessionID, code: (error as? WorkflowIssue)?.code)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(titles[hit.sessionID] ?? "")
                                        .font(.caption).bold().lineLimit(1)
                                    Text(searchExcerpt(hit)).lineLimit(2)
                                    if let version = hit.textVersion {
                                        Text(label(version == .selected ? "searchSelectedVersion" : "searchOriginalVersion", "")).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(WorkbenchRowButtonStyle())
                                .accessibilityLabel(newLabel("searchResult", english: "Open search result: ", chinese: "打开搜索结果：") + searchExcerpt(hit))
                                .accessibilityIdentifier("chat-search-hit-\(hit.sessionID.uuidString)-\(hit.messageID?.uuidString ?? "title")-\(index)")
                        }
                    } else { ForEach(visibleSessions(sessions)) { item in
                        HStack(spacing: 6) {
                            Button {
                                do {
                                    if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID, captureReadingPoint: true) }
                                    searchJump = nil
                                    try chat.selectSession(item.id)
                                    closeNarrowPanel()
                                } catch { report(error.localizedDescription, for: item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        if item.contextChoices?.pinned == true { Image(systemName: "pin.fill") }
                                        Text(item.title).lineLimit(2)
                                    }
                                    Text("\(item.messages.count) " + label("messages", "条消息"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let tags = item.contextChoices?.tags, !tags.isEmpty {
                                        Text(tags.joined(separator: " · ")).font(.caption2)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(selected == item.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(WorkbenchRowButtonStyle())
                                .accessibilityIdentifier("chat-session-select-\(item.id.uuidString)")
                            ChatActionMenu(title: newLabel("sessionActionsShort", english: "Actions", chinese: "操作"),
                                accessibilityIdentifier: "chat-session-actions-" + item.id.uuidString,
                                items: sessionMenuItems(item), contextID: "session:\(item.id):\(item.selectedLeafID?.uuidString ?? "none"):\(item.archived):\(String(describing:item.contextChoices))").fixedSize()
                        }
                    } }
                }
            }
        }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 16)
    }

    private func searchExcerpt(_ hit: ChatSearchHit) -> String {
        guard let range = Range(hit.range, in: hit.sourceText) else { return String(hit.sourceText.prefix(80)) }
        let start = hit.sourceText.index(range.lowerBound, offsetBy: -35, limitedBy: hit.sourceText.startIndex) ?? hit.sourceText.startIndex
        let end = hit.sourceText.index(range.upperBound, offsetBy: 45, limitedBy: hit.sourceText.endIndex) ?? hit.sourceText.endIndex
        return String(hit.sourceText[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }

    private func conversation(_ session: ChatSession, width: CGFloat, height: CGFloat, sidebarShown: Bool) -> some View {
        let structure = chat.transcriptStructure(for: session)
        let latestAnswerID = structure.path.last(where: { $0.role == .assistant })?.id
        let draftIsEmpty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    preparationTab = .conversations; showSidebar = true
                } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 26, height: 28) }
                    .buttonStyle(WorkbenchIconButtonStyle()).help(label("history", "对话"))
                    .accessibilityLabel(label("history", "对话")).accessibilityIdentifier("chat-history-open")
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(1)
                    if session.contextChoices?.deletedAt != nil {
                        Text(newLabel("deletedReadOnly", english: "Deleted · restore from the conversation list",
                            chinese: "已删除 · 请在对话列表恢复"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if session.archived {
                        Text(newLabel("archivedReadOnly", english: "Archived · read only", chinese: "已归档 · 只读"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let node = session.configuration {
                        let id = node.parameters["modelID"]?.string ?? ""
                        Text((model.projectSession.explicitModelChoices.first(where: { $0.id == id })?.displayName ??
                             (id.isEmpty ? label("chooseModel", "选择模型") : id)) + " · " + readiness(id))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(refinement("nextModel", "Choose a model for your next message", "为下一条消息选择模型")).font(.caption).foregroundStyle(.secondary)
                    }
                    if chat.isTemporary {
                        Text(refinement("temporaryNotice", "Temporary · local cache; exports and external tools may retain copies", "临时会话 · 仅本机缓存；导出与外部工具可能留存"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !session.messages.isEmpty {
                    ChatActionMenu(title: label("paths", "路径"), accessibilityIdentifier: "chat-paths",
                        items: structure.leaves.map { leaf in
                            .init(id: leaf.id.uuidString, title: branchSummary(leaf), selected: leaf.id == session.selectedLeafID) {
                                perform(sessionID: session.id) { try chat.selectLeaf(leaf.id, sessionID: session.id) }
                            }
                        } , contextID: "path:\(session.id):\(session.selectedLeafID?.uuidString ?? "none")").fixedSize().chatMeasured("paths", probe: layoutProbe)
                }
                Button(workflowText(language, "quick.textWorkspace.newConversation"), systemImage: "plus") { createSession() }
                    .disabled(chat.saveIssue != nil).accessibilityIdentifier("chat-new-conversation")
                textWorkspaceActions

            }.padding(.horizontal, 8).padding(.vertical, 8)
                .chatMeasured("topbar", probe: layoutProbe)
            if chat.isRunning, let active = chat.activeSessionID,
               let owner = chat.state.sessions.first(where: { $0.id == active }) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(owner.title + " · " + workflowText(language, "chat.phase." + chat.displayPhase.rawValue))
                        .font(.caption).lineLimit(2)
                        .help(chat.displayPhase == .lowMemoryExecution ? workflowText(language, "memory.runningHelp") : "")
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
              ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let notes = session.importLossNotes, !notes.isEmpty {
                            DisclosureGroup(newLabel("importLosses", english: "Import mapping notes", chinese: "导入映射记录")) {
                                ForEach(notes.indices, id: \.self) { Text(notes[$0]).font(.caption).textSelection(.enabled) }
                            }
                        }
                        if session.originSessionID != nil {
                            Text(label("forkOrigin", "此对话从另一条路径分叉；原对话仍保留。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(structure.path) { message in
                            let siblings = structure.siblings[(message.parentID?.uuidString ?? "root") + ":" + message.role.rawValue] ?? []
                            let attempt = chat.transcriptAttempt(message.attemptID, in: session)
                            ChatMessageRow(projection: .init(owner: ObjectIdentifier(chat), sessionID: session.id,
                                message: message, attempt: attempt, siblings: siblings, choices: session.contextChoices,
                                selectedLeafID: session.selectedLeafID,
                                canExclude: !(message.role == .user && session.selectedLeafID == message.id && draftIsEmpty),
                                archived: session.archived, hasConfiguration: session.configuration != nil,
                                canRun: canRun(session),
                                canReplay: attempt.map { ChatRunAdmission.allowsReplay(session, attempt: $0,
                                    isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil) } ?? false,
                                canAdopt: session.contextChoices?.deletedAt == nil && ChatContextCommands.canAdopt(attempt, in: chat),
                                speech: chat.speechPlaybackState, language: language?.effectiveLanguageIdentifier ?? "",
                                latestAnswer: message.id == latestAnswerID,
                                pendingSave: attempt.map { chat.hasUnsavedResult($0.id) } == true,
                                saveIssue: attempt.map { chat.hasUnsavedResult($0.id) } == true ? chat.saveIssue : nil)) {
                                    messageCard(message, session: session, siblings: siblings, attempt: attempt,
                                        latestAnswer: message.id == latestAnswerID)
                                }.equatable()
                                .modifier(ChatMessageEntrance(accepted: enteringMessages.contains(message.id)))
                                .background(ChatReadingMarker(owner: readingMarkers, sessionID: session.id, messageID: message.id))
                                .id(message.id)
                                .chatMeasured("message-\(message.id.uuidString)", probe: layoutProbe)
                        }
                        if session.selectedLeafID == nil {
                            VStack(spacing: 14) {
                                Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                                Text(refinement("begin", "What would you like to create?", "从一个想法开始")).font(.title2.weight(.semibold))
                                Text(session.configuration == nil
                                    ? refinement("beginModel", "Choose a local model, then write your first message.", "先选择本地模型，再写下你的第一条消息。")
                                    : refinement("beginReady", "Write a thought, ask a question, or add reference materials.", "写下想法、提出问题，或加入参考资料。"))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                                if session.configuration == nil {
                                    Button(label("chooseModel", "选择模型"), systemImage: "cpu", action: onChooseModel)
                                        .buttonStyle(WorkbenchPrimaryButtonStyle())
                                        .accessibilityIdentifier("chat-empty-model-picker")
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 44)
                            // Only empty conversations use this fallback target.
                            // With messages, an extra row adds trailing stack spacing.
                            Color.clear.frame(height: 1).id("chat-transcript-bottom")
                        }
                    }.scrollTargetLayout()
                        .background(WorkbenchScrollGeometry().allowsHitTesting(false))
                        .frame(maxWidth: CGFloat(model.chatDisplaySettings.preferences.transcriptWidth))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16).padding(.vertical, 20)
                }
                // Reading is observation, not a persistent request to align the
                // entire message. A Markdown paragraph may regain focus after a
                // link alert; binding that event to a tall message moves the reader.
                .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.001) { ids in
                    // A restore can produce the only visibility callback. Record
                    // its current-path ID; the state-saving observer below still
                    // defers while restoration is pending. This never scrolls.
                    guard chat.state.selectedSessionID == session.id,
                          let first = chat.selectedPath.first(where: { ids.contains($0.id) }) else { return }
                    visibleMessageID = first.id
                }
                .defaultScrollAnchor(followsBottom ? .bottom : nil, for: .sizeChanges)
                .onScrollPhaseChange { _, newPhase, context in
                    guard chat.state.selectedSessionID == session.id else { return }
                    let userPhase = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                    if userPhase { scrollRestoration = nil; searchJump = nil }
                    guard scrollRestoration?.sessionID != session.id else { return }
                    if userPhase || (userScrollingTranscript && newPhase == .idle) {
                        followsBottom = context.geometry.contentSize.height - context.geometry.contentOffset.y
                            - context.geometry.containerSize.height <= 28
                        if followsBottom { hasNewContent = false }
                        saveScrollState(for: session.id)
                    }
                    userScrollingTranscript = userPhase
                }
                .chatMeasured("transcript", probe: layoutProbe)
                .onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
                    ChatScrollPosition(offset: geometry.contentOffset.y,
                        distanceToBottom: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
                } action: { previous, current in
                    guard chat.state.selectedSessionID == session.id,
                          scrollRestoration?.sessionID != session.id else { return }
                    // Layout and programmatic movement are not a user's choice
                    // to leave the bottom. Only an actual scroll gesture changes follow intent.
                    if userScrollingTranscript {
                        followsBottom = ChatScrollPosition.followsBottom(previous: previous, current: current,
                            wasFollowing: followsBottom)
                        if followsBottom { hasNewContent = false }
                    }
                    traceScroll("geometry", session: session, position: current)
                    saveScrollState(for: session.id)
                }
                .onChange(of: visibleMessageID) { _, _ in
                    if chat.state.selectedSessionID == session.id, scrollRestoration?.sessionID != session.id {
                        traceScroll("anchor", session: session)
                        saveScrollState(for: session.id)
                    }
                }
                .onChange(of: transcriptRevision(session)) { previous, _ in
                    guard previous.hasPrefix(session.id.uuidString + ":"),
                          scrollRestoration?.sessionID != session.id else { return }
                    if followsBottom {
                        traceScroll("scroll:auto-bottom", session: session, target: "bottom")
                        scrollToLastMessage(in: session, using: scrollProxy)
                    } else {
                        hasNewContent = true
                        traceScroll("revision:no-scroll", session: session)
                    }
                    saveScrollState(for: session.id)
                }
                .onChange(of: session.id) { oldID, newID in
                    if scrollStates[oldID] == nil { saveScrollState(for: oldID) }
                    let restored = scrollStates.state(for: session, owner: chat)
                    followsBottom = restored?.followsBottom ?? true
                    hasNewContent = restored?.hasNewContent ?? false
                    visibleMessageID = nil
                    userScrollingTranscript = false
                    let restore = ChatScrollRestoration(sessionID: newID,
                        followsBottom: followsBottom, anchor: restored?.anchor)
                    scrollRestoration = restore
                    Task { @MainActor in
                        await Task.yield()
                        // A sibling can change while this task yields. Resolve the
                        // current path only after validating the restoration ticket.
                        guard let current = restore.currentSession(in: chat.state, pending: scrollRestoration),
                              searchJump?.sessionID != newID else { return }
                        if restore.followsBottom {
                            traceScroll("scroll:restore", session: current, target: "bottom")
                            scrollToLastMessage(in: current, using: scrollProxy)
                        } else if let anchor = restore.anchor {
                            traceScroll("scroll:restore", session: session, target: anchor.uuidString)
                            scrollProxy.scrollTo(anchor, anchor: .top)
                            if let point = restored?.readingPoint {
                                await restoreReadingPoint(point, ticket: restore)
                            }
                        }
                        if scrollRestoration?.ticket == restore.ticket { scrollRestoration = nil }
                    }
                }
                .onAppear {
                    scrollStates.markers = readingMarkers
                    if let jump = searchJump, jump.sessionID == session.id {
                        Task { @MainActor in
                            await Task.yield()
                            guard searchJump == jump, chat.state.selectedSessionID == jump.sessionID else { return }
                            followsBottom = false; hasNewContent = false
                            traceScroll("scroll:appear-search", session: session, target: jump.messageID.uuidString)
                            await alignSearchResult(jump, using: scrollProxy)
                        }
                        return
                    }
                    if let saved = scrollStates.state(for: session, owner: chat) {
                        followsBottom = saved.followsBottom
                        hasNewContent = saved.hasNewContent
                        if saved.followsBottom {
                            traceScroll("scroll:appear-saved", session: session, target: "bottom")
                            scrollToLastMessage(in: session, using: scrollProxy)
                        } else if let anchor = saved.anchor {
                            traceScroll("scroll:appear-saved", session: session, target: anchor.uuidString)
                            scrollProxy.scrollTo(anchor, anchor: .top)
                            if let point = saved.readingPoint {
                                let restore = ChatScrollRestoration(sessionID: session.id, followsBottom: false, anchor: anchor)
                                scrollRestoration = restore
                                Task { @MainActor in
                                    await restoreReadingPoint(point, ticket: restore)
                                    if scrollRestoration?.ticket == restore.ticket { scrollRestoration = nil }
                                }
                            }
                        }
                    } else if followsBottom {
                        traceScroll("scroll:appear-bottom", session: session, target: "bottom")
                        scrollToLastMessage(in: session, using: scrollProxy)
                    }
                }
                .onDisappear {
                    // Primary capture happens before shell navigation. This fallback never
                    // replaces a valid internal point with a missing/unmounted marker.
                    scrollStates.capture(chat)
                    if scrollStates.markers === readingMarkers { scrollStates.markers = nil }
                    scrollRestoration = nil
                }
                .onChange(of: searchJump) { _, jump in
                    guard let jump, jump.sessionID == session.id,
                          chat.state.selectedSessionID == jump.sessionID else { return }
                    scrollRestoration = nil
                    Task { @MainActor in
                        await Task.yield()
                        guard searchJump == jump, chat.state.selectedSessionID == jump.sessionID else { return }
                        followsBottom = false; hasNewContent = false
                        traceScroll("scroll:search", session: session, target: jump.messageID.uuidString)
                        await alignSearchResult(jump, using: scrollProxy)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsBottom {
                        Button(hasNewContent ? newLabel("newContent", english: "New content · Bottom", chinese: "有新内容 · 到底部") : label("bottom", "到底部"),
                               systemImage: "arrow.down") {
                            scrollRestoration = nil; searchJump = nil
                            followsBottom = true; hasNewContent = false
                            saveScrollState(for: session.id)
                            traceScroll("scroll:manual-bottom", session: session, target: "bottom")
                            scrollToLastMessage(in: session, using: scrollProxy)
                        }.padding(12).accessibilityIdentifier("chat-bottom-button")
                            .chatMeasured("bottom-button", probe: layoutProbe)
                    }
                }
              }.padding(.horizontal, 8)
        }
    }

    private func transcriptRevision(_ session: ChatSession) -> String {
        let latest = session.attempts.last
        return "\(session.id):\(session.selectedLeafID?.uuidString ?? ""):\(session.messages.count):\(latest?.rawText.utf8.count ?? 0):\(latest?.status.rawValue ?? "")"
    }

    private func scrollToLastMessage(in session: ChatSession, using proxy: ScrollViewProxy) {
        // Resolve a concrete lazy-layout target; an estimated content edge may
        // precede the final message until its height has been measured.
        if let lastID = session.selectedLeafID {
            proxy.scrollTo(lastID, anchor: .bottom)
        } else {
            proxy.scrollTo("chat-transcript-bottom", anchor: .bottom)
        }
    }

    private func alignSearchResult(_ jump: ChatSearchJump, using proxy: ScrollViewProxy) async {
        func isCurrent() -> Bool {
            searchJump == jump && chat.state.selectedSessionID == jump.sessionID
                && chat.selectedPath.contains { $0.id == jump.messageID }
        }
        guard isCurrent() else { return }
        // Leaving bottom-follow and moving a tall lazy message can each change
        // layout after the first correction. Confirm the measured edge across
        // two separate layouts, only for this explicit, cancellable navigation.
        var previous: ChatReadingMarkers.TopAlignment?
        var materialized = false
        var aligned = false
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(20))
            guard isCurrent() else { return }
            if let measured = readingMarkers.alignTop(messageID: jump.messageID, sessionID: jump.sessionID) {
                if measured.isAligned, previous == measured { aligned = true; break }
                previous = measured
            } else {
                previous = nil
                if !materialized {
                    proxy.scrollTo(jump.messageID, anchor: .top)
                    materialized = true
                }
            }
        }
        if !aligned, let current = chat.selectedSession {
            traceScroll("search:alignment-incomplete", session: current, target: jump.messageID.uuidString)
        }
        guard isCurrent() else { return }
        visibleMessageID = jump.messageID
        // Do not retain the reading point from before this explicit navigation.
        scrollStates[jump.sessionID]?.readingPoint = nil
        saveScrollState(for: jump.sessionID, captureReadingPoint: true)
        scrollRestoration = nil
        searchJump = nil
    }

    private func saveScrollState(for sessionID: UUID, captureReadingPoint: Bool = false) {
        var point = captureReadingPoint && chat.state.selectedSessionID == sessionID
            ? readingMarkers.capture(sessionID: sessionID, path: chat.selectedPath.map(\.id)) : nil
        if let id = point?.messageID, let current = chat.selectedSession {
            point?.leafID = current.selectedLeafID
            point?.revisionID = current.selectedAnswer(messageID: id)?.revisionID
            point?.outputBytes = current.messages.first(where: { $0.id == id })?.attemptID
                .flatMap { attemptID in current.attempts.first { $0.id == attemptID } }?.rawText.utf8.count ?? 0
        }
        let previous = scrollStates[sessionID]
        scrollStates[sessionID] = .init(followsBottom: followsBottom,
            hasNewContent: hasNewContent, anchor: point?.messageID ?? visibleMessageID ?? previous?.anchor,
            readingPoint: followsBottom ? nil : point ?? previous?.readingPoint,
            leafID: chat.state.sessions.first { $0.id == sessionID }?.selectedLeafID)
    }

    private func restoreReadingPoint(_ point: ChatReadingPoint, ticket: ChatScrollRestoration) async {
        // A lazy target may be materialized on the next layout pass. This bounded
        // wait belongs to one explicit session navigation, not ongoing scrolling.
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            guard let current = ticket.currentSession(in: chat.state, pending: scrollRestoration),
                  searchJump?.sessionID != ticket.sessionID,
                  chat.selectedPath.contains(where: { $0.id == point.messageID }),
                  current.id == ticket.sessionID, point.matches(current) else { return }
            if readingMarkers.restore(point, sessionID: ticket.sessionID) { return }
        }
    }

    private func traceScroll(_ event: String, session: ChatSession, position: ChatScrollPosition? = nil,
                             target: String? = nil) {
        #if DEBUG
        guard ChatScrollTrace.canRecord else { return }
        var row: [String: Any] = ["event": event, "session": session.id.uuidString,
            "revision": transcriptRevision(session), "followsBottom": followsBottom,
            "newContent": hasNewContent, "anchor": visibleMessageID?.uuidString ?? "none",
            "restoreTicket": scrollRestoration?.ticket.uuidString ?? "none",
            "inspectorRequested": showInspector, "sidebarRequested": showSidebar,
            "bodyWidth": lastBodyWidth]
        if let target { row["target"] = target }
        if let position {
            row["offset"] = position.offset
            row["distanceToBottom"] = position.distanceToBottom
        }
        ChatScrollTrace.write(row)
        #endif
    }

    private func branchSummary(_ message: ChatMessage) -> String {
        ChatPresentationText.branchSummary(message, you: label("you", "你"), assistant: label("assistant", "助手"))
    }

    private func openDataInspector(attemptID: UUID? = nil, preview: Bool = false) {
        if let attemptID, let attempt = session?.attempts.first(where: { $0.id == attemptID }) {
            present(.request(attempt)); return
        }
        showContextPreview = preview
        preparationTab = .settings
        showSidebar = true
    }

    private func retainedPane<Content: View>(_ visible: Bool, id: String, @ViewBuilder content: () -> Content) -> some View {
        RetainedContentHost(content: content()
            .environment(\.dLanguageStore, language)
            .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
            .preferredColorScheme(colorScheme)
            .foregroundStyle(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor,
                model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).secondaryColor)
            .tint(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).accentColor)
            .disabled(!visible), visible: visible, identifier: id)
            .allowsHitTesting(visible).accessibilityHidden(!visible)
    }

    private func changeMessageChoice(session: ChatSession,
                                     mutate: (inout ChatContextChoices) -> Void) {
        perform(sessionID: session.id) {
            guard chat.state.selectedSessionID == session.id else { throw WorkflowIssue("请返回原对话后再修改消息。") }
            guard chat.selectedSession?.contextChoices?.deletedAt == nil else { throw WorkflowIssue("请先恢复已删除的对话。") }
            try ChatContextCommands.choices(session, mutate: mutate, in: chat)
        }
    }

    private struct ChatSourceSelection: Equatable {
        let owner: ObjectIdentifier
        let sessionID: UUID
        let messageID: UUID
        let attemptID: UUID?
    }
    private struct ChatSourceProjection {
        let message: ChatMessage
        let attempt: ChatAttempt?
        let question: ChatMessage?
    }
    private func sourceSelection(for session: ChatSession) -> ChatSourceSelection? {
        if let explicit = sourceSelections[session.id] { return explicit }
        let selected = inspectedAttemptID.flatMap { id in session.attempts.first { $0.id == id } }
        let message = selected.flatMap { attempt in session.messages.first { $0.id == attempt.assistantMessageID } }
            ?? (try? session.path(to: session.selectedLeafID))?.last(where: { $0.role == .assistant })
        guard let message else { return nil }
        return .init(owner: ObjectIdentifier(chat), sessionID: session.id, messageID: message.id, attemptID: message.attemptID)
    }
    private func sourceProjection(_ selection: ChatSourceSelection, in session: ChatSession) -> ChatSourceProjection? {
        guard selection.owner == ObjectIdentifier(chat), selection.sessionID == session.id,
              let message = session.messages.first(where: { $0.id == selection.messageID && $0.role == .assistant }),
              message.attemptID == selection.attemptID else { return nil }
        guard let attemptID = selection.attemptID else { return .init(message: message, attempt: nil, question: nil) }
        guard let attempt = session.attempts.first(where: { $0.id == attemptID && $0.sessionID == session.id && $0.assistantMessageID == message.id }),
              let question = session.messages.first(where: { $0.id == attempt.userMessageID && $0.role == .user }) else { return nil }
        return .init(message: message, attempt: attempt, question: question)
    }
    private func openSources(messageID: UUID, sessionID: UUID, attemptID: UUID?) {
        guard chat.state.selectedSessionID == sessionID, let current = chat.selectedSession else { return }
        let selection = ChatSourceSelection(owner: ObjectIdentifier(chat), sessionID: sessionID, messageID: messageID, attemptID: attemptID)
        guard sourceProjection(selection, in: current) != nil else { return }
        sourceSelections[sessionID] = selection; inspectorTab = .sources; showInspector = true
    }
    @ViewBuilder private func sourcesContent(_ session: ChatSession) -> some View {
        if let selection = sourceSelection(for: session), let value = sourceProjection(selection, in: session) {
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(newLabel("answerSources", english: "Sources for this answer", chinese: "这条回答的来源")).font(.headline)
                    if let attempt = value.attempt, let question = value.question {
                        Text(attempt.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(newLabel("questionMaterials", english: "Materials supplied with this question", chinese: "本次问题提供的材料")).font(.subheadline)
                        ForEach(question.attachments.filter { $0.sourceOnly != true }) { item in attachmentRow(item, removable: false, sessionID: session.id) }
                        if question.attachments.contains(where: { $0.sourceOnly == true }) {
                            Text(newLabel("recordedOriginals", english: "Recorded quotations and originals", chinese: "已记录引用与原稿")).font(.subheadline)
                            Text(newLabel("originalsNote", english: "Recorded when added; later edits may change how the text uses them.", chinese: "这些是添加时保留的来源；后续编辑可能改变正文对它们的使用。")).font(.caption).foregroundStyle(.secondary)
                            ForEach(question.attachments.filter { $0.sourceOnly == true }) { item in attachmentRow(item, removable: false, sessionID: session.id) }
                        }
                        ForEach(question.knowledgeExcerpts ?? []) { excerpt in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(excerpt.name).font(.subheadline)
                                Text(excerpt.text).textSelection(.enabled)
                                Button(newLabel("sourceOriginal", english: "View original", chinese: "查看原件")) { present(.preview(excerpt.source)) }
                            }
                        }
                        if question.attachments.isEmpty, (question.knowledgeExcerpts ?? []).isEmpty {
                            Text(newLabel("noQuestionMaterials", english: "No materials recorded for this question.", chinese: "这次问题没有已记录的材料。")).foregroundStyle(.secondary)
                        }
                        Text(newLabel("sourceHistoryNote", english: "Earlier context and recorded memory sources are available in the frozen request.", chinese: "更早的上下文与已记录的记忆来源可在冻结请求中查看。")).font(.caption).foregroundStyle(.secondary)
                        Button(newLabel("inspectRequest", english: "Inspect frozen request", chinese: "检查冻结请求")) {
                            guard let current = chat.selectedSession, let recorded = sourceProjection(selection, in: current)?.attempt else { return }
                            present(.request(recorded))
                        }
                    } else {
                        Text(newLabel("importedSourcesUnavailable", english: "No local execution sources were recorded for this imported answer.", chinese: "这条导入回答没有本机执行来源记录。")).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
        } else {
            ContentUnavailableView(newLabel("noSourceSelection", english: "No answer selected", chinese: "尚未选择回答"), systemImage: "text.book.closed",
                description: Text(newLabel("chooseAnswerSources", english: "Choose Sources from an answer's actions.", chinese: "请在回答操作中选择“查看来源”。")))
        }
    }

    private func inspector(_ session: ChatSession) -> some View {
        VStack(spacing: 0) {
            WorkbenchSidebarTabs(title: consistencyText(language, "BAR-RIGHT"), selection: $inspectorTab, choices: [
                (.artifacts, consistencyText(language, "TAB-CHAT-RIGHT-RESULTS")),
                (.sources, consistencyText(language, "TAB-CHAT-RIGHT-SOURCES"))], helpPrefix: "TAB-CHAT-RIGHT-")
            WorkbenchSidebarPages(selection: inspectorTab, choices: ChatInspectorTab.allCases, identifier: "chat-right") { tab in
                if tab == .artifacts { artifactsContent(session) }
                else { sourcesContent(session) }
            }.id(session.id.uuidString + ":inspector-pages")
        }.accessibilityIdentifier("chat-inspector")
    }
    private func artifactsContent(_ session: ChatSession) -> some View {

                    WorkbenchScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(newLabel("savedAnswers", english: "Saved answers", chinese: "回答成果")).font(.headline)
                            Button(newLabel("newArtifact", english: "New editable artifact", chinese: "新建可编辑成果")) {
                                present(.artifact(.init(sessionID: session.id, title: newLabel("untitledArtifact", english: "Untitled", chinese: "未命名"), kind: .markdown, text: "")))
                            }
                            ForEach(session.artifacts ?? [], id: \.output) { value in
                                HStack {
                                    Button("\(value.title) · v\(value.revision)") { present(.artifact(value)) }
                                    if let output = value.output {
                                        Button(newLabel("useWorkflow", english: "Use in workflow", chinese: "用于工作流")) { onSavedAsset(output) }
                                    }
                                }
                            }
                            ForEach(session.attempts.filter { $0.output != nil }) { attempt in
                                if let output = attempt.output {
                                    Button(label("preview", "预览") + " · " +
                                           String((attempt.response?.finalText ?? attempt.rawText).prefix(36))) {
                                        present(.preview(output))
                                    }
                                }
                            }
                            if !session.attempts.contains(where: { $0.output != nil }) {
                                Text(newLabel("noArtifacts", english: "No saved answers", chinese: "尚无已保存回答")) .foregroundStyle(.secondary)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }

    }

    @ViewBuilder private func contextPreviewPanel(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(newLabel("contextPreviewTitle", english: "Next request preview", chinese: "下次请求预览"))
                .font(.subheadline.bold())
            Text(newLabel("contextPreviewNote", english: "Current path and draft only. This preview does not send or change them.",
                chinese: "仅显示当前路径与草稿；预览不会发送或修改它们。"))
                .font(.caption).foregroundStyle(.secondary)
            if chat.hasPendingAutomaticSearch(for: session) {
                Text(label("pendingSearchNote", "")).font(.caption).foregroundStyle(.secondary)
            }
            let result = Result { try chat.contextPreview(sessionID: session.id) }
            let summaries = (try? result.get().summaryUses) ?? []
            ForEach(chat.selectedPath) { message in
                let status = ChatContextRowStatus.forMessage(message, in: session, summaryUses: summaries)
                Text(newLabel("contextRow.\(status.rawValue)", english: status.english, chinese: status.chinese) +
                     " · " + branchSummary(message))
                    .font(.caption).lineLimit(2)
                    .chatMeasured("context-row-\(message.id.uuidString)", probe: layoutProbe)
                    .accessibilityIdentifier("chat-context-row-\(message.id.uuidString)")
            }
            switch result {
            case .success(let plan):
                Text(workflowText(language, "chat.estimatedInput", arguments: ["count": String(plan.estimatedTokens)]))
                    .font(.caption)
                    .help(label("inputEstimateHelp", ""))
                if let limit = session.configuration?.parameters["maximumPromptTokens"]?.integer {
                    Text(workflowText(language, "chat.inputLimit", arguments: ["count": String(limit)]))
                        .font(.caption)
                    if plan.estimatedTokens > limit {
                        Text(newLabel("overEstimate", english: "Estimate exceeds the configured limit.",
                            chinese: "估计值超过所选上限。"))
                            .font(.caption).foregroundStyle(.red)
                        Text(label("inputEstimateHelp", "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(newLabel("contextMedia", english: "Images: ", chinese: "图像：") + String(plan.images.count) +
                     newLabel("contextVideos", english: " · Videos: ", chinese: " · 视频：") + String(plan.videos.count))
                    .font(.caption)
            case .failure(let error):
                WorkbenchIssueText(raw: error.localizedDescription).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("chat-context-preview-error")
            }
        }.accessibilityIdentifier("chat-context-preview")
            .chatMeasured("context-preview-\(session.id.uuidString)", probe: layoutProbe)
    }

    func requestInspectionPanel(_ attempt: ChatAttempt) -> some View {
        let snapshot = ChatRequestInspection(attempt: attempt)
        return VStack(alignment: .leading, spacing: 8) {
            Text(newLabel("frozenRequest", english: "Frozen request", chinese: "冻结请求"))
                .font(.subheadline.bold())
            Text(newLabel("frozenRequestNote", english: "Saved attempt only. The JSON omits free text and credentials.",
                chinese: "仅来自已保存的尝试；JSON 省略自由文本与凭据。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.sections.filter { ["input", "messages"].contains($0.id) }) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(requestSectionTitle(section)).font(.subheadline.bold())
                    requestFields(section, attempt: attempt)
                }
            }
            ForEach(snapshot.sections.filter { !["input", "messages"].contains($0.id) }) { section in
                DisclosureGroup(requestSectionTitle(section)) {
                    requestFields(section, attempt: attempt)
                }.chatMeasured("request-section-" + section.id + "-" + attempt.id.uuidString, probe: layoutProbe)
            }
            Button(newLabel("copyRedactedJSON", english: "Copy redacted JSON", chinese: "复制脱敏 JSON")) {
                copy(snapshot.redactedJSON)
            }.accessibilityIdentifier("chat-copy-request-json")
            ChatRunFeedbackView(chat: chat, attempt: attempt).id(attempt.id)
            DisclosureGroup(newLabel("rawDetails", english: "Raw details (redacted)", chinese: "原始详情（脱敏）")) {
                Text(snapshot.redactedJSON).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("chat-request-json")
            }
        }.accessibilityIdentifier("chat-request-inspection")
            .chatMeasured("request-inspection-\(attempt.id.uuidString)", probe: layoutProbe)
    }

    private func requestSectionTitle(_ section: ChatRequestInspection.Section) -> String {
        let titles = ["source": "来源与身份（技术详情）", "input": "回答规则与格式", "messages": "实际发送的消息",
            "memory": "采用的记忆与摘要来源", "media": "媒体处理记录", "tools": "自定义工具声明",
            "template": "模型输入模板", "parameters": "本次模型参数", "seed": "本次随机种子", "response": "回答与用量记录"]
        return newLabel("requestSection." + section.id, english: section.title, chinese: titles[section.id] ?? section.title)
    }
    @ViewBuilder private func requestFields(_ section: ChatRequestInspection.Section, attempt: ChatAttempt) -> some View {
        if section.id == "input" {
            ForEach(section.fields.filter { ["system", "format"].contains($0.id) }) { field in
                requestField(field, section: section.id, attempt: attempt.id)
            }
            DisclosureGroup(newLabel("inputTechnicalDetails", english: "Material references and display details", chinese: "材料引用与展示详情")) {
                ForEach(section.fields.filter { !["system", "format"].contains($0.id) }) { field in
                    requestField(field, section: section.id, attempt: attempt.id)
                }
            }
        } else {
            ForEach(section.fields) { field in requestField(field, section: section.id, attempt: attempt.id) }
        }
    }
    private func requestField(_ field: ChatRequestInspection.Field, section: String, attempt: UUID) -> some View {
        let names = ["system": "这次使用的回答规则", "format": "回答格式（提示要求与生成后校验）",
            "messages": "消息快照", "displayLimit": "本地展示保护"]
        return VStack(alignment: .leading, spacing: 2) {
            Text(newLabel("requestField." + section + "." + field.id, english: field.label,
                chinese: section == "input" ? names[field.id] ?? field.label : field.label))
                .font(.caption).foregroundStyle(.secondary)
            Text(field.value.isEmpty ? newLabel("notSpecified", english: "Not specified", chinese: "未指定") : field.value)
                .font(.caption.monospaced()).textSelection(.enabled)
        }.chatMeasured("request-field-\(section)-\(field.id)-\(attempt.uuidString)", probe: layoutProbe)
    }

    private func sessionMenuItems(_ item: ChatSession) -> [ChatActionMenuItem] {
        var result: [ChatActionMenuItem] = [
            .init(id: "rename", title: label("rename", "重命名")) {
                present(.edit(ChatEdit(kind: .rename, sessionID: item.id, messageID: nil, text: item.title)))
            },
            .init(id: "pin", title: item.contextChoices?.pinned == true
                ? newLabel("unpin", english: "Unpin", chinese: "取消置顶") : newLabel("pin", english: "Pin", chinese: "置顶")) {
                perform(sessionID: item.id) { try ChatContextCommands.choices(item, mutate: { $0.pinned.toggle() }, in: chat) }
            },
            .init(id: "tags", title: newLabel("editTags", english: "Edit tags…", chinese: "编辑标签…")) {
                present(.edit(ChatEdit(kind: .tags, sessionID: item.id, messageID: nil, text: (item.contextChoices?.tags ?? []).joined(separator: "\n"))))
            },
            .init(id: "archive", title: item.archived ? newLabel("restoreArchive", english: "Restore from archive", chinese: "从归档恢复") : label("archive", "归档"), enabled: chat.activeSessionID != item.id) {
                perform(sessionID: item.id) { try chat.setArchived(!item.archived, sessionID: item.id) }
            },
            .init(id: "delete", title: item.contextChoices?.deletedAt == nil ? newLabel("softDelete", english: "Move to Deleted", chinese: "移到已删除") : newLabel("restoreDeleted", english: "Restore conversation", chinese: "恢复对话"), enabled: chat.activeSessionID != item.id) {
                perform(sessionID: item.id) { try chat.setDeleted(item.contextChoices?.deletedAt == nil, sessionID: item.id) }
            }
        ]
        if item.selectedLeafID != nil {
            result += [
                .init(id: "copy", title: label("copyPath", "复制所选路径")) { perform(sessionID: item.id) { copy(try chat.exportSelectedPath(sessionID: item.id, markdown: false)) } },
                .init(id: "markdown", title: label("exportMarkdown", "导出 Markdown")) { Task { await export(sessionID: item.id, markdown: true) } },
                .init(id: "text", title: label("exportPlain", "导出纯文字")) { Task { await export(sessionID: item.id, markdown: false) } },
                .init(id: "html", title: newLabel("exportHTML", english: "Export local HTML", chinese: "导出本地 HTML")) { Task { await export(sessionID: item.id, markdown: false, html: true) } }
            ]
        }
        if !chat.isTemporary {
            result.append(.init(id: "sessionPackage", title: newLabel("exportSessionPackage", english: "Export recoverable session…", chinese: "导出可恢复会话包…"), enabled: !chat.isBusy) {
                Task { await exportSessionPackage(sessionID: item.id) }
            })
        }
        result.insert(.init(id: "new", title: label("new", "新建")) { createSession() }, at: 0)
        result.append(.init(id: "organization", title: newLabel("conversationOrganization", english: "Conversation organization…", chinese: "会话整理…")) {
            perform(sessionID: item.id) {
                if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID, captureReadingPoint: true) }
                searchJump = nil
                try chat.selectSession(item.id)
                organizationExpanded = true; organizationRequest += 1
                preparationTab = .settings; showSidebar = true
            }
        })
        return ChatActionMenuItem.grouped(result, ids: [["new", "rename", "pin", "tags"], ["organization"], ["copy", "markdown", "text", "html", "sessionPackage"], ["archive", "delete"]])
    }

    private func messageMenuItems(_ message: ChatMessage, session: ChatSession, attempt: ChatAttempt?, siblings: [ChatMessage]) -> [ChatActionMenuItem] {
        let captured = ChatMessageCommandTarget(session: session, message: message, attempt: attempt)
        @MainActor func stillCurrent(_ strict: Bool = false) -> Bool {
            let current = chat.state.sessions.first { $0.id == session.id }
            return captured.isCurrent(selectedSession: chat.state.selectedSessionID, session: current,
                displayedAttempt: current.flatMap { chat.transcriptAttempt(message.attemptID, in: $0) }, requiresUnchangedValue: strict)
        }
        @MainActor func currentValues() -> (ChatSession, ChatAttempt?) {
            let owner = chat.state.sessions.first { $0.id == session.id } ?? session
            return (owner, chat.transcriptAttempt(message.attemptID, in: owner))
        }
        @MainActor func displayedText() -> String {
            let (owner, current) = currentValues()
            return ChatMessageContent.answerText(message: message, attempt: current, selectedAnswer: owner.selectedAnswer(messageID: message.id))
        }
        let choices = session.contextChoices
        let favorite = choices?.favoriteMessageIDs.contains(message.id) == true
        let excluded = choices?.excludedMessageIDs.contains(message.id) == true
        let revisions = choices?.revisions.filter { $0.messageID == message.id } ?? []
        let adoptedID = revisions.first { choices?.adoptedRevisionIDs.contains($0.id) == true }?.id
        let answerText = ChatMessageContent.answerText(message: message, attempt: attempt,
            selectedAnswer: session.selectedAnswer(messageID: message.id))
        let canAdopt = session.contextChoices?.deletedAt == nil && ChatContextCommands.canAdopt(attempt, in: chat)
        var result: [ChatActionMenuItem] = [
            .init(id: "copy", title: clarity(message.role == .user ? "copyMessage" : session.selectedAnswer(messageID: message.id)?.revisionID == nil && attempt.map { ChatChannelPresentation($0, checksFormat: false).isUnseparatedRaw } == true ? "copyCurrent" : "copyAnswer")) { copy(displayedText()) },
            .init(id: "details", title: clarity("details")) { let (owner, current) = currentValues(); present(.message(owner, message, current)) },
            .init(id: "favorite", title: favorite ? newLabel("unfavorite", english: "Remove favorite", chinese: "取消收藏") : newLabel("favorite", english: "Favorite", chinese: "收藏")) {
                changeMessageChoice(session: session) { value in
                    if value.favoriteMessageIDs.contains(message.id) { value.favoriteMessageIDs.removeAll { $0 == message.id } }
                    else { value.favoriteMessageIDs.append(message.id) }
                }
            }
        ]
        result.append(.init(id: "quote", title: clarity("quote"), enabled: attempt?.status != .running && attempt?.status != .saving) {
            perform(sessionID: session.id) { present(.quote(session.id, try chat.quoteSource(kind: .message, id: message.id, sessionID: session.id))) }
        })
        if ChatContextRowStatus.forMessage(message, in: session).canExclude {
            result.append(.init(id: "context", title: excluded ? newLabel("includeContext", english: "Include in context", chinese: "回纳上下文") : newLabel("excludeContext", english: "Exclude from context", chinese: "排除上下文"), help: label("contextChangeHelp", "")) {
                changeMessageChoice(session: session) { value in
                    if value.excludedMessageIDs.contains(message.id) { value.excludedMessageIDs.removeAll { $0 == message.id } }
                    else { value.excludedMessageIDs.append(message.id) }
                }
            })
        }
        if message.role == .user {
            result.append(.init(id: "edit", title: clarity("editMessage"), enabled: session.contextChoices?.deletedAt == nil && !chat.isBusy && chat.saveIssue == nil) {
                present(.edit(ChatEdit(kind: .message, sessionID: session.id, messageID: message.id, text: message.text)))
            })
            result.append(.init(id: "generate", title: label("generateReply", "生成回复"), enabled: canRun(session)) {
                Task { guard stillCurrent(true) else { return }; await run(sessionID: session.id) { try await chat.regenerate(message.id, sessionID: session.id) } }
            })
        } else if let parent = message.parentID {
            result.append(.init(id: "new-candidate", title: clarity("regenerate"), enabled: canRun(session)) {
                Task { guard stillCurrent(true) else { return }; await run(sessionID: session.id) { try await chat.regenerate(parent, sessionID: session.id) } }
            })
            if let attempt {
                result += [
                    .init(id: "inspect", title: newLabel("inspectRequest", english: "Inspect frozen request", chinese: "检查冻结请求")) { openDataInspector(attemptID: attempt.id) },
                    .init(id: "compare", title: newLabel("compareAnswers", english: "Compare answers…", chinese: "比较回答…")) { present(.comparison(session.id, attempt.id)) },
                    .init(id: "reproduce", title: clarity("reproduce"), enabled: ChatRunAdmission.allowsReplay(session, attempt: attempt, isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil), help: clarity("reproduceHelp")) {
                        Task { guard stillCurrent(true) else { return }; await run(sessionID: session.id) { try await chat.reproduce(attempt.id, sessionID: session.id) } }
                    }
                ]
            }
        }
        if message.role == .assistant {
            if message.parentID == nil {
                result.append(.init(id: "new-candidate", title: clarity("regenerate"), enabled: false))
            }
            result.append(.init(id: "sources", title: newLabel("viewSources", english: "View sources", chinese: "查看来源")) {
                openSources(messageID: message.id, sessionID: session.id, attemptID: message.attemptID)
            })
            result += [
                .init(id: "speak", title: clarity("read"), enabled: chat.speechPlaybackState == .idle) {
                    perform(sessionID: session.id) { try chat.speech.speak(displayedText()) }
                },
                .init(id: "adopt", title: clarity("editAnswer"), enabled: canAdopt) {
                    present(.edit(ChatEdit(kind: .answer, sessionID: session.id, messageID: message.id, text: answerText)))
                }
            ]
            if let attempt, attempt.status != .completed {
                result.append(.init(id: "adopt-partial", title: newLabel("adoptPartial", english: "Adopt current partial answer", chinese: "采用当前部分回答"), enabled: canAdopt, help: label("adoptPartialHelp", "")) {
                    perform(sessionID: session.id) { try ChatContextCommands.adopt(attempt.response?.finalText ?? attempt.rawText, messageID: message.id, sessionID: session.id, in: chat, origin: .partialAccepted) }
                })
            }
            if !revisions.isEmpty {
                var versions: [ChatActionMenuItem] = [.init(id: "original", title: newLabel("originalOutput", english: "Original model output", chinese: "原始模型输出"), selected: adoptedID == nil) {
                    perform(sessionID: session.id) { try ChatContextCommands.selectVersion(nil, messageID: message.id, sessionID: session.id, in: chat) }
                }]
                versions += revisions.enumerated().map { index, revision in
                    .init(id: revision.id.uuidString, title: workflowText(language, "chat.textVersion", arguments: ["index": String(index + 1)]) + " · " + String(revision.text.prefix(28)), selected: adoptedID == revision.id) {
                        perform(sessionID: session.id) { try ChatContextCommands.selectVersion(revision.id, messageID: message.id, sessionID: session.id, in: chat) }
                    }
                }
                result.append(.init(id: "versions", title: newLabel("answerVersions", english: "Answer versions", chinese: "回答版本"), enabled: canAdopt, children: versions))
            }
        }
        result.append(.init(id: "fork", title: clarity("fork"), help: clarity("forkHelp")) {
            perform(sessionID: session.id) { _ = try chat.forkSession(session.id, leafID: message.id, titleSuffix: label("branchSuffix", " · 分支")) }
        })
        if session.selectedAnswer(messageID: message.id) != nil {
            result += [
                .init(id: "artifact", title: clarity("artifact")) {
                    Task { @MainActor in
                        guard stillCurrent(true) else { return }
                        do {
                            let content = try await chat.artifactFromAnswer(message.id, sessionID: session.id)
                            onAssetsChanged()
                            guard chat.state.selectedSessionID == session.id else { return }
                            present(.artifact(content))
                        } catch { issues[session.id] = error.localizedDescription }
                    }
                },
                .init(id: "save", title: clarity("saveAsset")) { Task { guard stillCurrent(true) else { return }; await saveFinal(message.id, sessionID: session.id, useInWorkflow: false) } },
                .init(id: "workflow", title: label("useWorkflow", "用于工作流")) { Task { guard stillCurrent(true) else { return }; await saveFinal(message.id, sessionID: session.id, useInWorkflow: true) } }
            ]
        }
        if session.selectedAnswer(messageID: message.id)?.attempt?.outputFormat?.kind == .schema {
            result.append(.init(id: "fields", title: clarity("fields")) {
                perform(sessionID: session.id) { present(.fields(try ChatAnswerField.choices(session: session, messageID: message.id))) }
            })
        }
        if chat.speechPlaybackState == .speaking {
            result.append(.init(id: "pause-reading", title: newLabel("pauseReading", english: "Pause read-aloud", chinese: "暂停当前朗读")) { chat.speech.pauseSpeech() })
        } else if chat.speechPlaybackState == .paused {
            result.append(.init(id: "resume-reading", title: newLabel("resumeReading", english: "Resume read-aloud", chinese: "继续当前朗读")) { chat.speech.resumeSpeech() })
        }
        if chat.speechPlaybackState != .idle {
            result.append(.init(id: "stop-reading", title: newLabel("stopReading", english: "Stop read-aloud", chinese: "停止当前朗读")) { chat.speech.stopSpeech() })
        }
        if let attempt {
            @MainActor func rawOutput() -> String {
                let current = currentValues().1 ?? attempt
                return current.response?.rawText ?? current.rawText
            }
            result.append(.init(id: "raw", title: clarity("raw"), children: [
                .init(id: "view-raw", title: clarity("viewRaw")) { present(.raw(attempt.id, rawOutput())) },
                .init(id: "copy-raw", title: clarity("copyRaw")) { copy(rawOutput()) }
            ]))
        }
        if siblings.count > 1 {
            result.append(.init(id: "candidates", title: clarity("candidates"), children: siblings.enumerated().map { index, sibling in
                .init(id: sibling.id.uuidString, title: "\(index + 1) · " + branchSummary(sibling), selected: sibling.id == message.id) {
                    perform(sessionID: session.id) { try chat.selectLeaf(sibling.id, sessionID: session.id) }
                }
            }))
        }
        return result.map { $0.validated { stillCurrent() } }
    }

    private func clarity(_ key: String) -> String { workflowText(language, "chat.clarity." + key) }

    private var detailTitle: String {
        switch sheets.detail {
        case .raw: clarity("raw")
        case .searchHit: label("lexicalResults", "搜索结果")
        case .message: clarity("detailsTitle")
        default: workflowText(language, "childPanel.name.messages")
        }
    }

    private func messageDisabledReasons(_ message: ChatMessage, session: ChatSession) -> [String: String] {
        let gate: String
        if !chat.isLoaded { gate = clarity("reasonLoading") }
        else if chat.pendingSaveAttemptID != nil || chat.saveIssue != nil { gate = clarity("reasonSaving") }
        else if chat.isBusy { gate = clarity("reasonBusy") }
        else if session.archived || session.contextChoices?.deletedAt != nil { gate = clarity("reasonArchived") }
        else if session.configuration == nil { gate = clarity("reasonModel") }
        else { gate = clarity("reasonParameters") }
        return ["new-candidate": message.parentID == nil ? clarity("reasonNoQuestion") : gate,
                "edit": gate, "speak": clarity("reasonSpeech")]
    }

    private func organizedMessageMenu(_ commands: [ChatActionMenuItem], user: Bool) -> [ChatActionMenuItem] {
        ChatMessageMenuOrganization.organize(commands, contextTitle: clarity("context"),
            generationTitle: clarity("generation"), user: user)
    }

    private func messageCard(_ message: ChatMessage, session: ChatSession,
                             siblings: [ChatMessage], attempt: ChatAttempt?, latestAnswer: Bool = false) -> some View {
        let commands = messageMenuItems(message, session: session, attempt: attempt, siblings: siblings)
        let menu = organizedMessageMenu(commands, user: message.role == .user)
        let selectedAnswer = session.selectedAnswer(messageID: message.id)
        let revision = session.contextChoices?.revisions.first { $0.id == selectedAnswer?.revisionID }
        let noticeKeys = ChatMessageNotices.keys(attempt: attempt, edited: selectedAnswer?.revisionID != nil, revisionOrigin: revision?.origin,
            pendingSave: attempt.map { chat.hasUnsavedResult($0.id) } == true,
            activePhase: attempt?.id == chat.activeAttemptID ? chat.displayPhase : nil)
        let context = "message:\(session.id):\(message.id):\(attempt?.id.uuidString ?? "none"):\(selectedAnswer?.revisionID?.uuidString ?? "original")"
        return ChatBubbleLayout(user: message.role == .user) {
            ChatMessageChrome(user: message.role == .user, latestAnswer: latestAnswer) { open in
                ChatMessageContent(message: message, attempt: attempt,
                    selectedAnswer: selectedAnswer, onPreview: { present(.preview($0)) })
                    .chatMeasured(selectedAnswer?.revisionID != nil
                        ? "adopted-version-\(message.id.uuidString)" : "original-version-\(message.id.uuidString)", probe: layoutProbe)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .workbenchPanel(cornerRadius: 18)
                    .background {
                        // Behind selectable text: native selection-copy keeps priority.
                        Color.clear.workbenchContextMenu(onPresentationChange: { open.wrappedValue = $0 }) { WorkbenchMenuRows(items: menu.map(ChatActionMenu.convert)) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(message.role == .user ? label("you", "你") : label("assistant", "助手"))
            } actions: { focused, open in
                ChatMessageTools(commands: commands, menu: menu, user: message.role == .user,
                    contextID: context, identifier: "chat-message-actions-" + message.id.uuidString,
                    candidateIndex: siblings.firstIndex { $0.id == message.id } ?? 0, candidateCount: siblings.count,
                    focus: focused, menuOpen: open, moreTitle: clarity("more"), copiedTitle: clarity("copied"),
                    regenerateHelp: clarity("regenerateHelp"), readHelp: clarity("readHelp"),
                    disabledReasons: messageDisabledReasons(message, session: session),
                    layoutProbe: layoutProbe, messageID: message.id)
            } footer: {
                if !noticeKeys.isEmpty || attempt?.issue != nil {
                    ChatMessageNoticeView(attempt: attempt, keys: noticeKeys,
                        openDetails: { commands.first { $0.id == "details" }?.action?() })
                        .chatMeasured("attempt-status-\(attempt?.id.uuidString ?? "none")", probe: layoutProbe)
                }
            }
        }
    }

    @ViewBuilder private func messageDetails(_ message: ChatMessage, session: ChatSession, attempt: ChatAttempt?) -> some View {
        let selected = session.selectedAnswer(messageID: message.id)
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(clarity("sender"), value: message.role == .user ? label("you", "你") : label("assistant", "助手"))
            LabeledContent(clarity("time"), value: attempt?.createdAt.formatted() ?? clarity("notRecorded"))
            LabeledContent(clarity("displayedVersion"), value: selected?.revisionID != nil ? clarity(ChatMessageNotices.revisionKey(session.contextChoices?.revisions.first { $0.id == selected?.revisionID }?.origin)) : clarity("originalVersion"))
            if let attempt {
                let snapshot = ChatRequestInspection(attempt: attempt)
                Text(clarity("recordedModel")).font(.headline)
                // Only the frozen node is used; never today's selected model.
                let descriptor = attempt.node.parameters["modelID"]?.string.flatMap {
                    WorkflowModelRoutes.draftChoice(operationID: attempt.node.operationID, modelID: $0)
                }.flatMap { SharedLibraryProjection.descriptor(for: $0) }
                LabeledContent(clarity("model"), value: descriptor?.title ?? clarity("notRecorded"))
                LabeledContent(clarity("modelRevision"), value: descriptor?.revision ?? clarity("notRecorded"))
                LabeledContent(clarity("precision"), value: ModelSpecificationPresentation(descriptor: descriptor, language: language).precisionValue)
                if let parameters = snapshot.sections.first(where: { $0.id == "parameters" }) {
                    DisclosureGroup(clarity("parameters")) { requestFields(parameters, attempt: attempt) }
                }
                LowMemoryExecutionDetails(records: attempt.executionRecords ?? [])
                ChatRunFeedbackView(chat: chat, attempt: attempt)
                Divider()
                LabeledContent(clarity("state"), value: status(attempt))
                LabeledContent(label("finish", "结束原因"), value: workflowText(language, ChatMessageNotices.finishKey(attempt)))
                if chat.hasUnsavedResult(attempt.id) || attempt.status == .saving { Text(clarity("notSaved")) }
                if let issue = attempt.issue { WorkbenchIssueText(raw: issue, key: LowMemoryExecutionPresentation.nonExecutionCode(attempt.executionRecords)).foregroundStyle(.red).textSelection(.enabled) }
                if chat.hasUnsavedResult(attempt.id), let issue = chat.saveIssue { WorkbenchIssueText(raw: issue).textSelection(.enabled) }
                if let report = ChatChannelPresentation(attempt).formatReport {
                    Text(report.status == .valid ? label("validFormat", "原文符合请求的格式") : clarity("invalidFormat"))
                    if let reason = report.reason { Text(reason).textSelection(.enabled) }
                }
                DisclosureGroup(clarity("technical")) { requestInspectionPanel(attempt) }
            }
            if let excerpts = message.knowledgeExcerpts, !excerpts.isEmpty {
                DisclosureGroup(newLabel("usedSources", english: "Source excerpts sent with this question", chinese: "本次问题使用的资料片段")) {
                    ForEach(excerpts) { excerpt in
                        Text(excerpt.name).font(.headline)
                        Text(excerpt.text).textSelection(.enabled)
                        Button(newLabel("sourceOriginal", english: "View original", chinese: "查看原件")) { present(.preview(excerpt.source)) }
                    }
                }
            }
            if attempt == nil {
                DisclosureGroup(clarity("technical")) { Text(message.id.uuidString).textSelection(.enabled) }
            }
        }.accessibilityIdentifier("chat-message-details-" + message.id.uuidString)
    }

    private func settings(_ session: ChatSession) -> some View {
        let definition = session.configuration.flatMap { WorkflowRegistry.standard.definition(for: $0) }
        return VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text(newLabel("answerBehavior", english: "Answer behavior", chinese: "回答方式")).font(.headline)
            Text(label("futureOnly", "更改只影响之后的生成。")).font(.caption).foregroundStyle(.secondary)
                Text(label("systemPrompt", "系统提示（默认空）")) .font(.subheadline)
                TextSourcesQuestionEditor(value: session.systemPrompt, editEpoch: 0, isEditable: true,
                    accessibilityIdentifier: "chat-system-\(session.id.uuidString)",
                    accessibilityLabel: label("systemPrompt", "系统提示（默认空）"),
                    onEdit: { value in perform(sessionID: session.id) { try chat.setSystemPrompt(value, sessionID: session.id) } },
                    transparentBackground: true,
                    foregroundColor: NSColor(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor))
                    .id(session.id.uuidString + ":system")
                    .frame(height: 90).padding(4).workbenchPanel(cornerRadius: 10)
                Button(label("clearSystem", "清空系统提示")) { perform(sessionID: session.id) { try chat.setSystemPrompt("", sessionID: session.id) } }
            DisclosureGroup(newLabel("technicalName", english: "About these rules", chinese: "规则说明")) {
                Text(newLabel("systemPromptMeaning", english: "System prompt: rules sent with this conversation. This is separate from the model input template.", chinese: "系统提示词：随本会话发送的回答规则，与模型输入模板不同。")).font(.caption).foregroundStyle(.secondary)
            }
            Button(newLabel("defaultRulesSettings", english: "New conversation defaults…", chinese: "新会话默认规则设置…")) { openSettings?("defaults") }
                .disabled(openSettings == nil).accessibilityIdentifier("chat-edit-default-system")
            ChatOutputFormatPanel(chat: chat, sessionID: session.id).id(session.id.uuidString + ":output-format")
            parameterFields(session, definition: definition, advanced: false)
            Divider()
            Text(newLabel("contextMemory", english: "Context and memory", chinese: "上下文与记忆")).font(.headline)
            Button(newLabel("contextPreview", english: "What will be sent next", chinese: "下次将发送的内容")) { showContextPreview.toggle() }
                .accessibilityIdentifier("chat-context-preview-toggle")
            if showContextPreview { contextPreviewPanel(session) }
            Text(newLabel("contextScopeHint", english: "Message More → Do not send to model; materials and source excerpts are managed on the right.", chinese: "消息「更多」可设为不供模型参考；资料范围与采用片段在右侧「资料」管理。")).font(.caption).foregroundStyle(.secondary)
            ChatMemoryPanel(chat: chat, session: session, wording: { en, zh in newLabel(en, english: en, chinese: zh) })
                .id(session.id.uuidString + ":memory")
            ChatAssistancePanel(chat: chat, session: session, section: .organization, expanded: $organizationExpanded,
                wording: { en, zh in newLabel(en, english: en, chinese: zh) })
                .id(session.id.uuidString + ":organization").id("conversation-organization")
            Divider()
            DisclosureGroup(newLabel("advancedModelSettings", english: "Advanced model settings", chinese: "高级模型设置")) {
                parameterFields(session, definition: definition, advanced: true)
                DisclosureGroup(newLabel("templatePreview", english: "Model input template (advanced)", chinese: "模型输入模板（高级）")) {
                    Text(newLabel("templatePurpose", english: "Encodes the conversation for this model; it does not define writing style.", chinese: "将对话编码为模型输入；不用于定义文风。")).font(.caption).foregroundStyle(.secondary)
                    ChatTemplatePanel(chat: chat, sessionID: session.id).id(session.id.uuidString + ":template")
                }
            }
            if let notes = session.importLossNotes, !notes.isEmpty {
                DisclosureGroup(newLabel("importLosses", english: "Import mapping notes", chinese: "导入映射记录")) {
                    ForEach(notes.indices, id: \.self) { Text(notes[$0]).font(.caption).textSelection(.enabled) }
                }
            }
            if session.originSessionID != nil {
                Text(label("forkOrigin", "此对话从另一条路径分叉；原对话仍保留。")).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func parameterFields(_ session: ChatSession, definition: WorkflowOperationDefinition?, advanced: Bool) -> some View {
        if let node = session.configuration, let definition {
            let common = Set(["maximumOutputTokens", "temperature", "topP"])
            ForEach(definition.fields.filter {
                !["modelID", "task", "messagesJSON", "outputMode"].contains($0.id)
                    && (advanced != common.contains($0.id))
            }) { field in
                if field.id == "toolsJSON" {
                    Text(newLabel("customTools", english: "Custom tool declarations (advanced)", chinese: "自定义工具声明（高级）")).font(.subheadline)
                    Text(label("toolsUnexecuted", "仅向模型提供声明；此字段尚未接通自动执行。右侧工具仍可手动运行。")).font(.caption).foregroundStyle(.secondary)
                }
                QuickParameterField(ownerID: session.id.uuidString, operationID: node.operationID,
                    modelIdentity: node.parameters["modelID"]?.string,
                    field: field, value: node.parameters[field.id] ?? field.defaultValue,
                    onChange: { value in changeParameter(field.id, value: value, node: node, sessionID: session.id) },
                    raw: chat.parameterText[session.id.uuidString + ":" + field.id],
                    onRaw: { raw in changeNumeric(field: field, raw: raw, node: node, sessionID: session.id) })
            }
        }
    }

    private func closedComposer(_ session: ChatSession) -> some View {
        let deleted = session.contextChoices?.deletedAt != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(deleted
                ? newLabel("composerDeleted", english: "This conversation is deleted. Restore it or start a new one to write.", chinese: "此会话已删除。恢复会话或新建对话后即可输入。")
                : newLabel("composerArchived", english: "This conversation is archived. Restore it or start a new one to write.", chinese: "此会话已归档。恢复会话或新建对话后即可输入。"))
            if !session.draft.isEmpty {
                DisclosureGroup(newLabel("preservedDraft", english: "Preserved draft (read only)", chinese: "保留的草稿（只读）")) {
                    Text(session.draft).textSelection(.enabled).lineLimit(6)
                }
            }
            HStack {
                Button(newLabel("restoreForInput", english: "Restore conversation", chinese: "恢复会话")) {
                    perform(sessionID: session.id) {
                        if deleted { try chat.setDeleted(false, sessionID: session.id) }
                        else { try chat.setArchived(false, sessionID: session.id) }
                    }
                }.buttonStyle(WorkbenchPrimaryButtonStyle()).accessibilityIdentifier("chat-composer-restore")
                Button(newLabel("newForInput", english: "New conversation", chinese: "新建对话")) { createSession() }
                    .accessibilityIdentifier("chat-composer-new")
            }.disabled(!chat.isLoaded || chat.saveIssue != nil || chat.activeSessionID == session.id)
            if chat.canStopGeneration { composerSubmitButton(session) }
            if chat.isAssisting {
                Button(newLabel("stopAssistance", english: "Stop conversation tasks", chinese: "停止会话任务")) {
                    Task { await chat.cancelAssistance() }
                }
            }
            if let issue = issues[session.id] {
                WorkbenchIssueText(raw: issue, key: issueCodes[session.id]).font(.caption).foregroundStyle(.red)
            }
            if let issue = chat.saveIssue {
                Text(label("projectSaveIssue", "项目聊天保存失败：") + issue).font(.caption).foregroundStyle(.red)
            }
            if chat.pendingSaveAttemptID != nil || chat.saveIssue != nil {
                Button(label("retrySave", "重试保存（不重新生成）")) { Task { await chat.retrySave() } }
                    .help(clarity("retrySaveHelp"))
                    .disabled(chat.isRunning).accessibilityIdentifier("chat-composer-retry-save")
                    .chatMeasured("composer-retry-save", probe: layoutProbe)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .workbenchPanel(cornerRadius: 20).padding(.horizontal, 8).padding(.top, 8)
            .accessibilityIdentifier("chat-composer-readonly")
    }

    private func composer(_ session: ChatSession, availableHeight: CGFloat) -> some View {
        let editorLimit = speechExpanded ? min(100, max(52, availableHeight * 0.16)) : min(180, max(52, availableHeight * 0.3))
        let speechLimit = min(180, max(72, availableHeight * 0.24))
        let font = NSFont.systemFont(ofSize: CGFloat(model.chatDisplaySettings.preferences.textPointSize))
        let singleLineHeight = TextSourcesQuestionEditor.fittedHeight(text: "", font: font, width: 320, range: 0...editorLimit)
        let shape = ChatComposerShape(multiline: composerEditorHeight > singleLineHeight + 1 || session.draft.contains("\n"))
        let extensionShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let palette = model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme)
        return VStack(alignment: .leading, spacing: 8) {
            if chat.isAssisting {
                HStack {
                    Text(newLabel("assistanceRunning", english: "Conversation task running", chinese: "会话任务正在运行")).font(.caption)
                    Spacer()
                    Button(newLabel("stopAssistance", english: "Stop conversation tasks", chinese: "停止会话任务")) { Task { await chat.cancelAssistance() } }
                }
            }
            if !session.attachments.isEmpty {
                Button(newLabel("openInputMaterials", english: "Review input materials", chinese: "查看输入素材") + " (\(session.attachments.count))") {
                    preparationTab = .assets; showSidebar = true
                }
            }
            RetainedContentHost(content:
                WorkbenchScrollView {
                    ChatSpeechPanel(chat: chat, project: model.projectSession, sessionID: session.id,
                        onImportAudio: { locale in Task { await chooseTranscriptionFile(sessionID: session.id, locale: locale) } },
                        onOpenSettings: openSettings.map { open in { open("voice") } })
                        .padding(8)
                }.environment(\.dLanguageStore, language)
                    .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
                    .preferredColorScheme(colorScheme)
                    .foregroundStyle(palette.foregroundColor, palette.secondaryColor)
                    .tint(palette.accentColor).disabled(!speechExpanded),
                visible: speechExpanded, identifier: "chat-speech-host")
                .id(session.id.uuidString + ":speech")
                .transaction { $0.animation = nil }
                .frame(height: speechExpanded ? speechLimit : 0).clipped()
                .allowsHitTesting(speechExpanded)
                .accessibilityHidden(!speechExpanded)
                .clipShape(extensionShape)
                .background {
                    if speechExpanded { Color.clear.workbenchPanel(in: extensionShape) }
                }
                .workbenchMotion(value: speechExpanded)
            HStack(spacing: 12) {
                TextSourcesQuestionEditor(value: session.draft, editEpoch: 0,
                    isEditable: !session.archived && session.contextChoices?.deletedAt == nil && chat.saveIssue == nil,
                    accessibilityIdentifier: "chat-draft-\(session.id.uuidString)",
                    accessibilityLabel: newLabel("messageDraft", english: "Message draft", chinese: "待发送消息"),
                    onEdit: { value in editComposer(value, captured: session.id) },
                    pointSize: CGFloat(model.chatDisplaySettings.preferences.textPointSize),
                    sendsOnReturn: model.chatDisplaySettings.preferences.sendShortcut == .return,
                    onSubmit: { submitFromComposer(session.id) },
                    onFileDrop: { urls in
                        let owner = session.id
                        Task { await importURLs(urls, sessionID: owner) }
                    }, contentHeight: singleLineHeight...editorLimit, transparentBackground: true,
                    foregroundColor: NSColor(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor),
                    placeholder: chat.saveIssue == nil
                        ? refinement("draftPlaceholder", "Write a message, or drop files here…", "输入消息，或拖入文件…")
                        : newLabel("draftSaveBlocked", english: "Resolve the save error below to continue editing", chinese: "请先在下方重试保存，再继续编辑"),
                    focusRequest: composerFocusRequest,
                    liveValue: Binding(get: {
                        guard let id = try? composerOwner(session.id, creating: false),
                              let current = chat.state.sessions.first(where: { $0.id == id }) else { return session.draft }
                        return current.draft
                    }, set: { editComposer($0, captured: session.id) }))
                    .id(session.id.uuidString + ":draft")
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerEditorHeight = $0 }
                    .chatMeasured("composer-editor", probe: layoutProbe)
                    .help(model.chatDisplaySettings.preferences.sendShortcut == .return
                        ? refinement("returnHint", "Return sends; Shift–Return adds a line. Input method conversion takes priority.", "回车发送，Shift–回车换行；输入法选字优先。")
                        : refinement("commandHint", "Command–Return sends; Return adds a line. Drop files here to attach them.", "Command–回车发送，回车换行。拖入文件即可添加附件。"))
                composerSubmitButton(session)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background {
                Color.clear.contentShape(shape).onTapGesture { composerFocusRequest = UUID() }
                    .accessibilityHidden(true)
            }
            .workbenchPanel(in: shape)
            .chatMeasured("composer-capsule", probe: layoutProbe)
            .workbenchMotion(value: chat.canStopGeneration)
            HStack(spacing: 10) {
                attachmentButtons(session)
                Button { speechExpanded.toggle() } label: {
                    Image(systemName: "mic").frame(width: 28, height: 28)
                }.buttonStyle(WorkbenchIconButtonStyle())
                    .help(refinement("speech", "Voice input and read-aloud", "语音输入与朗读"))
                    .accessibilityLabel(refinement("speech", "Voice input and read-aloud", "语音输入与朗读"))
                    .accessibilityIdentifier("chat-speech-toggle")
                Spacer(minLength: 4)
                if session.configuration == nil {
                    Button(label("chooseModel", "选择模型"), action: onChooseModel)
                        .accessibilityIdentifier("chat-composer-model-picker")
                }
                if chat.pendingSaveAttemptID != nil || chat.saveIssue != nil {
                    Button(label("retrySave", "重试保存（不重新生成）")) { Task { await chat.retrySave() } }
                    .help(clarity("retrySaveHelp"))
                        .disabled(chat.isRunning)
                }
            }
            .padding(.horizontal, 16)
            if let issue = issues[session.id] {
                WorkbenchIssueText(raw: issue, key: issueCodes[session.id]).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let saveIssue = chat.saveIssue, saveIssue != issues[session.id] {
                Text(label("projectSaveIssue", "项目聊天保存失败：") + saveIssue)
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let globalIssue {
                WorkbenchIssueText(raw: globalIssue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if chat.selectedPath.last?.role == .user {
                Text(label("awaitingReply", "所选路径止于用户消息；请点“生成回复”，或选已完成路径。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .workbenchMotion(value: session.attachments.map(\.id))
        .frame(maxWidth: CGFloat(model.chatDisplaySettings.preferences.transcriptWidth) + 28)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
        .dropDestination(for: WorkflowCanvasTransfer.self) { items, _ in
            let owner = session.id
            Task { await importSharedAssets(items, sessionID: owner) }
            return !items.isEmpty
        }
        .dropDestination(for: URL.self) { urls, _ in
            let owner = session.id
            Task { await importURLs(urls, sessionID: owner) }
            return !urls.isEmpty
        }
    }

    private func composerOwner(_ captured: UUID, creating: Bool) throws -> UUID? {
        switch ChatComposerIdentity.resolve(captured: captured, empty: emptyDraftSession.id,
            created: nil, selected: chat.state.selectedSessionID) {
        case .current(let id): return id
        case .empty:
            guard creating else { return nil }
            return try chat.newSession(id: emptyDraftSession.id)
        case .stale: return nil
        }
    }
    private func composerIsCurrent(_ captured: UUID) -> Bool {
        ChatComposerIdentity.resolve(captured: captured, empty: emptyDraftSession.id,
            created: nil, selected: chat.state.selectedSessionID) != .stale
    }
    private func editComposer(_ value: String, captured: UUID) {
        do {
            if ChatComposerIdentity.resolve(captured: captured, empty: emptyDraftSession.id,
                created: nil, selected: chat.state.selectedSessionID) == .empty {
                guard !value.isEmpty else { return }
                try chat.newSession(id: emptyDraftSession.id, initialDraft: value)
            } else if let id = try composerOwner(captured, creating: false) {
                try chat.updateDraft(value, sessionID: id)
            }
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }

    @ViewBuilder private func composerSubmitButton(_ session: ChatSession) -> some View {
        if chat.canStopGeneration {
            Button(chat.isCancelling
                ? newLabel("stopping", english: "Stopping…", chinese: "正在停止…")
                : label("stop", "停止当前生成"), systemImage: "stop.fill") {
                Task { await chat.cancel() }
            }
            .buttonStyle(WorkbenchPrimaryButtonStyle())
            .disabled(chat.isCancelling)
            .accessibilityIdentifier("chat-stop")
            .help(newLabel("stopHelp", english: "Stop generation and keep received text. Resources are released before the next request.",
                chinese: "停止生成并保留已接收文字；资源释放后才能开始下一次。"))
            .chatMeasured("composer-stop", probe: layoutProbe)
            .transition(.identity)
        } else {
            Button(label("send", "发送"), systemImage: "arrow.up") { submitFromComposer(session.id) }
                .buttonStyle(WorkbenchPrimaryButtonStyle())
                .disabled(!ChatRunAdmission.allowsSend(session, isRunning: chat.isRunning,
                    hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
                    invalidFields: chat.invalidParameterFields))
                .accessibilityIdentifier("chat-send")
                .chatMeasured("composer-send", probe: layoutProbe)
                .transition(.identity)
        }
    }

    @ViewBuilder private func attachmentButtons(_ session: ChatSession) -> some View {
        ChatActionMenu(title: newLabel("addMaterials", english: "Add materials", chinese: "添加材料"), accessibilityIdentifier: "chat-attachments-menu",
            items: [
                .init(id: "files", title: newLabel("files", english: "Choose files…", chinese: "选择文件…"),
                      enabled: !filePanelBusy && !session.archived && session.contextChoices?.deletedAt == nil) {
                    guard composerIsCurrent(session.id), !filePanelBusy else { return }
                    Task { await chooseAttachments(for: session.id) }
                },
                .init(id: "project-assets", title: newLabel("projectAttachments", english: "Project assets…", chinese: "本项目成果与素材…"),
                      enabled: !filePanelBusy && !session.archived && session.contextChoices?.deletedAt == nil) {
                    guard composerIsCurrent(session.id), !filePanelBusy else { return }
                    present(.projectAttachments(session.id))
                },
                .init(id: "paste", title: newLabel("pasteAttachments", english: "Paste attachments", chinese: "粘贴附件")) {
                    Task { await pasteAttachments(sessionID: session.id) }
                },
                .init(id: "ocr", title: newLabel("importOCR", english: "Use local OCR for scanned PDFs on import", chinese: "导入扫描 PDF 时使用本地 OCR"), selected: ocrImport) { ocrImport.toggle() }
            ]).fixedSize().disabled(filePanelBusy || session.archived || session.contextChoices?.deletedAt != nil)
        Button {
            Task { await pasteAttachments(sessionID: session.id) }
        } label: { Image(systemName: "document.on.clipboard").frame(width: 28, height: 28) }
            .buttonStyle(WorkbenchIconButtonStyle())
            .accessibilityIdentifier("chat-paste-attachments")
            .help(newLabel("pasteAttachments", english: "Paste attachments", chinese: "粘贴附件"))
            .accessibilityLabel(newLabel("pasteAttachments", english: "Paste attachments", chinese: "粘贴附件"))
            .disabled(session.archived || session.contextChoices?.deletedAt != nil)
    }

    private var chatCommands: WorkbenchChatCommands {
        let controller = chat, id = chat.state.selectedSessionID
        func command(_ title: String, enabled: Bool, _ perform: @escaping () -> Void) -> WorkbenchGenerationCommand {
            .init(title: title, isEnabled: workspaceVisible && enabled && !filePanelBusy) {
                guard workspaceVisible, commandScope.permitsVisibleCommands, chat === controller, chat.state.selectedSessionID == id, !filePanelBusy else { return }
                perform()
            }
        }
        return .init(run: command(label("send", "发送"), enabled: session.map { ChatRunAdmission.allowsSend($0, isRunning: chat.isRunning, hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil, invalidFields: chat.invalidParameterFields) } ?? false) { if let id { submitFromComposer(id) } },
            stop: command(systemMenuText(language, "stop"), enabled: chat.canStopGeneration && !chat.isCancelling) { Task { await controller.cancel() } },
            retrySave: chat.pendingSaveAttemptID != nil || chat.saveIssue != nil ? command(systemMenuText(language, "retrySave"), enabled: !chat.isRunning) { Task { await controller.retrySave() } } : nil)
    }

    private func submitFromComposer(_ captured: UUID) {
        guard let sessionID = try? composerOwner(captured, creating: false), let session = chat.state.sessions.first(where: { $0.id == sessionID }),
              ChatRunAdmission.allowsSend(session, isRunning: chat.isRunning,
                hasPendingSave: chat.pendingSaveAttemptID != nil, hasSaveIssue: chat.saveIssue != nil,
                invalidFields: chat.invalidParameterFields) else { return }
        Task { await run(sessionID: sessionID) { try await chat.send(sessionID: sessionID) } }
    }

    private func attachmentRow(_ item: ChatAttachment, removable: Bool, sessionID: UUID) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.reference.kind == .image ? "photo" : item.reference.kind == .video ? "film" : "doc.text")
            Text(item.name).lineLimit(1)
            Text(attachmentKind(item.reference.kind)).font(.caption).foregroundStyle(.secondary)
            Button(label("preview", "预览")) { present(.preview(item.reference)) }
            if removable {
                let items = chat.state.sessions.first(where: { $0.id == sessionID })?.attachments ?? []
                Button(newLabel("attachmentEarlier", english: "Earlier", chinese: "前移")) {
                    perform(sessionID: sessionID) { try chat.moveAttachment(item.id, by: -1, sessionID: sessionID) }
                }.disabled(items.first?.id == item.id)
                Button(newLabel("attachmentLater", english: "Later", chinese: "后移")) {
                    perform(sessionID: sessionID) { try chat.moveAttachment(item.id, by: 1, sessionID: sessionID) }
                }.disabled(items.last?.id == item.id)
                Button(label("remove", "移除")) { perform(sessionID: sessionID) { try chat.removeAttachment(item.id, sessionID: sessionID) } }
            }
        }.font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .chatMeasured("attachment-\(item.id.uuidString)", probe: layoutProbe)
    }

    private func readiness(_ id: String) -> String {
        switch model.projectSession.explicitModelReadiness[id] ?? .unknown {
        case .available: label("ready", "文件已核验 · 运行时仍需检查")
        case .unprepared: label("unprepared", "需要准备模型文件")
        case .unavailable: label("unavailable", "文件或授权暂不可用")
        case .unsupported: label("unsupported", "当前入口未适配")
        case .unknown: label("unknown", "准备状态待核验")
        }
    }
    private func status(_ attempt: ChatAttempt) -> String {
        let fallback: String = switch attempt.status {
        case .running: "生成中"; case .completed: "已完成"; case .partial: "部分完成"
        case .cancelled: "已取消"; case .failed: "失败"; case .interrupted: "已中断"
        case .saving: "保存中"
        }
        return label("status." + attempt.status.rawValue, fallback)
    }
    private func attachmentKind(_ kind: WorkflowDataKind) -> String {
        switch kind {
        case .text: label("kind.text", "文字")
        case .image: label("kind.image", "图像")
        case .video: label("kind.video", "视频")
        case .document: newLabel("kind.document", english: "Document", chinese: "文档")
        default: kind.rawValue
        }
    }
    private func copy(_ string: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
    }
    private func perform(sessionID: UUID? = nil, clearOnSuccess: Bool = true, _ action: () throws -> Void) {
        let owner = sessionID ?? chat.state.selectedSessionID
        do { try action(); if clearOnSuccess { report(nil, for: owner) } }
        catch { report(error.localizedDescription, for: owner, code: (error as? WorkflowIssue)?.code) }
    }
    private func run(sessionID: UUID, _ action: () async throws -> Void) async {
        guard chat.state.selectedSessionID == sessionID else { return }
        do { try await action(); report(nil, for: sessionID) }
        catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }
    private func savePreset(_ session: ChatSession) {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(sessionID: session.id) { try chat.setPreset(ChatPromptPreset(name: name, prompt: session.systemPrompt)) }
        if issues[session.id] == nil { newPresetName = "" }
    }
    private func changeParameter(_ key: String, value: WorkflowScalar, node: WorkflowNode, sessionID: UUID) {
        var copy = node; copy.parameters[key] = value
        perform(sessionID: sessionID) { try chat.updateConfiguration(copy, sessionID: sessionID) }
        let fieldKey = sessionID.uuidString + ":" + key
        if issues[sessionID] == nil { chat.invalidParameterFields.remove(fieldKey) }
        else { chat.invalidParameterFields.insert(fieldKey) }
    }
    private func changeNumeric(field: WorkflowFieldDefinition, raw: String, node: WorkflowNode, sessionID: UUID) {
        let key = sessionID.uuidString + ":" + field.id
        chat.parameterText[key] = raw
        switch field.kind {
        case .integer:
            if let value = Int(raw) { changeParameter(field.id, value: .integer(value), node: node, sessionID: sessionID) }
            else { chat.invalidParameterFields.insert(key); report(label("invalidNumber", "数值未完成或无效；修正后才能生成。"), for: sessionID) }
        case .decimal:
            if let value = Double(raw), value.isFinite { changeParameter(field.id, value: .decimal(value), node: node, sessionID: sessionID) }
            else { chat.invalidParameterFields.insert(key); report(label("invalidNumber", "数值未完成或无效；修正后才能生成。"), for: sessionID) }
        default: break
        }
    }

    private func chooseSearchCredential(_ provider: ChatSearchProvider, sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = newLabel("searchKeyFile", english: "Choose your local API key file for \(provider.rawValue). The key is not copied into the project.",
                                 chinese: "选择 \(provider.rawValue) 的本地 API 密钥文件；密钥不会复制到项目中。")
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store,
              chat.state.sessions.contains(where: { $0.id == sessionID }) else { return }
        do { try chat.configureSearchCredential(url, provider: provider); report(nil, for: sessionID) }
        catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }

    private func chooseKnowledgeDirectory(for sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let inspection = Task.detached(priority: .userInitiated) { try ChatKnowledgeDirectoryInventory.inspect(url) }
            let inventory = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
            guard owner === chat, store === chat.store, chat.state.sessions.contains(where: { $0.id == sessionID }) else {
                if scoped { url.stopAccessingSecurityScopedResource() }; return
            }
            sheets.present(.knowledgeDirectory(sessionID, url, inventory, scoped))
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            report(error.localizedDescription, for: sessionID)
        }
    }

    private func chooseAttachments(for sessionID: UUID, knowledge: Bool = false) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard await panel.begin() == .OK, owner === chat, store === chat.store else { return }
        await importURLs(panel.urls, sessionID: sessionID, knowledge: knowledge)
    }
    private func chooseTranscriptionFile(sessionID: UUID, locale: String) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = newLabel("audioImport", english: "Choose a local PCM WAV or CAF. D keeps a copy, transcribes on device, and waits for your review before adding text to the draft.", chinese: "选择本地PCM WAV或CAF；D保留副本并在本机转写，审核后才加入草稿，不自动发送。")
        guard await panel.begin() == .OK, let url = panel.url, owner === chat, store === chat.store else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard ["wav", "caf"].contains(url.pathExtension.lowercased()) else { throw WorkflowIssue(panel.message) }
            guard let sessionID = try composerOwner(sessionID, creating: true) else { return }
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            let asset = try await store.importWorkflowMediaFile(at: url)
            onAssetsChanged(); try Task.checkCancellation()
            try await owner.transcribeSpeech(asset.record.reference, sessionID: sessionID, locale: locale)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }
    private func pasteAttachments(sessionID: UUID) async {
        // Explicit user action only; never poll the clipboard or follow web URLs.
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { await importURLs(files, sessionID: sessionID); return }
        guard let png = pasteboard.data(forType: .png), png.count <= 64 * 1_024 * 1_024 else {
            report(newLabel("pasteAttachmentMissing", english: "Copy local files or a PNG image first. Paste ordinary text directly in the draft. Other image formats can be added as files.", chinese: "请先复制本地文件或PNG图像；普通文字直接粘贴到草稿，其他图片格式可通过文件添加。"), for: sessionID); return
        }
        let owner = chat
        do {
            guard let sessionID = try composerOwner(sessionID, creating: true) else { return }
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            _ = try await owner.addPastedPNG(png, sessionID: sessionID)
            onAssetsChanged()
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }
    private func importURLs(_ urls: [URL], sessionID: UUID, knowledge: Bool = false,
                            directoryEntries: [ChatKnowledgeDirectoryInventory.Entry] = []) async {
        guard !urls.isEmpty else { return }
        guard urls.contains(where: { $0.isFileURL && (DocumentTextExtractor.supportsPlainText(fileExtension: $0.pathExtension) || ["pdf", "docx", "png", "jpg", "jpeg", "mp4"].contains($0.pathExtension.lowercased())) }) else {
            report(newLabel("supportedDocuments", english: "Supported: UTF-8 text/code/CSV, PDF, DOCX, PNG/JPEG and MP4", chinese: "支持UTF-8文字/代码/CSV、PDF、DOCX、PNG/JPEG和MP4"), for: chat.state.selectedSessionID); return
        }
        let resolved: UUID?
        do { resolved = try composerOwner(sessionID, creating: true) }
        catch { report(error.localizedDescription, for: sessionID); return }
        guard let sessionID = resolved else { return }
        let ocr = ocrImport
        let owner = chat, store = chat.store
        guard let activity = try? owner.beginExternalActivity() else { return }
        defer { owner.endExternalActivity(activity) }
        var failures: [String] = []
        for url in urls {
            guard owner === chat, store === chat.store, chat.isLoaded,
                  chat.state.sessions.contains(where: { $0.id == sessionID }) else { break }
            guard url.isFileURL else { failures.append(url.absoluteString + ": " + label("fileOnly", "仅接受本地文件")); continue }
            guard DocumentTextExtractor.supportsPlainText(fileExtension: url.pathExtension) ||
                  ["pdf", "docx", "png", "jpg", "jpeg", "mp4"].contains(url.pathExtension.lowercased()) else {
                failures.append(url.lastPathComponent + ": " + newLabel("supportedDocuments", english: "Supported: UTF-8 text/code/CSV, PDF, DOCX, PNG/JPEG and MP4", chinese: "支持UTF-8文字/代码/CSV、PDF、DOCX、PNG/JPEG和MP4"))
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                if let entry = directoryEntries.first(where: { $0.url == url }) { try entry.validateUnchanged() }
                try Task.checkCancellation()
                let published = try await store.importWorkflowMediaFile(at: url)
                onAssetsChanged()
                if knowledge {
                    try await chat.addKnowledgeDocument(published.record.reference, name: url.lastPathComponent, ocr: ocr)
                } else {
                    _ = try await chat.addAttachment(published.record.reference, name: url.lastPathComponent, sessionID: sessionID, ocr: ocr)
                }
            } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        report(failures.isEmpty ? nil : failures.joined(separator: "\n"), for: sessionID)
    }
    private func importSharedAssets(_ items: [WorkflowCanvasTransfer], sessionID: UUID) async {
        guard !items.isEmpty else { return }
        guard items.contains(where: { if case .asset = $0 { return true }; if case .assetInstance = $0 { return true }; return false }) else {
            report(label("unsupportedDrop", "只能拖入项目素材。"), for: chat.state.selectedSessionID); return
        }
        let resolved: UUID?
        do { resolved = try composerOwner(sessionID, creating: true) }
        catch { report(error.localizedDescription, for: sessionID); return }
        guard let sessionID = resolved else { return }
        let owner = chat, store = chat.store
        guard let activity = try? owner.beginExternalActivity() else { return }
        defer { owner.endExternalActivity(activity) }
        do {
            let manifest = await store.snapshot()
            let state = try await store.workflowState()
            guard owner === chat, store === chat.store else { return }
            guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "素材记录不可读。") }
            var failures: [String] = []
            for item in items {
                guard owner === chat, store === chat.store, chat.isLoaded,
                      chat.state.sessions.contains(where: { $0.id == sessionID }) else { break }
                let projectID: UUID, instanceID: UUID?, assetID: UUID
                switch item {
                case .asset(let project, let asset): (projectID, instanceID, assetID) = (project, nil, asset)
                case .assetInstance(let project, let instance, let asset): (projectID, instanceID, assetID) = (project, instance, asset)
                default:
                    failures.append(label("unsupportedDrop", "只能拖入项目素材。"))
                    continue
                }
                do {
                    if !ChatAssetDropScope.accepts(projectID: projectID, instanceID: instanceID,
                        manifestProjectID: manifest.id, manifestInstanceID: manifest.effectiveInstanceID) {
                        guard let onResolveSharedAsset else { throw WorkflowIssue("请从资料库重新拖入具有明确项目实例的素材。") }
                        let (source, reference, name) = try await onResolveSharedAsset(projectID, instanceID, assetID)
                        try Task.checkCancellation()
                        guard owner === chat, store === chat.store else { throw CancellationError() }
                        _ = try await owner.addSharedAttachment(reference, from: source, name: name, sessionID: sessionID)
                        onAssetsChanged(); continue
                    }
                    guard ChatAssetDropScope.accepts(projectID: projectID, instanceID: instanceID,
                        manifestProjectID: manifest.id, manifestInstanceID: manifest.effectiveInstanceID),
                          let asset = manifest.assets.first(where: { $0.id == assetID }),
                          let reference = archive.assets.first(where: { $0.reference.assetID == assetID })?.reference else {
                        throw WorkflowIssue(label("dropScope", "拖入素材不属于此聊天项目，或缺少受管理的版本。"))
                    }
                    try await chat.addAttachment(reference, name: asset.name, sessionID: sessionID)
                } catch {
                    failures.append(String(assetID.uuidString.prefix(8)) + ": " + error.localizedDescription)
                }
            }
            report(failures.isEmpty ? nil : failures.joined(separator: "\n"), for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }
    private func importConversation() async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= ChatInterchange.maximumImportBytes else { throw WorkflowIssue("Conversation import must be a regular file up to 2 MiB. / 会话导入限2MiB普通文件。") }
            let data = try Data(contentsOf: url)
            if let choices = try? ChatOpenWebUIImport.conversations(in: data), choices.count > 1 {
                // Selection and the selected tree's validation happen in the preview sheet.
            } else { _ = try ChatInterchange.previewImport(data) }
            present(.conversationImport(data, String(url.deletingPathExtension().lastPathComponent.prefix(100))))
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }

    private func importPresets() async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, owner === chat else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 2_097_152 else { throw WorkflowIssue("Preset file must be at most 2 MiB. / 预设文件不能超过2MiB。") }
            let data = try Data(contentsOf: url)
            let presets = try ChatPresetFile.decode(data)
            present(.presetImport(presets, data))
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }
    private func exportPresets(_ presets: [ChatPromptPreset], sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        do {
            _ = try ChatPresetFile.encode(presets)
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            guard await panel.begin() == .OK, let directory = panel.url, owner === chat, store === chat.store else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            _ = try await store.exportChatPresets(presets, exportID: UUID(), directory: directory)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }

    private func exportSessionPackage(sessionID: UUID) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "D-chat.dbackup"
        panel.message = newLabel("sessionPackagePrivacy", english: "Includes all branches, unsent draft, attachments and frozen inputs (which may contain private facts). Personal-memory identities without local content remain provenance only. Future memory reads start disabled. Restore as an independent project through the existing Restore Backup entry.", chinese: "包含所有分支、未发送草稿、附件及冻结输入（可能含私人信息）。未保存本地内容的个人记忆仅保留来源标识，恢复后默认不读取记忆。使用现有“恢复备份”入口恢复为独立项目。")
        guard await panel.begin() == .OK, let destination = panel.url, owner === chat else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            let plan = try await owner.sessionBackupPlan(sessionID: sessionID)
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            _ = try await ProjectBackup.create(plan, at: destination)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }

    private func export(sessionID: UUID, markdown: Bool, html: Bool = false) async {
        guard !filePanelBusy else { return }
        filePanelBusy = true; defer { filePanelBusy = false }
        let owner = chat, store = chat.store
        let snapshot = chat.state.sessions.first(where: { $0.id == sessionID })
        let value: String
        do {
            if html {
                guard let session = snapshot, let leaf = session.selectedLeafID else { throw WorkflowIssue("No selected conversation path. / 尚无所选会话路径。") }
                value = try ChatInterchange.exportHTML(session: session, leafID: leaf)
            } else { value = try chat.exportSelectedPath(sessionID: sessionID, markdown: markdown) }
        }
        catch { report(error.localizedDescription, for: sessionID); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await panel.begin() == .OK, let directory = panel.url,
              owner === chat, store === chat.store else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        do {
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            if html, let snapshot, let leaf = snapshot.selectedLeafID {
                _ = try await store.exportChatHTML(snapshot, leafID: leaf, exportID: UUID(), directory: directory)
                report(nil, for: sessionID); return
            }
            let reference = try await store.publishWorkflowAsset(data: Data(value.utf8), mediaType: html ? "text/html" : markdown ? "text/markdown" : "text/plain",
                name: html ? "聊天路径 HTML" : markdown ? "聊天路径 Markdown" : "聊天路径纯文字", operationID: "d.chat.export-path",
                details: ["chatSessionID": sessionID.uuidString, "format": html ? "html" : markdown ? "markdown" : "plain"]).record.reference
            onAssetsChanged()
            _ = try await store.exportWorkflowAssets([reference], name: html ? "D-chat-html" : markdown ? "D-chat-markdown" : "D-chat-text",
                                                      exportID: UUID(), directory: directory)
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }
    private func saveFinal(_ messageID: UUID, sessionID: UUID, useInWorkflow: Bool) async {
        let owner = chat
        do {
            let activity = try owner.beginExternalActivity(); defer { owner.endExternalActivity(activity) }
            let asset = try await owner.saveAssistantFinal(messageID, sessionID: sessionID)
            guard owner === chat else { return }
            if owner.isTemporary {
                guard let onRetainTemporary else { throw WorkflowIssue("长期保存入口不可用；成果仍在临时会话。") }
                try await onRetainTemporary(asset, useInWorkflow, activity)
            } else {
                onAssetsChanged()
                if useInWorkflow { onSavedAsset(asset) }
            }
            report(nil, for: sessionID)
        } catch { report(error.localizedDescription, for: sessionID, code: (error as? WorkflowIssue)?.code) }
    }

    private func present(_ item: ChatDetail) {
        // Close the actual narrow pane as well as its presentation state before
        // replacing it with a detail sheet. Inline panes remain in place.
        if sheets.narrowPanel != nil { closeNarrowPanel() }
        sheets.present(item)
    }

    private func closeNarrowPanel(keepPreference: Bool = true) {
        if !keepPreference {
            switch sheets.narrowPanel {
            case .sessions: showSidebar = false
            case .inspector: showInspector = false
            case nil: break
            }
        }
        sheets.narrowPanel = nil
        sheets.didDismissNarrowPanel()
    }

    private func createSession() {
        do {
            if let currentID = chat.state.selectedSessionID { saveScrollState(for: currentID, captureReadingPoint: true) }
            searchJump = nil
            _ = try chat.newSession()
            closeNarrowPanel()
        } catch { report(error.localizedDescription, for: chat.state.selectedSessionID) }
    }

    private func editSheet(_ edit: ChatEdit) -> some View {
        ChatEditForm(edit: edit, issue: issues[edit.sessionID], onCancel: { sheets.detail = nil }, onCommit: { text in
                switch edit.kind {
                case .rename: try chat.rename(edit.sessionID, title: text)
                case .message:
                    guard let id = edit.messageID else { throw WorkflowIssue("消息不存在。") }
                    guard chat.state.selectedSessionID == edit.sessionID else { throw WorkflowIssue("请返回原对话后再编辑消息。") }
                    _ = try chat.editUserMessage(id, text: text, sessionID: edit.sessionID)
                case .answer:
                    guard let id = edit.messageID else { throw WorkflowIssue("回答不存在。") }
                    try ChatContextCommands.adopt(text, messageID: id, sessionID: edit.sessionID, in: chat)
                case .tags:
                    guard let session = chat.state.sessions.first(where: { $0.id == edit.sessionID }) else {
                        throw WorkflowIssue("对话不存在。")
                    }
                    let tags = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    try ChatContextCommands.choices(session, mutate: { $0.tags = tags }, in: chat)
                case .defaultSystem: try chat.setDefaultSystemPrompt(text)
                }
        }, onFlush: { try await chat.flush() }, onSaved: { sheets.detail = nil })
    }
}

private struct ChatEdit: Identifiable {
    enum Kind: Equatable { case rename, message, answer, tags, defaultSystem }
    let id = UUID()
    let kind: Kind
    let sessionID: UUID
    let messageID: UUID?
    let text: String
}

@MainActor
private struct ChatEditForm: View {
    let edit: ChatEdit
    let issue: String?
    let onCancel: () -> Void
    let onCommit: (String) throws -> Void
    let onFlush: () async throws -> Void
    let onSaved: () -> Void
    @State private var applied = false
    @State private var text: String
    @State private var saving = false
    @State private var saveFailure: String?
    @Environment(\.dLanguageStore) private var language

    private func label(_ key: String, _ fallback: String) -> String {
        workflowText(language, "chat." + key, fallback: fallback)
    }
    private func newLabel(_ key: String, english: String, chinese: String) -> String {
        workflowText(language, "chat." + key,
            fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? chinese : english)
    }

    init(edit: ChatEdit, issue: String?, onCancel: @escaping () -> Void, onCommit: @escaping (String) throws -> Void, onFlush: @escaping () async throws -> Void, onSaved: @escaping () -> Void) {
        self.edit = edit; self.issue = issue; self.onCancel = onCancel; self.onCommit = onCommit; self.onFlush = onFlush; self.onSaved = onSaved
        _text = State(initialValue: edit.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let title = switch edit.kind {
                case .rename: label("rename", "重命名对话")
                case .message: label("editBranch", "编辑消息 · 创建新分支")
                case .answer: newLabel("editAdopt", english: "Edit and adopt answer", chinese: "编辑并采用回答")
                case .tags: newLabel("editTags", english: "Edit tags", chinese: "编辑标签")
                case .defaultSystem: newLabel("editDefaultSystem", english: "Default system prompt for new conversations", chinese: "新会话默认系统提示")
            }
            Text(title).font(.headline)
            if edit.kind == .message { Text(label("editMessageNote", "")).font(.caption).foregroundStyle(.secondary) }
            if edit.kind == .answer {
                Text(newLabel("originalPreserved", english: "The original model output stays unchanged. Save explicitly to adopt this version.",
                    chinese: "原始模型输出保持不变；明确保存后才采用此版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if edit.kind == .tags {
                Text(newLabel("tagLines", english: "One tag per line; up to 24 tags of 32 characters each.",
                    chinese: "每行一个标签；最多24个，每个不超过32字。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextSourcesQuestionEditor(value: text, editEpoch: 0, isEditable: !applied && !saving,
                accessibilityIdentifier: "chat-edit-\(edit.sessionID.uuidString)", accessibilityLabel: title, onEdit: { text = $0 })
                .id(edit.id).frame(height: edit.kind == .rename ? 70 : 220).workbenchInputSurface()
            if let issue = saveFailure ?? issue { WorkbenchIssueText(raw: issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                WorkbenchRequestCloseButton(title: label("cancel", "取消"), fallback: onCancel)
                Button(applied ? label("retrySave", "重试保存（不重新生成）") : edit.kind == .message ? label("createBranch", "创建分支") : edit.kind == .answer ? label("saveAndUse", "保存并采用") : label("save", "保存")) {
                    saving = true
                    Task { defer { saving = false }; do { try await saveDraft(); onSaved() } catch { saveFailure = error.localizedDescription } }
                }
                    .disabled((edit.kind == .rename || edit.kind == .message || edit.kind == .answer) &&
                              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat-edit-save")
                    .help(applied ? label("clarity.retrySaveHelp", "只重试保存，不重新生成。") : "")
            }
        }.padding(20).frame(maxWidth: .infinity).disabled(saving)
        .workbenchCloseProtection(isDirty: applied || text != edit.text, isSaving: saving, allowsDiscard: !applied, save: { try await saveDraft() })
    }
    private func saveDraft() async throws {
        if !applied { try onCommit(text); applied = true }
        try await onFlush()
    }
}

/// Explicit value boundary: construction of menus/Markdown stays inside body.
/// Independent run/speech observations used by the content still invalidate it;
/// mutable chat.state is read only in action closures, never during this row's render.
struct ChatMessageRow<Content: View>: View, Equatable {
    struct Projection: Equatable {
        let owner: ObjectIdentifier
        let sessionID: UUID
        let message: ChatMessage
        let attempt: ChatAttempt?
        let siblings: [ChatMessage]
        let choices: ChatContextChoices?
        let selectedLeafID: UUID?
        let canExclude: Bool
        let archived: Bool
        let hasConfiguration: Bool
        let canRun: Bool
        let canReplay: Bool
        let canAdopt: Bool
        let speech: ChatSpeechPlaybackState
        let language: String
        var latestAnswer = false
        var pendingSave = false
        var saveIssue: String? = nil
    }
    let projection: Projection
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.projection == rhs.projection }
    var body: some View {
        #if DEBUG
        let _ = ChatRowUpdateProbe.body?(projection.message.id)
        #endif
        content()
    }
}
#if DEBUG
@MainActor enum ChatRowUpdateProbe {
    static var body: ((UUID) -> Void)?
    static var browserBody: (() -> Void)?
    static var searchQuery: (() -> Void)?
}
#endif

/// The history browser observes stored message text only while searching. Its
/// ordinary list depends on summaries, not unsent draft or streaming bytes.
struct ChatSessionBrowser<Content: View>: View, Equatable {
    struct Projection: Equatable {
        struct Summary: Equatable {
            let id: UUID; let title: String; let count: Int; let archived: Bool
            let choices: ChatContextChoices?; let leaf: UUID?
        }
        struct SearchSource: Equatable {
            let messages: [ChatMessage]; let attempts: [ChatAttempt]
        }
        let owner: ObjectIdentifier
        let summaries: [Summary]
        let sources: [SearchSource]
        let selected: UUID?
        let query: String
        let archived: Bool; let deleted: Bool; let favorites: Bool; let tag: String; let language: String
        let filePanelBusy: Bool
        init(owner: ObjectIdentifier, sessions: [ChatSession], selected: UUID?, query: String,
             archived: Bool, deleted: Bool, favorites: Bool, tag: String, language: String, filePanelBusy: Bool) {
            self.owner = owner; self.selected = selected; self.query = query
            self.archived = archived; self.deleted = deleted; self.favorites = favorites
            self.tag = tag; self.language = language
            self.filePanelBusy = filePanelBusy
            summaries = sessions.map { .init(id: $0.id, title: $0.title, count: $0.messages.count,
                archived: $0.archived, choices: $0.contextChoices, leaf: $0.selectedLeafID) }
            sources = query.isEmpty || deleted ? [] : sessions.map { .init(messages: $0.messages, attempts: $0.attempts) }
        }
    }
    let projection: Projection
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.projection == rhs.projection }
    var body: some View {
        #if DEBUG
        let _ = ChatRowUpdateProbe.browserBody?()
        #endif
        content()
    }
}

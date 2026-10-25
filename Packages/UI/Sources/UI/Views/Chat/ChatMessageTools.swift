import AppKit
import DWorkbench
import SwiftUI

/// A command is valid for the captured displayed value, not a later selection.
/// Equality is checked only on invocation, never by hashing/encoding every row.
struct ChatMessageCommandTarget {
    let sessionID: UUID
    let leafID: UUID?
    let message: ChatMessage
    let attempt: ChatAttempt?
    let answer: ChatSelectedAnswer?
    init(session: ChatSession, message: ChatMessage, attempt: ChatAttempt?) {
        sessionID = session.id; leafID = session.selectedLeafID
        self.message = message; self.attempt = attempt
        answer = session.selectedAnswer(messageID: message.id)
    }
    func isCurrent(selectedSession: UUID?, session: ChatSession?, displayedAttempt: ChatAttempt? = nil, requiresUnchangedValue: Bool = false) -> Bool {
        guard selectedSession == sessionID, let session, session.id == sessionID,
              session.selectedLeafID == leafID,
              session.messages.first(where: { $0.id == message.id }) == message else { return false }
        let selected = session.selectedAnswer(messageID: message.id)
        guard selected?.revisionID == answer?.revisionID,
              answer?.revisionID == nil || selected?.text == answer?.text else { return false }
        let live = displayedAttempt ?? message.attemptID.flatMap { id in session.attempts.first { $0.id == id } }
        if requiresUnchangedValue { return live == attempt && selected == answer }
        // Stream bytes and terminal parsing advance within one frozen attempt.
        return live?.id == attempt?.id && live?.sessionID == attempt?.sessionID &&
            live?.node == attempt?.node && live?.messagesJSON == attempt?.messagesJSON && live?.inputs == attempt?.inputs
    }
}

extension ChatActionMenuItem {
    @MainActor func validated(_ valid: @escaping () -> Bool) -> Self {
        let guarded: (@MainActor () -> Void)?
        if let action { guarded = { if valid() { action() } } } else { guarded = nil }
        var value = Self(id: id, title: title, enabled: enabled, selected: selected,
            children: children?.map { $0.validated(valid) }, isSeparator: isSeparator, action: guarded)
        value.isCurrent = { isCurrent() && valid() }
        return value
    }
}

enum ChatMessageMenuOrganization {
    static func organize(_ commands: [ChatActionMenuItem], contextTitle: String, generationTitle: String, user: Bool) -> [ChatActionMenuItem] {
        func rows(_ ids: [String]) -> [ChatActionMenuItem] { ids.compactMap { id in commands.first { $0.id == id } } }
        var result = rows(["favorite", "quote", "fork"])
        if let context = commands.first(where: { $0.id == "context" }) {
            result.append(.init(id: "context", title: contextTitle, children: [context]))
        }
        let generation = rows(["generate", "new-candidate", "compare", "edit", "adopt", "adopt-partial", "candidates", "versions", "reproduce"])
        if !generation.isEmpty {
            result.append(.init(id: "separator-generation", title: "", isSeparator: true))
            result.append(.init(id: "generation", title: generationTitle, children: generation))
        }
        for (key, ids) in [("assets", ["save", "workflow", "artifact", "fields"]),
                           ("speech", ["speak", "pause-reading", "resume-reading", "stop-reading"]),
                           ("details", ["sources", "raw", "details"])] {
            let group = rows(ids)
            if !group.isEmpty { result.append(.init(id: "separator-" + key, title: "", isSeparator: true)); result += group }
        }
        return result
    }
    static func primaryIDs(user: Bool, compact: Bool = false) -> [String] {
        compact ? ["copy"] : user ? ["copy", "edit"] : ["copy", "new-candidate", "speak"]
    }
    static func symbols(_ id: String) -> String {
        switch id { case "copy": "doc.on.doc"; case "edit": "pencil"; case "new-candidate": "arrow.clockwise"; default: "speaker.wave.2" }
    }
}

struct ChatMessageTools: View {
    let commands: [ChatActionMenuItem]
    let menu: [ChatActionMenuItem]
    let user: Bool
    let contextID: String
    let identifier: String
    let candidateIndex: Int
    let candidateCount: Int
    @Binding var focus: Bool
    @Binding var menuOpen: Bool
    let moreTitle: String
    let copiedTitle: String
    let regenerateHelp: String
    let readHelp: String
    let disabledReasons: [String: String]
    let layoutProbe: ((String, CGRect) -> Void)?
    let messageID: UUID
    @FocusState private var focusedItem: String?
    @State private var copied = false
    @State private var copyGeneration = 0
    @State private var menuFocused = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            if candidateCount > 1 { tools(compact: false, candidates: true).fixedSize() }
            tools(compact: false, candidates: false).fixedSize()
            tools(compact: true, candidates: false).fixedSize()
        }
        .onChange(of: focusedItem) { _, value in focus = value != nil || menuFocused }
        .task(id: copyGeneration) {
            guard copyGeneration > 0 else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }; copied = false
        }
        .environment(\.workbenchMenuContext, contextID)
    }
    private func tools(compact: Bool, candidates: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(ChatMessageMenuOrganization.primaryIDs(user: user, compact: compact), id: \.self) { id in
                if let item = commands.first(where: { $0.id == id }) {
                    Button {
                        guard item.isCurrent() else { return }
                        item.action?()
                        if id == "copy" { copied = true; copyGeneration += 1 }
                    } label: {
                        Image(systemName: id == "copy" && copied ? "checkmark" : ChatMessageMenuOrganization.symbols(id))
                            .font(.system(size: 16)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(ChatMessageIconStyle()).focused($focusedItem, equals: id)
                    .disabled(!item.enabled)
                    .help(help(item)).accessibilityLabel(id == "copy" && copied ? copiedTitle : item.title)
                    .accessibilityIdentifier(identifier + "-" + id)
                }
            }
            WorkbenchMenu(moreTitle, onPresentationChange: { menuOpen = $0 }, onFocusChange: {
                menuFocused = $0; focus = $0 || focusedItem != nil
            }) { WorkbenchMenuRows(items: menu.map(ChatActionMenu.convert)) } label: {
                Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 28, height: 28)
            }.buttonStyle(ChatMessageIconStyle()).help(moreTitle).accessibilityLabel(moreTitle)
                .accessibilityIdentifier(identifier)
                .chatMeasured("message-menu-\(messageID.uuidString)", probe: layoutProbe)
            if candidates, let choices = commands.first(where: { $0.id == "candidates" })?.children {
                HStack(spacing: 0) {
                    candidateButton("chevron.left", item: choices[max(0, candidateIndex - 1)], enabled: candidateIndex > 0)
                    Text("\(candidateIndex + 1) / \(candidateCount)").font(.caption).monospacedDigit()
                    candidateButton("chevron.right", item: choices[min(choices.count - 1, candidateIndex + 1)], enabled: candidateIndex + 1 < choices.count)
                }
            }
        }
    }
    private func candidateButton(_ symbol: String, item: ChatActionMenuItem, enabled: Bool) -> some View {
        Button { item.action?() } label: { Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 28) }
            .buttonStyle(ChatMessageIconStyle()).disabled(!enabled)
            .focused($focusedItem, equals: symbol).help(item.title).accessibilityLabel(item.title)
    }
    private func help(_ item: ChatActionMenuItem) -> String {
        if item.id == "copy", copied { return copiedTitle }
        let detail = item.id == "new-candidate" ? regenerateHelp : item.id == "speak" ? readHelp : ""
        return item.title + (detail.isEmpty ? "" : "\n" + detail) + (item.enabled ? "" : "\n" + (disabledReasons[item.id] ?? ""))
    }
}

/// Main failure and incomplete output are independent of publication failure.
/// Normal completion deliberately contributes no status row.
enum ChatMessageNotices {
    static func keys(attempt: ChatAttempt?, edited: Bool, pendingSave: Bool) -> [String] {
        var result: [String] = []
        if let attempt {
            switch attempt.status {
            case .running: result.append("generating")
            case .saving: break
            case .completed: break
            case .cancelled: result.append("stopped")
            case .partial, .interrupted: result.append("partial")
            case .failed: result.append("failed")
            }
            if attempt.response?.finishReason == .length { result.append("length") }
            if attempt.response?.finishReason == .incomplete, !result.contains("partial") { result.append("partial") }
            let presentation = ChatChannelPresentation(attempt)
            if !edited, presentation.isUnseparatedRaw { result.append(attempt.status == .running ? "preview" : "unparsed") }
            if !edited, !presentation.isUnseparatedRaw, presentation.text.isEmpty { result.append("emptyBody") }
            if presentation.formatReport?.status == .invalid { result.append("invalidFormat") }
            if !(attempt.response?.toolCalls.isEmpty ?? true) { result.append("toolsUnexecuted") }
            if pendingSave || attempt.status == .saving { result.append("notSaved") }
        }
        if edited { result.append("edited") }
        return result
    }
}

struct ChatMessageNoticeView: View {
    let attempt: ChatAttempt?
    let keys: [String]
    let openDetails: @MainActor () -> Void
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        if !keys.isEmpty || attempt?.issue != nil {
            VStack(alignment: .leading, spacing: 2) {
                let summary = keys.map { workflowText(language, "chat.clarity." + $0) }.joined(separator: " · ")
                if let issue = attempt?.issue {
                    (Text(summary + (summary.isEmpty ? "" : " · ")) + Text(WorkbenchOwnedIssue.summary(issue, language: language) ?? ChatErrorText.display(issue, language: language)))
                        .lineLimit(2).foregroundStyle(.red)
                } else { Text(summary).lineLimit(2).foregroundStyle(.secondary) }
                if attempt != nil {
                    Button(workflowText(language, "chat.clarity.details"), action: openDetails)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.font(.system(size: 12)).textSelection(.enabled)
        }
    }
}

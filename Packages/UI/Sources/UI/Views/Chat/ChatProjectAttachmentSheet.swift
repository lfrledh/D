import DWorkbench
import SwiftUI

/// Selection uses the same published versions as Canvas. Browsing does not pin,
/// import, hash, or mutate assets; adoption uses the existing verified attachment API.
struct ChatProjectAttachmentChoice: Identifiable {
    let name: String
    let reference: WorkflowAssetReference
    let instanceID: UUID
    var id: UUID { reference.assetID }

    static func load(from store: ProjectStore) async throws -> [Self] {
        let manifest = await store.snapshot()
        let state = try await store.workflowState()
        guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "Project assets unavailable / 项目素材不可读") }
        return manifest.assets.compactMap { asset in
            guard let record = archive.assets.first(where: { $0.reference.assetID == asset.id }),
                  [.text, .image, .video, .document].contains(record.reference.kind) else { return nil }
            return Self(name: asset.name, reference: record.reference, instanceID: manifest.effectiveInstanceID)
        }
    }

    @MainActor func adopt(in chat: ChatController, sessionID: UUID, from source: ProjectStore? = nil) async throws {
        let activity = try chat.beginExternalActivity()
        defer { chat.endExternalActivity(activity) }
        let source = source ?? chat.store
        let manifest = await source.snapshot()
        guard manifest.effectiveInstanceID == instanceID, manifest.id == reference.projectID,
              chat.state.selectedSessionID == sessionID else {
            throw WorkflowIssue("Return to the original conversation and project. / 请返回原会话与项目后选择。")
        }
        try Task.checkCancellation()
        _ = try await chat.addSharedAttachment(reference, from: source, name: name, sessionID: sessionID)
    }
}

/// The library sheet cannot require a drop onto the inactive window behind it.
/// This explicit adoption uses the same authorized Store and attachment boundary.
struct ChatLibraryAttachmentButton: View {
    let chat: ChatController
    let sessionID: UUID
    let source: ProjectStore
    let choice: ChatProjectAttachmentChoice
    let isCurrent: () -> Bool
    let wording: (String, String) -> String
    let onAdopted: () -> Void
    @State private var task: Task<Void, Never>?
    @State private var issue: String?

    var body: some View {
        VStack {
            Button(wording("Add to current chat draft", "加入当前聊天草稿")) {
                guard task == nil else { return }
                task = Task { @MainActor in
                    defer { task = nil }
                    do {
                        guard isCurrent() else { throw WorkflowIssue("Return to the original conversation. / 请返回原会话。") }
                        try await choice.adopt(in: chat, sessionID: sessionID, from: source)
                        try Task.checkCancellation()
                        onAdopted()
                    } catch is CancellationError {} catch { issue = error.localizedDescription }
                }
            }.disabled(task != nil).accessibilityIdentifier("library-asset-to-chat")
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
        }.onDisappear { task?.cancel() }
    }
}

struct ChatProjectAttachmentSheet: View {
    let chat: ChatController
    let sessionID: UUID
    let wording: (String, String) -> String
    let close: () -> Void
    @State private var choices: [ChatProjectAttachmentChoice] = []
    @State private var selected: UUID?
    @State private var loaded = false
    @State private var issue: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(wording("Project assets", "本项目成果与素材")).font(.headline)
                Spacer()
                Button(wording("Close", "关闭")) { task?.cancel(); close() }.keyboardShortcut(.cancelAction)
            }
            Text(wording("Choose a published text, image, video, or document version. It becomes a pending attachment; nothing is sent. Audio needs transcription first.",
                         "选择已入库的文字、图像、视频或文档版本。只加入待发送附件，不自动发送；音频请先转写。"))
                .font(.caption).foregroundStyle(.secondary)
            if !loaded { ProgressView() }
            else if choices.isEmpty { Text(wording("No supported published assets in this project.", "本项目暂无可选择的已入库素材。")) }
            List(choices, selection: $selected) { choice in
                VStack(alignment: .leading) {
                    Text(choice.name)
                    Text("\(choice.reference.kind.rawValue) · \(choice.reference.version.uuidString.prefix(8))")
                        .font(.caption).foregroundStyle(.secondary)
                }.tag(choice.id)
            }.accessibilityIdentifier("chat-project-attachments")
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            Button(wording("Add to draft", "加入待发送附件")) {
                guard task == nil, let choice = choices.first(where: { $0.id == selected }) else { return }
                task = Task { @MainActor in
                    defer { task = nil }
                    do {
                        try await choice.adopt(in: chat, sessionID: sessionID)
                        try Task.checkCancellation()
                        close()
                    }
                    catch is CancellationError {} catch { issue = error.localizedDescription }
                }
            }.disabled(task != nil || selected == nil)
                .accessibilityIdentifier("chat-project-attachment-add")
        }.padding(20).frame(minWidth: 560, minHeight: 360)
            .task {
                do { choices = try await ChatProjectAttachmentChoice.load(from: chat.store) }
                catch { issue = error.localizedDescription }
                loaded = true
            }
            .onDisappear { task?.cancel() }
    }
}

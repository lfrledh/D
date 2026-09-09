import Foundation
import Observation

/// A verified, read-only view of one registered original and its persisted draft.
public struct ProjectAudioInspection: Sendable {
    public let document: AudioDraftDocument
    public let asset: ProjectAsset
    public let url: URL
    public let metadata: AudioAssetMetadata
    public let waveform: [AudioPeak]

    public init(document: AudioDraftDocument, asset: ProjectAsset, url: URL,
                metadata: AudioAssetMetadata, waveform: [AudioPeak]) {
        self.document = document
        self.asset = asset
        self.url = url
        self.metadata = metadata
        self.waveform = waveform
    }
}

/// Owns the audio state for exactly one open-project context. Views never write the store.
@MainActor @Observable
public final class ProjectAudioController {
    public let contextID: UUID
    public let transport: AudioTransport
    public private(set) var document: AudioDraftDocument?
    public private(set) var inspection: ProjectAudioInspection?
    public private(set) var pendingCaptures: [AudioCaptureReservation] = []
    public private(set) var isInspecting = false
    public private(set) var isSaving = false
    public private(set) var isFinalizing = false
    public private(set) var errorMessage: String?

    /// Editor-owned input. These values are intentionally separate from the persisted draft.
    public private(set) var noteInput = ""
    public private(set) var clipNameInput = ""
    public private(set) var clipNoteInput = ""
    public private(set) var clipRangeInput: AudioFrameRange?

    public var waveform: [AudioPeak] { inspection?.waveform ?? [] }
    public var metadata: AudioAssetMetadata? { inspection?.metadata }
    public var documentID: UUID? { document?.id }
    public var isBusy: Bool {
        isSaving || isInspecting || (isStartingRecording && !permissionRequestDetached) || isFinalizing
            || transport.state == .requestingPermission || transport.state == .recording
    }
    public var hasUnsubmittedInput: Bool {
        guard let document else { return false }
        return !sameUTF8(noteInput, document.note) || !clipNameInput.isEmpty
            || !clipNoteInput.isEmpty || clipRangeInput != nil
    }
    public var isDirty: Bool { hasUnsubmittedInput || isSaving }
    public var navigationBlockMessage: String? {
        if hasUnsubmittedInput {
            return "原声备注或片段输入尚未提交。请保存，或明确放弃这些输入后再切换。"
        }
        if captureFailureBlocksNavigation {
            return "录音文件仍处于待恢复状态。请重试恢复，或明确选择保留待恢复文件后再关闭。"
        }
        return nil
    }

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let recordingEnabled: Bool
    @ObservationIgnored private let publish: @MainActor (ProjectManifest) -> Void
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    @ObservationIgnored private var finalizeTask: Task<Bool, Never>?
    @ObservationIgnored private var finalizeToken: UUID?
    @ObservationIgnored private var finalizingCaptureID: UUID?
    @ObservationIgnored private var activeCaptureID: UUID?
    @ObservationIgnored private var activeCaptureURL: URL?
    @ObservationIgnored private var captureGeneration: UInt64 = 0
    @ObservationIgnored private var editorGeneration: UInt64 = 0
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var captureFailureBlocksNavigation = false
    @ObservationIgnored private var isStartingRecording = false
    @ObservationIgnored private var permissionRequestDetached = false
    @ObservationIgnored private var admissionsOpen = true
    @ObservationIgnored private var navigationPreparing = false

    init(contextID: UUID = UUID(), store: ProjectStore, transport: AudioTransport,
         recordingEnabled: Bool,
         publish: @escaping @MainActor (ProjectManifest) -> Void) {
        self.contextID = contextID
        self.store = store
        self.transport = transport
        self.recordingEnabled = recordingEnabled
        self.publish = publish
        transport.recordingDidFinish = { [weak self] url, error in
            self?.recordingFinished(url: url, error: error)
        }
    }

    /// Synchronizes persisted state without overwriting newer editor input for the same document.
    func synchronize(_ manifest: ProjectManifest) {
        pendingCaptures = manifest.pendingAudioCaptures
        let next = manifest.activeDocument?.kind == .audio ? manifest.activeDocument?.audioDraft : nil
        if next?.id != document?.id {
            transport.stopPlayback()
            document = next
            inspection = nil
            noteInput = next?.note ?? ""
            clipNameInput = ""
            clipNoteInput = ""
            clipRangeInput = nil
            editorGeneration &+= 1
        } else if let next {
            document = next
        }
    }

    func resumeAdmissions() {
        if isActive, !navigationPreparing { admissionsOpen = true }
    }

    public func clearError() { errorMessage = nil }

    /// UI binding entry point. Identity makes a stale view unable to edit a replacement document.
    @discardableResult
    public func setNoteInput(_ value: String, contextID: UUID, documentID: UUID) -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else { return false }
        noteInput = value
        editorGeneration &+= 1
        errorMessage = nil
        return true
    }

    /// UI binding entry point for a not-yet-submitted clip.
    @discardableResult
    public func setClipInput(name: String, range: AudioFrameRange?, note: String = "",
                             contextID: UUID, documentID: UUID) -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else { return false }
        clipNameInput = name
        clipRangeInput = range
        clipNoteInput = note
        editorGeneration &+= 1
        errorMessage = nil
        return true
    }

    /// Explicitly discards only editor input; persisted media, drafts and captures are untouched.
    @discardableResult
    public func discardUnsubmittedInput(contextID: UUID, documentID: UUID) -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID), let document else { return false }
        noteInput = document.note
        clipNameInput = ""
        clipNoteInput = ""
        clipRangeInput = nil
        editorGeneration &+= 1
        errorMessage = nil
        return true
    }

    public func saveNote(contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else {
            rejectStaleEditor(); return false
        }
        let snapshot = noteInput
        let generation = editorGeneration
        return await enqueue(.note(snapshot), contextID: contextID, documentID: documentID,
                             editorGeneration: generation)
    }

    public func addClip(contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID),
              let range = clipRangeInput else {
            errorMessage = "片段范围尚未设置，原声稿没有改变。"
            return false
        }
        let clip = AudioClip(name: clipNameInput, range: range, note: clipNoteInput)
        let generation = editorGeneration
        return await enqueue(.addClip(clip), contextID: contextID, documentID: documentID,
                             editorGeneration: generation)
    }

    public func selectFullAudio(contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else {
            rejectStaleEditor(); return false
        }
        guard await enqueue(.selection(nil), contextID: contextID, documentID: documentID,
                            editorGeneration: nil) else { return false }
        return await prepareSelectedPlayback(contextID: contextID, documentID: documentID)
    }

    public func selectClip(id: UUID, contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID),
              document?.clips.contains(where: { $0.id == id }) == true else {
            errorMessage = "找不到要选择的已保存片段。"
            return false
        }
        guard await enqueue(.selection(id), contextID: contextID, documentID: documentID,
                            editorGeneration: nil) else { return false }
        return await prepareSelectedPlayback(contextID: contextID, documentID: documentID)
    }

    public func refreshInspection(contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID), !isInspecting else {
            return false
        }
        isInspecting = true
        defer { isInspecting = false }
        do {
            let value = try await store.inspectAudio(documentID: documentID)
            guard matches(contextID: contextID, documentID: documentID),
                  value.document == document else { return false }
            inspection = value
            guard preparePlayback(value, range: selectedRange(in: value.document)) else { return false }
            errorMessage = nil
            return true
        } catch {
            report(error, context: "原声音频检查失败；原件和草稿均未改变")
            return false
        }
    }

    public func exportOriginal(to destination: URL, contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID), let assetID = document?.assetID else {
            rejectStaleEditor(); return false
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await store.export(assetID: assetID, to: destination)
            guard matches(contextID: contextID, documentID: documentID) else { return false }
            errorMessage = nil
            return true
        } catch {
            report(error, context: "原声原件导出失败；请选择新的目标文件")
            return false
        }
    }

    public func exportClip(id: UUID, to destination: URL,
                           contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID),
              let range = document?.clips.first(where: { $0.id == id })?.range else {
            errorMessage = "找不到要导出的已保存片段。"
            return false
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await store.exportAudioClip(documentID: documentID, range: range, to: destination)
            guard matches(contextID: contextID, documentID: documentID) else { return false }
            errorMessage = nil
            return true
        } catch {
            report(error, context: "原声片段导出失败；请选择新的目标文件")
            return false
        }
    }

    /// Exports an explicit half-open original-frame range without changing saved selection.
    public func exportRange(_ range: AudioFrameRange, to destination: URL,
                            contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else {
            rejectStaleEditor(); return false
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await store.exportAudioClip(documentID: documentID, range: range, to: destination)
            guard matches(contextID: contextID, documentID: documentID) else { return false }
            errorMessage = nil
            return true
        } catch {
            report(error, context: "原声范围导出失败；已保存选区没有改变")
            return false
        }
    }

    /// Re-validates and prepares an explicit range for playback, without autoplay or persistence.
    public func preparePlayback(range: AudioFrameRange? = nil,
                                contextID: UUID, documentID: UUID) async -> Bool {
        guard admissionsOpen, matches(contextID: contextID, documentID: documentID) else {
            rejectStaleEditor(); return false
        }
        if inspection?.document.id != documentID {
            guard await refreshInspection(contextID: contextID, documentID: documentID) else { return false }
        }
        guard let inspection else { return false }
        return preparePlayback(inspection, range: range ?? selectedRange(in: document))
    }

    public func startRecording(name: String) async -> Bool {
        guard admissionsOpen, recordingEnabled else {
            report(AudioMediaError.unavailable("当前项目会话未启用录音能力"), context: "无法开始录音")
            return false
        }
        guard isActive, !isStartingRecording, activeCaptureID == nil, finalizeTask == nil,
              transport.state != .requestingPermission, transport.state != .recording else {
            errorMessage = "已有录音或最终化操作正在进行。"
            return false
        }
        captureGeneration &+= 1
        let admissionGeneration = captureGeneration
        isStartingRecording = true
        permissionRequestDetached = false
        defer { isStartingRecording = false; permissionRequestDetached = false }
        transport.stopPlayback()
        do {
            // The reservation is durable before a permission request can suspend.
            let reservation = try await store.reserveAudioCapture(name: name)
            let reservedManifest = await store.snapshot()
            pendingCaptures = reservedManifest.pendingAudioCaptures
            publish(reservedManifest)
            guard isActive, admissionGeneration == captureGeneration else { return false }
            let url = try await store.audioCaptureURL(id: reservation.id)
            let generation = captureGeneration
            activeCaptureID = reservation.id
            activeCaptureURL = url
            captureFailureBlocksNavigation = false
            errorMessage = nil
            try await transport.requestAndStartRecording(to: url)
            guard isActive, generation == captureGeneration else { return false }
            return transport.state == .recording || finalizingCaptureID == reservation.id
        } catch is CancellationError {
            errorMessage = "录音许可请求已取消；预约已保留，可稍后恢复。"
            return false
        } catch {
            report(error, context: "录音未能开始；已登记的预约将保留供恢复")
            if transport.state == .failed { captureFailureBlocksNavigation = true }
            return false
        }
    }

    public func finishRecording() async -> Bool {
        guard isActive else { return false }
        do {
            let wasRequestingPermission = transport.state == .requestingPermission
            _ = try transport.finishRecording()
            if wasRequestingPermission { permissionRequestDetached = true }
        } catch {
            report(error, context: "录音设备已停止，但文件需要稍后恢复")
            captureFailureBlocksNavigation = true
        }
        guard let task = finalizeTask else {
            if transport.state == .idle, activeCaptureID != nil {
                // Permission was cancelled before a device started. Keep the durable reservation.
                captureGeneration &+= 1
                activeCaptureID = nil
                activeCaptureURL = nil
                return true
            }
            return activeCaptureID == nil && !captureFailureBlocksNavigation
        }
        return await awaitFinalize(task)
    }

    public func retryPendingCapture(id: UUID) async -> Bool {
        guard isActive, pendingCaptures.contains(where: { $0.id == id }), finalizeTask == nil,
              transport.state != .recording, transport.state != .requestingPermission else {
            errorMessage = "找不到可恢复的录音预约，或另一音频操作尚未结束。"
            return false
        }
        return await awaitFinalize(scheduleFinalize(id: id, expectedURL: nil))
    }

    /// Allows close while retaining the registered reservation and raw bytes for later recovery.
    @discardableResult
    public func keepPendingCaptureForRecovery(id: UUID) -> Bool {
        guard admissionsOpen, pendingCaptures.contains(where: { $0.id == id }),
              finalizingCaptureID == nil, transport.state != .recording,
              transport.state != .requestingPermission else { return false }
        captureGeneration &+= 1
        activeCaptureID = nil
        activeCaptureURL = nil
        captureFailureBlocksNavigation = false
        errorMessage = nil
        return true
    }

    /// Called before generic inference draining so a recording never makes close wait on itself.
    func prepareForNavigation() async -> Bool {
        guard isActive else { return true }
        if let message = navigationBlockMessage {
            errorMessage = message
            return false
        }
        admissionsOpen = false
        navigationPreparing = true
        defer { navigationPreparing = false }
        transport.stopPlayback()
        // Wait only for reservation persistence, never for a suspended system permission dialog.
        while isStartingRecording && !permissionRequestDetached
                && transport.state != .requestingPermission {
            await Task.yield()
        }
        if transport.state == .requestingPermission || transport.state == .recording {
            guard await finishRecording() else { admissionsOpen = true; return false }
        }
        if let task = finalizeTask, !(await awaitFinalize(task)) { admissionsOpen = true; return false }
        await writeTail?.value
        if let message = navigationBlockMessage {
            errorMessage = message
            admissionsOpen = true
            return false
        }
        admissionsOpen = false
        return true
    }

    /// Drains already admitted draft writes without changing playback or admission state.
    func flushPendingWrites() async -> Bool {
        await writeTail?.value
        if hasUnsubmittedInput {
            errorMessage = navigationBlockMessage
            return false
        }
        return true
    }

    func deactivateAfterClose() {
        isActive = false
        admissionsOpen = false
        captureGeneration &+= 1
        transport.shutdown()
        transport.recordingDidFinish = nil
    }

    private enum DraftMutation {
        case note(String)
        case addClip(AudioClip)
        case selection(UUID?)
    }

    private func enqueue(_ mutation: DraftMutation, contextID: UUID, documentID: UUID,
                         editorGeneration acknowledgedGeneration: UInt64?) async -> Bool {
        let preceding = writeTail
        let task = Task { @MainActor [weak self] () -> Bool in
            if let preceding { await preceding.value }
            guard let self else { return false }
            return await self.perform(mutation, contextID: contextID, documentID: documentID,
                                      acknowledgedGeneration: acknowledgedGeneration)
        }
        writeTail = Task { _ = await task.value }
        return await task.value
    }

    private func perform(_ mutation: DraftMutation, contextID: UUID, documentID: UUID,
                         acknowledgedGeneration: UInt64?) async -> Bool {
        guard matches(contextID: contextID, documentID: documentID), var next = document else {
            rejectStaleEditor(); return false
        }
        let expectedRevision = next.revision
        switch mutation {
        case .note(let note):
            next.note = note
        case .addClip(let clip):
            next.clips.append(clip)
        case .selection(let id):
            next.selectedClipID = id
        }
        let changed: Bool
        switch mutation {
        case .note(let note):
            changed = !sameUTF8(note, document?.note ?? "")
        case .addClip:
            changed = true
        case .selection(let id):
            changed = id != document?.selectedClipID
        }
        if !changed { return true }
        guard expectedRevision < UInt64.max else {
            report(ProjectStoreError.invalidProject("原声稿修订编号已耗尽。"), context: "原声稿未保存")
            return false
        }
        next.revision = expectedRevision + 1
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.saveAudioDraft(next, documentID: documentID,
                                                         expectedRevision: expectedRevision)
            guard matches(contextID: contextID, documentID: documentID),
                  let saved = updated.documents.first(where: { $0.id == documentID })?.audioDraft,
                  saved == next else { return false }
            document = saved
            publish(updated)
            if case .addClip = mutation, acknowledgedGeneration == editorGeneration {
                clipNameInput = ""
                clipNoteInput = ""
                clipRangeInput = nil
                editorGeneration &+= 1
            }
            errorMessage = nil
            return true
        } catch {
            report(error, context: "原声稿尚未保存；输入仍保留在当前窗口")
            return false
        }
    }

    private func prepareSelectedPlayback(contextID: UUID, documentID: UUID) async -> Bool {
        guard matches(contextID: contextID, documentID: documentID), let document else { return false }
        if inspection?.document.id != documentID || inspection?.document.revision != document.revision {
            guard await refreshInspection(contextID: contextID, documentID: documentID) else { return false }
        }
        guard let inspection else { return false }
        return preparePlayback(inspection, range: selectedRange(in: document))
    }

    private func recordingFinished(url: URL, error: String?) {
        guard isActive, let id = activeCaptureID, let expected = activeCaptureURL,
              url.standardizedFileURL == expected.standardizedFileURL else { return }
        if let error {
            errorMessage = "录音设备已关闭，预约和原始文件已保留：\(error)"
            captureFailureBlocksNavigation = true
            return
        }
        _ = scheduleFinalize(id: id, expectedURL: expected)
    }

    @discardableResult
    private func scheduleFinalize(id: UUID, expectedURL: URL?) -> Task<Bool, Never> {
        if finalizingCaptureID == id, let finalizeTask { return finalizeTask }
        let token = UUID()
        finalizingCaptureID = id
        finalizeToken = token
        isFinalizing = true
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer {
                if self.finalizeToken == token {
                    self.finalizeTask = nil
                    self.finalizeToken = nil
                    self.finalizingCaptureID = nil
                    self.isFinalizing = false
                }
            }
            if let expectedURL, self.activeCaptureURL?.standardizedFileURL != expectedURL.standardizedFileURL {
                return false
            }
            do {
                let updated = try await self.store.finalizeAudioCapture(id: id)
                guard self.isActive, self.finalizeToken == token else { return false }
                self.publish(updated)
                self.pendingCaptures = updated.pendingAudioCaptures
                self.activeCaptureID = nil
                self.activeCaptureURL = nil
                self.captureFailureBlocksNavigation = false
                self.synchronize(updated)
                if let documentID = self.document?.id {
                    _ = await self.refreshInspection(contextID: self.contextID, documentID: documentID)
                }
                self.errorMessage = nil
                return true
            } catch {
                guard self.isActive, self.finalizeToken == token else { return false }
                self.report(error, context: "录音最终化失败；预约和原始文件均已保留，可显式重试")
                self.captureFailureBlocksNavigation = true
                return false
            }
        }
        finalizeTask = task
        return task
    }

    private func awaitFinalize(_ task: Task<Bool, Never>) async -> Bool {
        let token = finalizeToken
        let result = await task.value
        if finalizeToken == token {
            finalizeTask = nil
            finalizeToken = nil
            finalizingCaptureID = nil
        }
        return result
    }

    private func matches(contextID: UUID, documentID: UUID) -> Bool {
        isActive && self.contextID == contextID && document?.id == documentID
    }

    private func rejectStaleEditor() {
        errorMessage = "原声编辑器所属的项目或文档已改变；未对当前文档执行操作。"
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
        transport.present(error)
    }

    private func selectedRange(in document: AudioDraftDocument?) -> AudioFrameRange? {
        guard let document, let selected = document.selectedClipID else { return nil }
        return document.clips.first(where: { $0.id == selected })?.range
    }

    @discardableResult
    private func preparePlayback(_ inspection: ProjectAudioInspection,
                                 range: AudioFrameRange?) -> Bool {
        do {
            try transport.preparePlayback(url: inspection.url,
                                          format: inspection.metadata.format,
                                          range: range)
            return true
        } catch {
            report(error, context: "原声已检查，但无法准备播放")
            return false
        }
    }

    private func sameUTF8(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

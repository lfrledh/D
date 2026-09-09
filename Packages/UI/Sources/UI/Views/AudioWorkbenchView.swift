import DWorkbench
import Foundation
import SwiftUI

/// Stateless callbacks retained for previews and the accepted component tests. Production uses
/// `AudioWorkbenchProductionActions` and controller-owned editor input below.
public struct AudioWorkbenchActions {
    public var importOriginal: () -> Void
    public var startRecording: () -> Void
    public var finishRecording: () -> Void
    public var saveNote: (UUID, String) -> Void
    public var selectClip: (UUID?) -> Void
    public var addClip: (AudioFrameRange, String) -> Void
    public var exportOriginal: () -> Void
    public var exportRange: (AudioFrameRange) -> Void

    public init(importOriginal: @escaping () -> Void, startRecording: @escaping () -> Void,
                finishRecording: @escaping () -> Void, saveNote: @escaping (UUID, String) -> Void,
                selectClip: @escaping (UUID?) -> Void,
                addClip: @escaping (AudioFrameRange, String) -> Void,
                exportOriginal: @escaping () -> Void,
                exportRange: @escaping (AudioFrameRange) -> Void) {
        self.importOriginal = importOriginal
        self.startRecording = startRecording
        self.finishRecording = finishRecording
        self.saveNote = saveNote
        self.selectClip = selectClip
        self.addClip = addClip
        self.exportOriginal = exportOriginal
        self.exportRange = exportRange
    }
}

@MainActor
enum AudioWorkbenchButtonHandler {
    @discardableResult
    static func saveNote(documentID: UUID, editingDocumentID: UUID?, note: String,
                         actions: AudioWorkbenchActions,
                         reject: (AudioMediaError) -> Void) -> Bool {
        guard editingDocumentID == documentID else { return false }
        guard note.utf8.count <= AudioLimits.maximumNoteBytes else {
            reject(.limitExceeded)
            return false
        }
        actions.saveNote(documentID, note)
        return true
    }

    @discardableResult
    static func addClip(documentID: UUID, editingDocumentID: UUID?, existingClipCount: Int,
                        name: String, range: () -> AudioFrameRange?,
                        actions: AudioWorkbenchActions,
                        reject: (AudioMediaError) -> Void) -> Bool {
        guard editingDocumentID == documentID else { return false }
        guard !name.isEmpty, name.utf8.count <= AudioLimits.maximumNameBytes,
              existingClipCount < AudioLimits.maximumClips else {
            reject(.limitExceeded)
            return false
        }
        guard let range = range() else { return false }
        actions.addClip(range, name)
        return true
    }
}

public struct AudioWorkbenchView: View {
    private let previewDocument: AudioDraftDocument?
    private let previewMetadata: AudioAssetMetadata?
    private let previewWaveform: [AudioPeak]
    private let controller: ProjectAudioController?
    private let legacyActions: AudioWorkbenchActions?
    private let productionActions: AudioWorkbenchProductionActions?
    private let recordingEnabled: Bool
    private let navigationInProgress: Bool
    @Bindable public var transport: AudioTransport

    @State private var previewNote = ""
    @State private var previewClipName = ""
    @State private var startFrame: Int64 = 0
    @State private var endFrame: Int64 = 0
    @State private var editingDocumentID: UUID?
    @State private var rangeInitializedDocumentID: UUID?
    @State private var refreshRequestedDocumentID: UUID?
    @State private var preparedRange: AudioFrameRange?
    @State private var actionStatus: String?
    private var layoutProbe: ((String, CGRect) -> Void)?

    private var document: AudioDraftDocument? { controller?.document ?? previewDocument }
    private var metadata: AudioAssetMetadata? { controller?.metadata ?? previewMetadata }
    private var waveform: [AudioPeak] { controller?.waveform ?? previewWaveform }
    private var canEdit: Bool { controller?.canEdit ?? true }

    public init(document: AudioDraftDocument?, metadata: AudioAssetMetadata?, waveform: [AudioPeak],
                transport: AudioTransport, actions: AudioWorkbenchActions) {
        previewDocument = document
        previewMetadata = metadata
        previewWaveform = waveform
        controller = nil
        legacyActions = actions
        productionActions = nil
        recordingEnabled = true
        navigationInProgress = false
        self.transport = transport
    }

    public init(controller: ProjectAudioController, recordingEnabled: Bool,
                navigationInProgress: Bool = false,
                actions: AudioWorkbenchProductionActions) {
        previewDocument = nil
        previewMetadata = nil
        previewWaveform = []
        self.controller = controller
        legacyActions = nil
        productionActions = actions
        self.recordingEnabled = recordingEnabled
        self.navigationInProgress = navigationInProgress
        transport = controller.transport
    }

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        Group {
            if let document, let metadata {
                editor(document: document, metadata: metadata)
            } else {
                emptyState
            }
        }
        .padding(20)
        .coordinateSpace(name: "audio-workbench-layout")
        .onChange(of: document?.id) { _, id in
            load(documentID: id)
            refreshInspectionIfNeeded()
        }
        .onChange(of: metadata?.contentSHA256) { _, _ in initializeRangeIfAvailable() }
        .onChange(of: navigationInProgress) { wasInProgress, isInProgress in
            if wasInProgress && !isInProgress { refreshInspectionIfNeeded() }
        }
        .onAppear {
            load(documentID: document?.id)
            refreshInspectionIfNeeded()
        }
        .accessibilityIdentifier("audio-workbench")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(document == nil ? "尚未添加音频" : "原声暂时无法读取",
                  systemImage: document == nil ? "waveform" : "waveform.badge.exclamationmark")
        } description: {
            Text(document == nil
                 ? "导入一个原始 WAV/CAF PCM。原件会保留不变。"
                 : "已登记的原声仍在项目中。请重新读取；失败时原件和输入都不会改变。")
        } actions: {
            VStack(spacing: 8) {
                if document == nil {
                    Button("导入音频…", action: importOriginal)
                        .accessibilityIdentifier("audio-import")
                } else {
                    Button("重新读取原声", action: refreshInspection)
                        .accessibilityIdentifier("audio-refresh")
                }
                recordingControl
                if !recordingEnabled && !isRecordingOrRequesting {
                    Text("麦克风录音尚未启用；录音保持关闭，也不会请求系统许可。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                captureRecovery
                statusLabel
            }
        }
    }

    private func editor(document: AudioDraftDocument, metadata: AudioAssetMetadata) -> some View {
        let format = metadata.format
        return GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(format: format)
                    let layout = viewport.size.width >= 720
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    layout {
                        media(format: format).frame(maxWidth: .infinity).frame(height: 260)
                        details(document: document, format: format)
                    }
                    captureRecovery
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("audio-editor-scroll")
        }
    }

    private func header(format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("原始音频").font(.title2.weight(.semibold))
                Text("原件保持不变；片段只记录起止位置。\(format.channelCount) 声道 · \(Int(format.sampleRate)) Hz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 210), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                Button("导出原件", systemImage: "square.and.arrow.up", action: exportOriginal)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("audio-export-original")
                    .audioMeasured("audio-export-original", probe: layoutProbe)
                recordingControl.buttonStyle(.glass)
            }
            if !recordingEnabled && !isRecordingOrRequesting {
                Text("麦克风录音尚未启用；录音保持关闭，也不会请求系统许可。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller?.errorMessage != nil {
                Button("重新读取原声", action: refreshInspection)
                    .accessibilityIdentifier("audio-refresh")
            }
        }
        .accessibilityIdentifier("audio-header")
    }

    @ViewBuilder private var recordingControl: some View {
        if isRecordingOrRequesting {
            Button(transport.state == .recording ? "结束录音" : "取消等待",
                   systemImage: "stop.fill", action: finishRecording)
                .accessibilityIdentifier("audio-record-finish")
                .audioMeasured("audio-record-finish", probe: layoutProbe)
        } else {
            Button("开始录音", systemImage: "mic.fill", action: startRecording)
                .disabled(!recordingEnabled)
                .accessibilityIdentifier("audio-record-start")
                .audioMeasured("audio-record-start", probe: layoutProbe)
        }
    }

    private var isRecordingOrRequesting: Bool {
        transport.state == .recording || transport.state == .requestingPermission
    }

    private func media(format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformView(peaks: waveform, position: transport.positionFrame,
                         frameCount: format.frameCount) { frame in
                do { try transport.seek(toFrame: frame) }
                catch { transport.present(error) }
            }
            .frame(minHeight: 180)
            .accessibilityIdentifier("audio-waveform")
            HStack {
                Button(transport.state == .playing ? "暂停" : "播放",
                       systemImage: transport.state == .playing ? "pause.fill" : "play.fill") {
                    if transport.state == .playing {
                        transport.pause()
                    } else {
                        do { try transport.play() }
                        catch { transport.present(error) }
                    }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("audio-play-pause")
                Text(time(transport.positionFrame, format: format)).monospacedDigit()
                Spacer()
                statusLabel
            }
            if let preparedRange {
                Text("已准备试听：\(time(preparedRange.startFrame, format: format)) – \(time(preparedRange.endFrame, format: format))")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio-prepared-range")
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func details(document: AudioDraftDocument, format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("注释与片段").font(.headline)
            TextField("原始媒体注释", text: noteBinding(document), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disabled(!canEdit)
                .accessibilityIdentifier("audio-note")
                .audioMeasured("audio-note", probe: layoutProbe)
            Button(controller?.isSaving == true ? "正在保存…" : "保存注释") {
                saveNote(document)
            }
            .disabled(!canEdit || controller?.isSaving == true)
            .accessibilityIdentifier("audio-save-note")
            Divider()
            HStack {
                TextField("片段名称", text: clipNameBinding(document))
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-clip-name")
                Button("添加片段") { addClip(document, format: format) }
                    .disabled(!canEdit || document.clips.count >= AudioLimits.maximumClips)
                    .accessibilityIdentifier("audio-add-clip")
                    .audioMeasured("audio-add-clip", probe: layoutProbe)
            }
            rangeEditors(document: document, format: format)
            HStack {
                Button("完整音频") {
                    select(Optional<AudioClip>.none, document: document, format: format)
                }
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-select-full")
                    .accessibilityAddTraits(document.selectedClipID == nil ? .isSelected : [])
                Button("试听当前范围") { auditionCurrentRange(document: document, format: format) }
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-audition-range")
                Button("导出编辑范围") { exportCurrentRange(format: format) }
                    .disabled(controller != nil && controller?.clipRangeInput == nil)
                    .accessibilityIdentifier("audio-export-range")
            }
            ForEach(document.clips) { clip in
                HStack {
                    Button(clip.name) { select(clip, document: document, format: format) }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("audio-clip-\(clip.id.uuidString)")
                        .accessibilityAddTraits(document.selectedClipID == clip.id ? .isSelected : [])
                    Spacer()
                    Text("\(time(clip.range.startFrame, format: format)) – \(time(clip.range.endFrame, format: format))")
                        .font(.caption)
                    Button("导出") { export(clip: clip) }
                        .accessibilityIdentifier("audio-export-clip-\(clip.id.uuidString)")
                }
                .audioMeasured("audio-clip-row-\(clip.id.uuidString)", probe: layoutProbe)
            }
            if controller?.hasUnsubmittedInput == true {
                HStack {
                    Text("有尚未提交的原声输入。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("放弃输入", role: .destructive) { discardInput(document, format: format) }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("audio-discard-input")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rangeEditors(document: AudioDraftDocument, format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: startBinding(document: document, format: format),
                    in: Int64(0)...max(Int64(0), format.frameCount - 1), step: 1) {
                Text("开始：\(startFrame) 帧（\(time(startFrame, format: format))）")
                    .monospacedDigit()
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("audio-range-start")
            Stepper(value: endBinding(document: document, format: format),
                    in: min(Int64(1), format.frameCount)...max(Int64(1), format.frameCount), step: 1) {
                Text("结束：\(endFrame) 帧（\(time(endFrame, format: format))）")
                    .monospacedDigit()
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("audio-range-end")
            Text("按原始帧调整，每次一步；范围包含开始帧，不包含结束帧。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var captureRecovery: some View {
        if let controller, !controller.pendingCaptures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("待恢复录音").font(.headline)
                Text("录音保存尚未完成。可重试；也可保留文件供以后恢复。原件不会被删除。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.pendingCaptures) { capture in
                    HStack {
                        Text(capture.name).lineLimit(1)
                        Spacer()
                        Button("重试") {
                            productionActions?.retryCapture(
                                capture.id, controller.contextID, editingDocumentID
                            )
                        }
                            .disabled(controller.isFinalizing || isRecordingOrRequesting)
                        Button("保留待恢复") {
                            productionActions?.keepCapture(
                                capture.id, controller.contextID, editingDocumentID
                            )
                        }
                            .disabled(controller.isFinalizing || isRecordingOrRequesting)
                    }
                    .accessibilityIdentifier("audio-recovery-\(capture.id.uuidString)")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle((controller?.errorMessage ?? transport.errorMessage) == nil ? Color.secondary : Color.red)
            .accessibilityIdentifier("audio-status")
    }

    private func noteBinding(_ document: AudioDraftDocument) -> Binding<String> {
        Binding(get: { controller?.noteInput ?? previewNote }, set: { value in
            if let controller {
                _ = controller.setNoteInput(value, contextID: controller.contextID,
                                            documentID: document.id)
            } else {
                previewNote = value
            }
        })
    }

    private func clipNameBinding(_ document: AudioDraftDocument) -> Binding<String> {
        Binding(get: { controller?.clipNameInput ?? previewClipName }, set: { value in
            if let controller {
                _ = controller.setClipInput(name: value, range: controller.clipRangeInput,
                                            note: controller.clipNoteInput,
                                            contextID: controller.contextID,
                                            documentID: document.id)
            } else {
                previewClipName = value
            }
        })
    }

    private func startBinding(document: AudioDraftDocument,
                              format: AudioFormatInfo) -> Binding<Int64> {
        Binding(get: { startFrame }, set: { proposed in
            let upper = max(Int64(0), format.frameCount - 1)
            startFrame = min(max(0, proposed), upper)
            if endFrame <= startFrame { endFrame = min(format.frameCount, startFrame + 1) }
            publishRangeEdit(document: document, format: format)
        })
    }

    private func endBinding(document: AudioDraftDocument,
                            format: AudioFormatInfo) -> Binding<Int64> {
        Binding(get: { endFrame }, set: { proposed in
            endFrame = min(max(1, proposed), format.frameCount)
            if startFrame >= endFrame { startFrame = max(0, endFrame - 1) }
            publishRangeEdit(document: document, format: format)
        })
    }

    private func publishRangeEdit(document: AudioDraftDocument, format: AudioFormatInfo) {
        guard let controller, editingDocumentID == document.id,
              let range = admittedRange(format: format) else { return }
        _ = controller.setClipInput(name: controller.clipNameInput, range: range,
                                    note: controller.clipNoteInput,
                                    contextID: controller.contextID, documentID: document.id)
    }

    private func saveNote(_ document: AudioDraftDocument) {
        if let legacyActions {
            _ = AudioWorkbenchButtonHandler.saveNote(
                documentID: document.id, editingDocumentID: editingDocumentID,
                note: previewNote, actions: legacyActions,
                reject: { transport.present($0) }
            )
            return
        }
        guard let controller, let productionActions, editingDocumentID == document.id,
              controller.noteInput.utf8.count <= AudioLimits.maximumNoteBytes else {
            transport.present(AudioMediaError.limitExceeded)
            return
        }
        let contextID = controller.contextID
        let editorRevision = controller.editorRevision
        Task {
            let saved = await productionActions.saveNote(contextID, document.id)
            guard matches(controller: controller, contextID: contextID, documentID: document.id),
                  controller.editorRevision == editorRevision else { return }
            actionStatus = saved ? "注释已保存。" : nil
        }
    }

    private func addClip(_ document: AudioDraftDocument, format: AudioFormatInfo) {
        if let legacyActions {
            _ = AudioWorkbenchButtonHandler.addClip(
                documentID: document.id, editingDocumentID: editingDocumentID,
                existingClipCount: document.clips.count, name: previewClipName,
                range: { admittedRange(format: format) }, actions: legacyActions,
                reject: { transport.present($0) }
            )
            return
        }
        guard let controller, let productionActions, editingDocumentID == document.id,
              !controller.clipNameInput.isEmpty,
              controller.clipNameInput.utf8.count <= AudioLimits.maximumNameBytes,
              document.clips.count < AudioLimits.maximumClips,
              let range = admittedRange(format: format), controller.clipRangeInput == range else {
            transport.present(AudioMediaError.invalidRange)
            return
        }
        let contextID = controller.contextID
        let editorRevision = controller.editorRevision
        Task {
            let saved = await productionActions.addClip(contextID, document.id)
            guard matches(controller: controller, contextID: contextID, documentID: document.id) else { return }
            let acknowledgedOriginalInput = controller.editorRevision == editorRevision + 1
                && controller.clipNameInput.isEmpty && controller.clipRangeInput == nil
            guard controller.editorRevision == editorRevision || acknowledgedOriginalInput else { return }
            actionStatus = saved ? "片段已保存。" : nil
        }
    }

    private func select(_ clip: AudioClip?, document: AudioDraftDocument,
                        format: AudioFormatInfo) {
        if let legacyActions {
            legacyActions.selectClip(clip?.id)
            setDisplayedRange(clip?.range ?? fullRange(format))
            return
        }
        guard let controller, let productionActions else { return }
        let contextID = controller.contextID
        let editorRevision = controller.editorRevision
        let pendingRange = controller.clipRangeInput
        Task {
            guard await productionActions.selectClip(clip?.id, contextID, document.id) else { return }
            guard matches(controller: controller, contextID: contextID, documentID: document.id) else { return }
            let range = clip?.range ?? fullRange(format)
            preparedRange = range
            if pendingRange == nil, controller.editorRevision == editorRevision,
               controller.clipRangeInput == nil {
                setDisplayedRange(range)
            }
        }
    }

    private func select(_ id: UUID?, document: AudioDraftDocument,
                        format: AudioFormatInfo) {
        select(id.flatMap { target in document.clips.first { $0.id == target } },
               document: document, format: format)
    }

    private func auditionCurrentRange(document: AudioDraftDocument, format: AudioFormatInfo) {
        guard let range = admittedRange(format: format) else {
            transport.present(AudioMediaError.invalidRange)
            return
        }
        guard let controller, let productionActions else {
            legacyActions?.selectClip(nil)
            return
        }
        let contextID = controller.contextID
        let editorRevision = controller.editorRevision
        let pendingRange = controller.clipRangeInput
        Task {
            guard await productionActions.prepareRange(range, contextID, document.id) else { return }
            guard matches(controller: controller, contextID: contextID, documentID: document.id),
                  controller.editorRevision == editorRevision,
                  controller.clipRangeInput == pendingRange else { return }
            preparedRange = range
            do { try transport.play() }
            catch { transport.present(error) }
        }
    }

    private func exportCurrentRange(format: AudioFormatInfo) {
        guard let range = admittedRange(format: format) else {
            transport.present(AudioMediaError.invalidRange)
            return
        }
        if let controller, let productionActions {
            guard let documentID = controller.documentID else { return }
            productionActions.exportRange(
                range, controller.editorRevision, controller.contextID, documentID
            )
        } else {
            legacyActions?.exportRange(range)
        }
    }

    private func export(clip: AudioClip) {
        if let productionActions, let controller, let documentID = controller.documentID {
            productionActions.exportSavedClip(clip.id, controller.contextID, documentID)
        }
        else { legacyActions?.exportRange(clip.range) }
    }

    private func discardInput(_ document: AudioDraftDocument, format: AudioFormatInfo) {
        guard let controller, let productionActions,
              productionActions.discardInput(controller.contextID, document.id) else { return }
        setDisplayedRange(selectedRange(document: document, format: format))
        actionStatus = "未提交输入已放弃；原件和已保存内容未改变。"
    }

    private func importOriginal() {
        if let productionActions { productionActions.importOriginal() }
        else { legacyActions?.importOriginal() }
    }

    private func startRecording() {
        if let productionActions { productionActions.startRecording() }
        else { legacyActions?.startRecording() }
    }

    private func finishRecording() {
        if let productionActions { productionActions.finishRecording() }
        else { legacyActions?.finishRecording() }
    }

    private func refreshInspection() {
        refreshRequestedDocumentID = nil
        requestInspectionRefresh(force: true)
    }

    private func refreshInspectionIfNeeded() {
        requestInspectionRefresh(force: false)
    }

    private func requestInspectionRefresh(force: Bool) {
        guard !navigationInProgress, (force || metadata == nil),
              let controller, let productionActions,
              let documentID = controller.documentID,
              refreshRequestedDocumentID != documentID else { return }
        let contextID = controller.contextID
        refreshRequestedDocumentID = documentID
        Task {
            let refreshed = await productionActions.refreshInspection(contextID, documentID)
            guard matches(controller: controller, contextID: contextID, documentID: documentID) else { return }
            refreshRequestedDocumentID = nil
            if refreshed {
                initializeRangeIfAvailable()
                if let document = controller.document, let metadata = controller.metadata {
                    preparedRange = selectedRange(document: document, format: metadata.format)
                }
            }
        }
    }

    private func exportOriginal() {
        if let productionActions, let controller, let documentID = controller.documentID {
            productionActions.exportOriginal(controller.contextID, documentID)
        }
        else { legacyActions?.exportOriginal() }
    }

    private func load(documentID: UUID?) {
        if editingDocumentID != documentID {
            editingDocumentID = documentID
            rangeInitializedDocumentID = nil
            refreshRequestedDocumentID = nil
            previewNote = document?.note ?? ""
            previewClipName = ""
            actionStatus = nil
            startFrame = 0
            endFrame = 0
            preparedRange = nil
        }
        initializeRangeIfAvailable()
    }

    private func initializeRangeIfAvailable() {
        guard let document, let metadata,
              rangeInitializedDocumentID != document.id else { return }
        let range = controller?.clipRangeInput ?? selectedRange(document: document, format: metadata.format)
        setDisplayedRange(range)
        if transportHasPreparedPlayback {
            preparedRange = selectedRange(document: document, format: metadata.format)
        }
        rangeInitializedDocumentID = document.id
    }

    private func matches(controller: ProjectAudioController, contextID: UUID,
                         documentID: UUID) -> Bool {
        self.controller === controller && controller.contextID == contextID
            && controller.documentID == documentID && editingDocumentID == documentID
    }

    private func selectedRange(document: AudioDraftDocument,
                               format: AudioFormatInfo) -> AudioFrameRange {
        document.selectedClipID.flatMap { selected in
            document.clips.first { $0.id == selected }?.range
        } ?? fullRange(format)
    }

    private func fullRange(_ format: AudioFormatInfo) -> AudioFrameRange {
        AudioFrameRange(startFrame: 0, endFrame: format.frameCount)
    }

    private func setDisplayedRange(_ range: AudioFrameRange) {
        startFrame = range.startFrame
        endFrame = range.endFrame
    }

    private func admittedRange(format: AudioFormatInfo) -> AudioFrameRange? {
        guard format.frameCount > 0,
              startFrame >= 0, endFrame <= format.frameCount, startFrame < endFrame else {
            return nil
        }
        return AudioFrameRange(startFrame: startFrame, endFrame: endFrame)
    }

    private var statusText: String {
        if let message = controller?.errorMessage ?? transport.errorMessage ?? actionStatus {
            return message
        }
        return switch transport.state {
        case .requestingPermission: "等待录音许可"
        case .recording: "正在录音"
        case .recorded: "已准备"
        case .playing: "正在播放"
        case .paused: "已暂停"
        case .idle, .failed: ""
        }
    }

    private var transportHasPreparedPlayback: Bool {
        switch transport.state {
        case .recorded, .playing, .paused: true
        case .idle, .requestingPermission, .recording, .failed: false
        }
    }

    private func time(_ frame: Int64, format: AudioFormatInfo) -> String {
        String(format: "%.2fs", Double(frame) / format.sampleRate)
    }
}

private struct WaveformView: View {
    let peaks: [AudioPeak]
    let position: Int64
    let frameCount: Int64
    let seek: (Int64) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let count = max(peaks.count, 1)
                let width = size.width / CGFloat(count)
                for (index, peak) in peaks.enumerated() {
                    let x = (CGFloat(index) + 0.5) * width
                    let top = size.height * (0.5 - CGFloat(peak.maximum) * 0.45)
                    let bottom = size.height * (0.5 - CGFloat(peak.minimum) * 0.45)
                    context.stroke(Path {
                        $0.move(to: CGPoint(x: x, y: top))
                        $0.addLine(to: CGPoint(x: x, y: bottom))
                    }, with: .color(.accentColor), lineWidth: max(1, width * 0.55))
                }
                if frameCount > 0 {
                    let x = size.width * CGFloat(position) / CGFloat(frameCount)
                    context.stroke(Path {
                        $0.move(to: CGPoint(x: x, y: 0))
                        $0.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(.primary), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard frameCount > 0 else { return }
                let availableWidth = max(proxy.size.width, 1)
                let fraction = min(1, max(0, Double(value.location.x / availableWidth)))
                let frame = min(frameCount - 1,
                                max(0, Int64((fraction * Double(frameCount)).rounded(.down))))
                seek(frame)
            })
        }
    }
}

private extension View {
    func audioMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("audio-workbench-layout"))
        } action: { rectangle in
            probe?(id, rectangle)
        }
    }
}

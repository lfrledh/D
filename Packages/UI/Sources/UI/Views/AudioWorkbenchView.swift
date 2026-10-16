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
    @Environment(\.dLanguageStore) private var consistencyLanguage
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
        .audioMeasured("audio-workbench", probe: layoutProbe)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(document == nil ? consistencyText(consistencyLanguage, "remaining.63607e970c42") : consistencyText(consistencyLanguage, "remaining.7ae1d2e07764"),
                  systemImage: document == nil ? "waveform" : "waveform.badge.exclamationmark")
        } description: {
            Text(document == nil
                 ? consistencyText(consistencyLanguage, "remaining.dc5e0177b179")
                 : consistencyText(consistencyLanguage, "remaining.7a9cd97fa625"))
        } actions: {
            VStack(spacing: 8) {
                if document == nil {
                    Button(consistencyText(consistencyLanguage, "remaining.bc41336ea29f"), action: importOriginal)
                        .accessibilityIdentifier("audio-import")
                } else {
                    Button(consistencyText(consistencyLanguage, "remaining.ab7cc5e472e6"), action: refreshInspection)
                        .accessibilityIdentifier("audio-refresh")
                }
                recordingControl
                if !recordingEnabled && !isRecordingOrRequesting {
                    Text(consistencyText(consistencyLanguage, "remaining.575a8d87e5d4"))
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
                Text(consistencyText(consistencyLanguage, "remaining.a61a015d1672")).font(.title2.weight(.semibold))
                Text(consistencyText(consistencyLanguage, "remaining.308f72288b38", arguments: ["v0": String(describing: format.channelCount), "v1": String(describing: Int(format.sampleRate))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 210), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                Button(consistencyText(consistencyLanguage, "remaining.21ce92417dc8"), systemImage: "square.and.arrow.up", action: exportOriginal)
                    .buttonStyle(WorkbenchGlassButtonStyle())
                    .accessibilityIdentifier("audio-export-original")
                    .audioMeasured("audio-export-original", probe: layoutProbe)
                recordingControl.buttonStyle(WorkbenchGlassButtonStyle())
            }
            if !recordingEnabled && !isRecordingOrRequesting {
                Text(consistencyText(consistencyLanguage, "remaining.575a8d87e5d4"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller?.errorMessage != nil {
                Button(consistencyText(consistencyLanguage, "remaining.ab7cc5e472e6"), action: refreshInspection)
                    .accessibilityIdentifier("audio-refresh")
            }
        }
        .accessibilityIdentifier("audio-header")
    }

    @ViewBuilder private var recordingControl: some View {
        if isRecordingOrRequesting {
            Button(transport.state == .recording ? consistencyText(consistencyLanguage, "remaining.9e8b189ff9e7") : consistencyText(consistencyLanguage, "remaining.fdc423587f24"),
                   systemImage: "stop.fill", action: finishRecording)
                .accessibilityIdentifier("audio-record-finish")
                .audioMeasured("audio-record-finish", probe: layoutProbe)
        } else {
            Button(consistencyText(consistencyLanguage, "remaining.ee9247035880"), systemImage: "mic.fill", action: startRecording)
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
            .audioMeasured("audio-waveform", probe: layoutProbe)
            HStack {
                Button(transport.state == .playing ? consistencyText(consistencyLanguage, "remaining.8d12fc0d4eb2") : consistencyText(consistencyLanguage, "remaining.c3396195e91c"),
                       systemImage: transport.state == .playing ? "pause.fill" : "play.fill") {
                    if transport.state == .playing {
                        transport.pause()
                    } else {
                        do { try transport.play() }
                        catch { transport.present(error) }
                    }
                }
                .buttonStyle(WorkbenchGlassButtonStyle())
                .accessibilityIdentifier("audio-play-pause")
                Text(time(transport.positionFrame, format: format)).monospacedDigit()
                Spacer()
                statusLabel
            }
            if let preparedRange {
                Text(consistencyText(consistencyLanguage, "remaining.54b25dc3d556", arguments: ["v0": String(describing: time(preparedRange.startFrame, format: format)), "v1": String(describing: time(preparedRange.endFrame, format: format))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio-prepared-range")
                    .audioMeasured("audio-prepared-range", probe: layoutProbe)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func details(document: AudioDraftDocument, format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(consistencyText(consistencyLanguage, "remaining.79513b4afed9")).font(.headline)
            TextField(consistencyText(consistencyLanguage, "remaining.febb598fbcef"), text: noteBinding(document), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(WorkbenchGlassTextFieldStyle())
                .disabled(!canEdit)
                .accessibilityIdentifier("audio-note")
                .audioMeasured("audio-note", probe: layoutProbe)
            Button(controller?.isSaving == true ? consistencyText(consistencyLanguage, "remaining.6bdb4435095e") : consistencyText(consistencyLanguage, "remaining.2214441f8100")) {
                saveNote(document)
            }
            .disabled(!canEdit || controller?.isSaving == true)
            .accessibilityIdentifier("audio-save-note")
            Divider()
            HStack {
                TextField(consistencyText(consistencyLanguage, "remaining.5679e242347c"), text: clipNameBinding(document))
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-clip-name")
                Button(consistencyText(consistencyLanguage, "remaining.780e77bb7d01")) { addClip(document, format: format) }
                    .disabled(!canEdit || document.clips.count >= AudioLimits.maximumClips)
                    .accessibilityIdentifier("audio-add-clip")
                    .audioMeasured("audio-add-clip", probe: layoutProbe)
            }
            rangeEditors(document: document, format: format)
            HStack {
                Button(consistencyText(consistencyLanguage, "remaining.6b0ee08c94f5")) {
                    select(Optional<AudioClip>.none, document: document, format: format)
                }
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-select-full")
                    .accessibilityAddTraits(document.selectedClipID == nil ? .isSelected : [])
                Button(consistencyText(consistencyLanguage, "remaining.dff93287cdc5")) { auditionCurrentRange(document: document, format: format) }
                    .disabled(!canEdit)
                    .accessibilityIdentifier("audio-audition-range")
                Button(consistencyText(consistencyLanguage, "remaining.27ba660e37bb")) { exportCurrentRange(format: format) }
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
                    Button(consistencyText(consistencyLanguage, "remaining.76420433f22d")) { export(clip: clip) }
                        .accessibilityIdentifier("audio-export-clip-\(clip.id.uuidString)")
                }
                .audioMeasured("audio-clip-row-\(clip.id.uuidString)", probe: layoutProbe)
            }
            if controller?.hasUnsubmittedInput == true {
                HStack {
                    Text(consistencyText(consistencyLanguage, "remaining.3770318e532e"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(consistencyText(consistencyLanguage, "remaining.cc26c3570bb5"), role: .destructive) { discardInput(document, format: format) }
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
                Text(consistencyText(consistencyLanguage, "remaining.20c88acfeb8b", arguments: ["v0": String(describing: startFrame), "v1": String(describing: time(startFrame, format: format))]))
                    .monospacedDigit()
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("audio-range-start")
            Stepper(value: endBinding(document: document, format: format),
                    in: min(Int64(1), format.frameCount)...max(Int64(1), format.frameCount), step: 1) {
                Text(consistencyText(consistencyLanguage, "remaining.5d1fdfe74fe6", arguments: ["v0": String(describing: endFrame), "v1": String(describing: time(endFrame, format: format))]))
                    .monospacedDigit()
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("audio-range-end")
            Text(consistencyText(consistencyLanguage, "remaining.e585b7e61afe"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var captureRecovery: some View {
        if let controller, !controller.pendingCaptures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(consistencyText(consistencyLanguage, "remaining.3fb86fc50550")).font(.headline)
                Text(consistencyText(consistencyLanguage, "remaining.5a1d184d0691"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.pendingCaptures) { capture in
                    HStack {
                        Text(capture.name).lineLimit(1)
                        Spacer()
                        Button(consistencyText(consistencyLanguage, "remaining.b8784c8dd563")) {
                            productionActions?.retryCapture(
                                capture.id, controller.contextID, editingDocumentID
                            )
                        }
                            .disabled(controller.isFinalizing || isRecordingOrRequesting)
                        Button(consistencyText(consistencyLanguage, "remaining.c6bca057fb85")) {
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
        if let message = controller?.errorMessage ?? transport.errorMessage { return message }
        if let actionStatus {
            switch actionStatus {
            case "注释已保存。": return consistencyText(consistencyLanguage, "remaining.0af1064ff510")
            case "片段已保存。": return consistencyText(consistencyLanguage, "remaining.666577412ccf")
            case "未提交输入已放弃；原件和已保存内容未改变。": return consistencyText(consistencyLanguage, "remaining.0a680010906c")
            default: return actionStatus
            }
        }
        return switch transport.state {
        case .requestingPermission: consistencyText(consistencyLanguage, "remaining.b6adc42adfe8")
        case .recording: consistencyText(consistencyLanguage, "remaining.5254d30be60f")
        case .recorded: consistencyText(consistencyLanguage, "remaining.8bef70b00989")
        case .playing: consistencyText(consistencyLanguage, "remaining.e6666b2eb332")
        case .paused: consistencyText(consistencyLanguage, "remaining.eb0c326b60ae")
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
    @Environment(\.dLanguageStore) private var consistencyLanguage
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

extension View {
    func audioMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("audio-workbench-layout"))
        } action: { rectangle in
            probe?(id, rectangle)
        }
    }
}

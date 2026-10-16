import DInference
import DWorkbench
import Foundation
import SwiftUI
import Observation

public enum AudioCreationPresentation { case complete, content, parameters }

/// Shared by the editor and its collapsible parameter surface. Closing a popover must
/// not silently lose an unapplied interval; changing document/source resets it explicitly.
@MainActor @Observable public final class AudioCreationRangeState {
    var startText = ""
    var endText = ""
    var pendingMessage: String?
    private(set) var contextID: UUID?
    private var sourceID: UUID?
    private var appliedRange: AudioFrameRange?
    private var initialized = false
    public init() {}
    func synchronize(contextID: UUID?, range: AudioFrameRange?, source: ProjectAsset?) {
        guard !initialized || self.contextID != contextID || sourceID != source?.id || appliedRange != range else { return }
        initialized = true
        self.contextID = contextID; sourceID = source?.id; appliedRange = range
        let values = AudioCreationButtonHandler.displayedRange(range, source: source)
        startText = values.0; endText = values.1; pendingMessage = nil
    }
}

public struct AudioCreationView: View {
    @Environment(\.dLanguageStore) private var language
    @Binding private var draft: AudioCreationDraft
    private let source: ProjectAsset?
    private let candidates: [ProjectAsset]
    private let selectedAssetID: UUID?
    private let adoptedAssetID: UUID?
    private let modelStatus: String
    private let canGenerate: Bool
    private var musicSupported = false
    private var executionCapability: AudioExecutionCapability?
    private let isBusy: Bool
    private let progress: Double?
    private let status: String?
    @Bindable private var transport: AudioTransport
    private let actions: AudioCreationActions
    @State private var ownedRangeState = AudioCreationRangeState()
    private var suppliedRangeState: AudioCreationRangeState?
    private var presentation: AudioCreationPresentation = .complete
    private var presentationContextID: UUID?
    private var rangeState: AudioCreationRangeState { suppliedRangeState ?? ownedRangeState }
    private var rangeStartText: String { rangeState.startText }
    private var rangeEndText: String { rangeState.endText }
    private var rangeInputMessage: String? {
        get { rangeState.pendingMessage }
        nonmutating set { rangeState.pendingMessage = newValue }
    }
    private var scrollToCandidatesForCheck = false
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(draft: Binding<AudioCreationDraft>, source: ProjectAsset?, candidates: [ProjectAsset],
                selectedAssetID: UUID?, adoptedAssetID: UUID?, modelStatus: String,
                canGenerate: Bool, isBusy: Bool, progress: Double?, status: String?,
                transport: AudioTransport, actions: AudioCreationActions) {
        _draft = draft
        self.source = source
        self.candidates = candidates
        self.selectedAssetID = selectedAssetID
        self.adoptedAssetID = adoptedAssetID
        self.modelStatus = modelStatus
        self.canGenerate = canGenerate
        self.isBusy = isBusy
        self.progress = progress
        self.status = status
        self.transport = transport
        self.actions = actions
    }

    public func presenting(_ presentation: AudioCreationPresentation, rangeState: AudioCreationRangeState, contextID: UUID) -> Self {
        var copy = self; copy.presentation = presentation; copy.suppliedRangeState = rangeState
        copy.presentationContextID = contextID; return copy
    }

    /// The host alone knows whether the MRT2 provider is currently available.  Keeping this
    /// opt-in preserves the existing Stable Audio surface for callers which have not wired it.
    public func supportingMusic(_ enabled: Bool) -> Self {
        var copy = self; copy.musicSupported = enabled; return copy
    }

    public func capabilitySummary(_ capability: AudioExecutionCapability?) -> Self {
        var copy = self; copy.executionCapability = capability; return copy
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { reader in
              ScrollView {
                let layout = viewport.size.width >= 720
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                VStack(alignment: .leading, spacing: 16) {
                    if presentation != .content { header }
                    if presentation == .parameters {
                        controls.frame(maxWidth: .infinity, alignment: .topLeading)
                    } else if presentation == .content {
                        sourceAndCandidates.frame(maxWidth: .infinity, alignment: .topLeading).id("audio-candidates")
                    } else {
                        layout {
                            controls.frame(maxWidth: .infinity, alignment: .topLeading)
                            sourceAndCandidates.frame(maxWidth: .infinity, alignment: .topLeading).id("audio-candidates")
                        }
                    }
                    if presentation != .content { statusArea }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
              }
              .task(id: viewport.size.width) {
                  if scrollToCandidatesForCheck {
                      await Task.yield()
                      reader.scrollTo("audio-candidates", anchor: .bottom)
                  }
              }
            }
        }
        .onAppear(perform: loadRangeText)
        .onChange(of: presentationContextID) { _, _ in loadRangeText() }
        .onChange(of: source?.id) { _, _ in
            rangeInputMessage = nil
            loadRangeText()
        }
        .onChange(of: draft.editRegion) { _, _ in loadRangeText() }
        .onChange(of: rangeStartText) { _, _ in assessRangeInput() }
        .onChange(of: rangeEndText) { _, _ in assessRangeInput() }
        .coordinateSpace(name: "audio-workbench-layout")
        .accessibilityIdentifier("audio-create-view")
    }

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    /// Exercises the real SwiftUI viewport without assuming its private AppKit hierarchy.
    func scrollingToCandidatesForLayoutCheck() -> Self {
        var copy = self; copy.scrollToCandidatesForCheck = true; return copy
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(language, "consistency.audio.copy0", fallback: "Audio Creation")).font(.title2.weight(.semibold))
            Text(workflowText(language, "consistency.audio.copy1", fallback: "Generate candidates from a prompt or reference audio. Adopt, reject and save each result explicitly."))
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(modelStatus).font(.caption).foregroundStyle(.secondary)
                Button(workflowText(language, "consistency.audio.copy2", fallback: "Choose Model…"), action: actions.chooseModel).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-choose-model")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            capabilitySummaryContent
            profilePicker
            TextField(draft.profile == .conditionedMusic ? workflowText(language, "consistency.audio.copy3", fallback: "Describe the instrumental style") : workflowText(language, "consistency.audio.copy4", fallback: "Describe the sound"), text: $draft.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(WorkbenchGlassTextFieldStyle())
                .disabled(isBusy).accessibilityIdentifier("audio-create-prompt")
            if draft.profile == .conditionedMusic {
                musicControls
            } else {
                stableAudioControls
            }
            actionRow
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var capabilitySummaryContent: some View {
        if let capability = executionCapability {
            VStack(alignment: .leading, spacing: 4) {
                Text(workflowText(language, "consistency.audio.copy5", fallback: "Current Generation Capabilities")).font(.subheadline.weight(.semibold))
                Text(Self.capabilitySummaryText(capability, language: language))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if capability.noteControlFidelity == .approximate {
                    Text(workflowText(language, "consistency.audio.copy6", fallback: "Note conditioning provides approximate control. Style and accompaniment may vary; exact chords and fixed audio are not guaranteed."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("audio-capability-summary")
        } else {
            Text(workflowText(language, "consistency.audio.copy7", fallback: "No generation capabilities have been declared for this environment."))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("audio-capability-summary")
        }
    }

    static func capabilitySummaryText(_ capability: AudioExecutionCapability, language: UILanguageStore? = nil) -> String {
        let profile: String
        switch capability.profile.identifier {
        case "sm-music": profile = consistencyText(language, "audio.musicProfile")
        case "sm-sfx": profile = consistencyText(language, "audio.sfxProfile")
        case "medium": profile = "Stable Audio Medium"
        case "mrt2-small-export-v1": profile = consistencyText(language, "audio.mrtProfile")
        default: profile = consistencyText(language, "audio.deployed", arguments: ["identifier": capability.profile.identifier])
        }
        let operations = capability.operations.map { operation in
            consistencyText(language, "audio.operation." + operation.rawValue)
        }.joined(separator: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? "、" : ", ")
        return consistencyText(language, "audio.capability", arguments: ["profile": profile,
            "seconds": capability.maximumDurationSeconds.formatted(.number.locale(Locale(identifier: language?.effectiveLanguageIdentifier ?? "en"))),
            "sampleRate": String(capability.sampleRate), "channels": String(capability.channelCount), "operations": operations])
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            WorkbenchPicker(workflowText(language, "consistency.audio.copy8", fallback: "Creation Type"), selection: profileBinding) {
                WorkbenchChoice(workflowText(language, "consistency.audio.copy9", fallback: "Sound Generation and Editing (Stable Audio)"), value:AudioCreationProfile.stableAudio)
                WorkbenchChoice(workflowText(language, "consistency.audio.copy10", fallback: "Melody-Conditioned Instrumental Music (MRT2)"), value:AudioCreationProfile.conditionedMusic)
                    .disabled(source != nil || !musicSupported)
            }
            .pickerStyle(.menu)
            .disabled(isBusy || (source != nil && draft.profile != .conditionedMusic))
            .accessibilityIdentifier("audio-create-profile")
            if source != nil && draft.profile == .stableAudio {
                Text(workflowText(language, "consistency.audio.copy11", fallback: "A creation with source audio cannot be converted to melody-conditioned music. Start a new creation without source audio."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.profile == .conditionedMusic && !musicSupported {
                Text(workflowText(language, "consistency.audio.copy12", fallback: "Melody-conditioned music is unavailable. Existing conditions can be viewed, saved or exported, but new generation is unavailable."))
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("audio-create-music-unavailable")
            }
        }
    }

    private var profileBinding: Binding<AudioCreationProfile> {
        Binding(get: { draft.profile }, set: { profile in
            guard profile != draft.profile else { return }
            if profile == .conditionedMusic {
                guard source == nil, musicSupported else { return }
                draft.profile = .conditionedMusic
                draft.operation = .generate
                draft.editRegion = nil
                if draft.music == nil { draft.music = .example }
            } else {
                draft.profile = .stableAudio
            }
        })
    }

    private var stableAudioControls: some View {
        Group {
            WorkbenchPicker(workflowText(language, "consistency.audio.copy13", fallback: "Operation"), selection: $draft.operation) {
                WorkbenchChoice(workflowText(language, "consistency.audio.copy14", fallback: "Generate New Audio"), value:AudioOperation.generate)
                WorkbenchChoice(workflowText(language, "consistency.audio.copy16", fallback: "Reference Variation"), value:AudioOperation.variation).disabled(source == nil)
                WorkbenchChoice(workflowText(language, "consistency.audio.copy17", fallback: "Inpaint Region"), value:AudioOperation.inpaint).disabled(source == nil)
            }
            .pickerStyle(.menu).disabled(isBusy)
            .accessibilityIdentifier("audio-create-operation")
            parameterFields
            if draft.operation == .inpaint { rangeEditor }
        }
    }

    private var musicControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workflowText(language, "consistency.audio.copy19", fallback: "Melody control is approximate. Each generation produces a new complete clip as a 48 kHz mix, not separate stems. Timing is aligned to 0.04-second intervals."))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("audio-create-music-guidance")
            parameterRow(workflowText(language, "consistency.audio.copy20", fallback: "Duration (seconds)"), text: $draft.durationText, id: "duration", disabled: isBusy)
            parameterRow("Seed", text: $draft.seedText, id: "seed", disabled: isBusy)
            MusicConditionEditor(draft: musicBinding, isBusy: isBusy,
                                 importCondition: actions.importCondition,
                                 exportCondition: actions.exportCondition)
        }
    }

    private var musicBinding: Binding<MusicCreationDraft> {
        Binding(get: { draft.music ?? .example }, set: { draft.music = $0 })
    }

    private var parameterFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            if !sourceOperation {
                parameterRow(workflowText(language, "consistency.audio.copy20", fallback: "Duration (seconds)"), text: $draft.durationText, id: "duration", disabled: isBusy)
            }
            parameterRow("Seed", text: $draft.seedText, id: "seed", disabled: isBusy)
            parameterRow(workflowText(language, "consistency.audio.copy21", fallback: "Steps"), text: $draft.stepsText, id: "steps", disabled: isBusy)
            parameterRow("Guidance", text: $draft.guidanceText, id: "guidance", disabled: isBusy)
            if draft.operation == .generate {
                GridRow { Text(workflowText(language, "consistency.audio.copy22", fallback: "Strength")); Text(workflowText(language, "consistency.audio.copy23", fallback: "1 (fixed for new generation)")) }
            } else {
                parameterRow(workflowText(language, "consistency.audio.copy22", fallback: "Strength"), text: $draft.strengthText, id: "strength", disabled: isBusy)
            }
            if sourceOperation, let sourceDuration {
                GridRow { Text(workflowText(language, "consistency.audio.copy24", fallback: "Source Duration")); Text(sourceDuration).monospacedDigit() }
            }
        }
    }

    private func parameterRow(_ title: String, text: Binding<String>, id: String, disabled: Bool) -> some View {
        GridRow {
            Text(title)
            TextField(title, text: text).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(disabled)
                .accessibilityIdentifier("audio-create-\(id)")
        }
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workflowText(language, "consistency.audio.copy25", fallback: "Inpaint Region (seconds; start inclusive, end exclusive)")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField(workflowText(language, "consistency.audio.copy26", fallback: "Start"), text: Binding(get: { rangeState.startText }, set: { rangeState.startText = $0 })).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-range-start")
                TextField(workflowText(language, "consistency.audio.copy27", fallback: "End"), text: Binding(get: { rangeState.endText }, set: { rangeState.endText = $0 })).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-range-end")
                Button(workflowText(language, "consistency.audio.copy28", fallback: "Apply Region"), action: applyRange)
                    .disabled(isBusy).accessibilityIdentifier("audio-create-range-apply")
            }
            Text(rangeInputMessage ?? rangeMessage).font(.caption)
                .foregroundStyle(rangeInputMessage == nil ? Color.secondary : Color.orange)
        }
    }

    private var actionRow: some View {
        HStack {
            if isBusy {
                Button(workflowText(language, "consistency.audio.copy29", fallback: "Cancel"), role: .destructive, action: actions.cancel)
                    .accessibilityIdentifier("audio-create-cancel")
            } else {
                Button(workflowText(language, "consistency.audio.copy15", fallback: "Generate")) {
                    guard canSubmit else { return }
                    _ = AudioCreationButtonHandler.submit(draft, source: source,
                                                          hostAllowsGeneration: canGenerate,
                                                          hasPendingRangeInput: draft.operation == .inpaint && rangeInputMessage != nil,
                                                          actions: actions)
                }
                    .buttonStyle(WorkbenchGlassButtonStyle())
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("audio-create-generate")
            }
            Button(workflowText(language, "consistency.audio.copy30", fallback: "Save"), action: actions.save).disabled(isBusy)
                .accessibilityIdentifier("audio-create-save")
        }
    }

    private var sourceAndCandidates: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceInfo
            Divider()
            Text(workflowText(language, "consistency.audio.copy31", fallback: "Candidates")).font(.headline)
            if candidates.isEmpty {
                Text(workflowText(language, "consistency.audio.copy32", fallback: "No candidates yet. Enter a prompt to create one."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(candidates) { asset in candidateRow(asset) }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var sourceInfo: some View {
        if let source {
            Text(consistencyText(language, "audio.reference", arguments: ["name": source.name])).lineLimit(nil)
            Text(sourceDuration ?? workflowText(language, "consistency.audio.copy33", fallback: "Source duration unknown")).font(.caption).foregroundStyle(.secondary)
            if !AudioCreationButtonHandler.sourceIsEditable(source) {
                Text(workflowText(language, "consistency.audio.copy34", fallback: "This source is not a 44.1 kHz stereo WAV supported for editing by this model. You can still keep, play and export it."))
                    .font(.caption).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button(workflowText(language, "consistency.audio.copy35", fallback: "Play")) { _ = AudioCreationButtonHandler.play(source.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-source-play")
                Button(workflowText(language, "consistency.audio.copy36", fallback: "Stop"), action: actions.stop)
                    .accessibilityIdentifier("audio-create-stop")
                Button(workflowText(language, "consistency.audio.copy37", fallback: "Export")) { _ = AudioCreationButtonHandler.export(source.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-source-export")
                Button(workflowText(language, "consistency.audio.copy38", fallback: "Use Original Audio")) {
                    _ = AudioCreationButtonHandler.adopt(nil, isRejected: false, isBusy: isBusy, actions: actions)
                }.disabled(isBusy).accessibilityIdentifier("audio-create-adopt-original")
            }
        } else {
            Text(workflowText(language, "consistency.audio.copy39", fallback: "No reference audio. You can generate directly from a prompt. Reference variation and region inpainting require source audio."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ asset: ProjectAsset) -> some View {
        let rejected = draft.rejectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    _ = AudioCreationButtonHandler.select(asset.id, isBusy: isBusy, actions: actions)
                } label: {
                    Text(asset.name).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-select-\(asset.id.uuidString)")
                HStack {
                    if selectedAssetID == asset.id { Text(workflowText(language, "consistency.audio.copy40", fallback: "Selected")).font(.caption) }
                    if adoptedAssetID == asset.id { Text(workflowText(language, "consistency.audio.copy41", fallback: "Adopted")).font(.caption) }
                    if rejected { Text(workflowText(language, "consistency.audio.copy42", fallback: "Rejected")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(assetDuration(asset) ?? workflowText(language, "consistency.audio.copy43", fallback: "Duration unknown")).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button(workflowText(language, "consistency.audio.copy35", fallback: "Play")) { _ = AudioCreationButtonHandler.play(asset.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-play-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-play-\(asset.id.uuidString)", probe: layoutProbe)
                Button(workflowText(language, "consistency.audio.copy44", fallback: "Adopt")) {
                    _ = AudioCreationButtonHandler.adopt(asset.id, isRejected: rejected, isBusy: isBusy, actions: actions)
                }.disabled(isBusy || rejected)
                    .accessibilityIdentifier("audio-create-adopt-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-adopt-\(asset.id.uuidString)", probe: layoutProbe)
                Button(rejected ? workflowText(language, "consistency.audio.copy45", fallback: "Restore") : workflowText(language, "consistency.audio.copy46", fallback: "Reject")) {
                    _ = AudioCreationButtonHandler.setRejected(asset.id, currentlyRejected: rejected, isBusy: isBusy, actions: actions)
                }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-reject-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-reject-\(asset.id.uuidString)", probe: layoutProbe)
                Button(workflowText(language, "consistency.audio.copy37", fallback: "Export")) { _ = AudioCreationButtonHandler.export(asset.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-export-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-export-\(asset.id.uuidString)", probe: layoutProbe)
                if asset.metadata.audio?.format.sampleRate != 48_000 {
                    Button(workflowText(language, "consistency.audio.copy47", fallback: "Create from This Audio")) { actions.createFrom(asset.id) }.disabled(isBusy)
                        .accessibilityIdentifier("audio-create-from-\(asset.id.uuidString)")
                        .audioMeasured("audio-create-from-\(asset.id.uuidString)", probe: layoutProbe)
                }
            }
            if rejected { Text(workflowText(language, "consistency.audio.copy48", fallback: "Rejecting a candidate does not delete it or the original.")).font(.caption).foregroundStyle(.secondary) }
        }
        .audioMeasured("audio-create-candidate-\(asset.id.uuidString)", probe: layoutProbe)
        .accessibilityIdentifier("audio-create-candidate-\(asset.id.uuidString)")
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress { ProgressView(value: progress).accessibilityIdentifier("audio-create-progress") }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !isBusy {
                Text(validationMessage).font(.caption)
                    .foregroundStyle(canSubmit ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("audio-create-status")
            }
        }
    }

    private var sourceOperation: Bool { draft.operation != .generate }
    private var canSubmit: Bool {
        durationConfigurationError == nil && AudioCreationButtonHandler.canSubmit(draft, source: source, hostAllowsGeneration: canGenerate && (draft.profile != .conditionedMusic || musicSupported),
                                             hasPendingRangeInput: draft.operation == .inpaint && rangeInputMessage != nil)
    }
    private var durationConfigurationError: String? {
        if let capability = executionCapability {
            do { try draft.validateDuration(capability: capability, sourceFormat: source?.metadata.audio?.format) }
            catch { return error.localizedDescription }
        }
        return nil
    }
    private var validationMessage: String {
        if let error = durationConfigurationError { return error }
        return AudioCreationButtonHandler.submissionMessage(draft, source: source, hostAllowsGeneration: canGenerate && (draft.profile != .conditionedMusic || musicSupported),
            hasPendingRangeInput: draft.operation == .inpaint && rangeInputMessage != nil, language: language)
    }
    private var sourceDuration: String? { source.flatMap(assetDuration) }
    private func assetDuration(_ asset: ProjectAsset) -> String? {
        guard let format = asset.metadata.audio?.format, format.sampleRate > 0 else { return nil }
        return consistencyText(language, "audio.seconds", arguments: ["seconds": (Double(format.frameCount) / format.sampleRate).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: language?.effectiveLanguageIdentifier ?? "en")))])
    }
    private var rangeMessage: String {
        guard let format = source?.metadata.audio?.format else { return workflowText(language, "consistency.audio.copy49", fallback: "Source audio is required to set a region.") }
        return consistencyText(language, "audio.frames", arguments: ["frames": String(format.frameCount)])
    }
    private func loadRangeText() {
        rangeState.synchronize(contextID: presentationContextID, range: draft.editRegion, source: source)
    }
    private func applyRange() {
        guard let format = source?.metadata.audio?.format,
              let candidate = AudioCreationButtonHandler.frameRange(startText: rangeStartText,
                                                                       endText: rangeEndText, format: format) else {
            rangeInputMessage = workflowText(language, "consistency.audio.copy50", fallback: "Invalid region. The saved range has not changed.")
            return
        }
        draft.editRegion = candidate
        rangeInputMessage = nil
    }

    private func assessRangeInput() {
        guard draft.operation == .inpaint else { return }
        guard let format = source?.metadata.audio?.format,
              let candidate = AudioCreationButtonHandler.frameRange(startText: rangeStartText,
                                                                       endText: rangeEndText, format: format) else {
            rangeInputMessage = workflowText(language, "consistency.audio.copy50", fallback: "Invalid region. The saved range has not changed.")
            return
        }
        rangeInputMessage = candidate == draft.editRegion ? nil : workflowText(language, "consistency.audio.copy51", fallback: "Apply the region before generating.")
    }
}

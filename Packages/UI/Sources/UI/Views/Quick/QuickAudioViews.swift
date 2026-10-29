import DWorkbench
import SwiftUI

@MainActor private func audioText(_ language: UILanguageStore?, _ key: String) -> String {
    workflowText(language, "quick.audio." + key)
}

struct QuickAudioSettings: View {
    @Bindable var quick: QuickGenerationController
    @Environment(\.dLanguageStore) private var language
    @State private var advanced = false
    var body: some View {
        if let draft = quick.draft, let form = QuickAudioPresentation.form(for: draft), !quick.audioRequiresWorkflow {
            VStack(alignment: .leading, spacing: 14) {
                Text(audioText(language, "duration")).font(.subheadline)
                if form == .mrt2Text {
                    TextField(audioText(language, "duration"), text: Binding(get: {
                        draft.fieldText["quickDurationSeconds"] ?? QuickAudioPresentation.seconds(frames: draft.node.parameters["durationFrames"]?.integer ?? 100)
                    }, set: { quick.setAudioDurationSeconds($0, draftID: draft.id) }))
                        .textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("quick-audio-duration")
                } else { parameter("duration", draft: draft, title: "duration", hideTitle: true) }
                Stepper(value: Binding(get: { draft.attempts }, set: { quick.setAttempts($0, draftID: draft.id) }), in: 1...8) {
                    Text(audioText(language, "count") + " · \(draft.attempts)")
                }
                if form == .aceGenerate {
                    WorkbenchPicker(audioText(language, "vocal"), selection: Binding(get: { draft.node.parameters["vocal"]?.string ?? "instrumental" }, set: { quick.setParameter("vocal", value: .text($0), draftID: draft.id) })) {
                        WorkbenchChoice(audioText(language, "instrumental"), value: "instrumental")
                        WorkbenchChoice(audioText(language, "lyricsMode"), value: "lyrics")
                    }
                }
                DisclosureGroup(audioText(language, "advanced"), isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        parameter("seed", draft: draft, title: "seed")
                        if form == .aceGenerate {
                            ForEach(["steps", "guidance", "bpm", "keyScale", "meter", "loadingStrategy", "memoryBudgetGiB"], id: \.self) { key in parameter(key, draft: draft) }
                        }
                    }.padding(.top, 8)
                }
            }.padding(.horizontal, 20)
        }
    }
    @ViewBuilder private func parameter(_ id: String, draft: QuickDraft, title: String? = nil, hideTitle: Bool = false) -> some View {
        if let field = quick.definition?.fields.first(where: { $0.id == id }) {
            QuickParameterField(ownerID: draft.id, operationID: draft.node.operationID, modelIdentity: draft.node.parameters["modelID"]?.string,
                field: field, value: draft.node.parameters[id] ?? field.defaultValue,
                onChange: { quick.setParameter(id, value: $0, draftID: draft.id) }, raw: draft.fieldText[id],
                onRaw: { quick.setFieldText(id, text: $0, draftID: draft.id) },
                titleOverride: title.map { audioText(language, $0) }, hidesTitle: hideTitle)
        }
    }
}

struct QuickAudioInput: View {
    @Bindable var quick: QuickGenerationController
    let continueInWorkflow: (QuickDraft) -> Void
    var compact = false
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        if let draft = quick.draft {
            if quick.audioRequiresWorkflow {
                Text(audioText(language, "complex")).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(audioText(language, "continue")) { continueInWorkflow(draft) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    editor("promptText", title: "description", placeholder: "placeholder", draft: draft)
                    if QuickAudioPresentation.form(for: draft) == .aceGenerate {
                        if draft.node.parameters["vocal"]?.string == "lyrics" {
                            editor("lyricsText", title: "lyrics", draft: draft)
                            TextField(audioText(language, "language"), text: Binding(get: { draft.node.parameters["language"]?.string ?? "en" }, set: { quick.setParameter("language", value: .text($0), draftID: draft.id) }))
                                .textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityLabel(audioText(language, "language"))
                        } else if !(draft.node.parameters["lyricsText"]?.string ?? "").isEmpty {
                            Button(audioText(language, "lyricsMode")) { quick.setParameter("vocal", value: .text("lyrics"), draftID: draft.id) }
                        }
                    }
                }
            }
        }
    }
    private func editor(_ key: String, title: String, placeholder: String? = nil, draft: QuickDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(audioText(language, title)).font(.subheadline)
            TextSourcesQuestionEditor(value: draft.node.parameters[key]?.string ?? "", editEpoch: 0, isEditable: true,
                accessibilityIdentifier: "quick-audio-" + key, accessibilityLabel: audioText(language, title),
                onEdit: { quick.setParameter(key, value: .text($0), draftID: draft.id) },
                placeholder: placeholder.map { audioText(language, $0) })
                .id([draft.id, key]).frame(height: key == "lyricsText" ? (compact ? 56 : 72) : (compact ? 48 : 64)).padding(4).workbenchInputSurface()
        }
    }
}

/// The ordinal is presentation only; the parent retains the exact asset reference as identity.
struct QuickAudioCandidateAccessibility: ViewModifier {
    let enabled: Bool
    let index: Int
    let count: Int
    let selected: Bool
    @Environment(\.dLanguageStore) private var language
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityValue(workflowText(language, "quick.audio.candidatePosition",
                arguments: ["index": String(index + 1), "count": String(count)]))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else { content }
    }
}

/// Metadata only. No playback resource or waveform is prepared in a candidate row.
struct QuickAudioCandidate: View {
    let store: ProjectStore
    let reference: WorkflowAssetReference
    let attempt: Int?
    @State private var name = ""
    @State private var seconds: Double?
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.isEmpty ? audioText(language, "assets") : name).lineLimit(2)
            HStack(spacing: 8) {
                if let seconds { Text(String(format: "%.2f s", seconds)).monospacedDigit() }
                if let attempt { Text(workflowText(language, "refinement.quick.attempt", arguments: ["index": String(attempt)])) }
            }.font(.caption).foregroundStyle(.secondary)
        }.task(id: reference) {
            let manifest = await store.snapshot()
            guard !Task.isCancelled, manifest.id == reference.projectID,
                  let asset = manifest.assets.first(where: { $0.id == reference.assetID }) else { return }
            name = asset.name
            if let format = asset.metadata.audio?.format, format.sampleRate > 0 {
                seconds = Double(format.frameCount) / format.sampleRate
            }
        }
    }
}

/// The transport's progress ticks are observed only here, never by the page or rows.
struct QuickAudioPlayer: View {
    @Bindable var playback: QuickAudioPlayback
    let beforePlay: () -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var issue: String?
    var body: some View {
        VStack(spacing: 8) {
            if let format = playback.format {
                let transport = playback.transport
                HStack(spacing: 12) {
                    Button(audioText(language, transport.state == .playing ? "pause" : "play"), systemImage: transport.state == .playing ? "pause.fill" : "play.fill") {
                        if transport.state == .playing { transport.pause() }
                        else { beforePlay(); perform { try transport.play() } }
                    }.labelStyle(.iconOnly).font(.title2).frame(width: 36, height: 36)
                        .help(audioText(language, transport.state == .playing ? "pause" : "play"))
                        .accessibilityIdentifier("quick-audio-play")
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { Double(transport.positionFrame) }, set: { frame in perform { try transport.seek(toFrame: min(format.frameCount - 1, Int64(frame))) } }), in: 0...Double(max(1, format.frameCount)))
                            .accessibilityLabel(audioText(language, "position"))
                        HStack {
                            Text(time(Double(transport.positionFrame) / format.sampleRate))
                            Spacer(); Text(time(Double(format.frameCount) / format.sampleRate))
                        }.font(.caption.monospacedDigit())
                    }
                }
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: Binding(get: { Double(transport.volume) }, set: { transport.setVolume(Float($0)) }), in: 0...1)
                        .accessibilityLabel(audioText(language, "volume"))
                }.frame(maxWidth: 180).help(audioText(language, "volume"))
            } else if playback.issue == nil { ProgressView() }
            if let error = issue ?? playback.issue ?? playback.transport.errorMessage {
                WorkbenchIssueText(raw: error, key: issue == nil && playback.issue != nil ? playback.issueCode : nil).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.frame(maxWidth: 520).onChange(of: playback.reference) { _, _ in issue = nil }
    }
    private func time(_ seconds: Double) -> String { String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)) }
    private func perform(_ action: () throws -> Void) { do { try action(); issue = nil } catch { issue = error.localizedDescription } }
}

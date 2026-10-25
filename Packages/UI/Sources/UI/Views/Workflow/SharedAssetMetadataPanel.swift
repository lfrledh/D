import AppKit
import DWorkbench
import SwiftUI

/// Adapts the existing workbench editor-close gate; owns no project or draft state.
struct MetadataEditorLifecycle: Sendable {
    var begin: @MainActor @Sendable () -> Void = {}
    var end: @MainActor @Sendable () -> Void = {}
}
private struct MetadataEditorLifecycleKey: EnvironmentKey { static let defaultValue = MetadataEditorLifecycle() }
extension EnvironmentValues {
    var metadataEditorLifecycle: MetadataEditorLifecycle {
        get { self[MetadataEditorLifecycleKey.self] }
        set { self[MetadataEditorLifecycleKey.self] = newValue }
    }
}

public typealias SharedLibraryAnnotationSave = @MainActor (ProjectAssetEditBaseline, String?, String?, Bool?) async throws -> Void

@MainActor func metadataText(_ language: UILanguageStore?, _ key: String, _ zh: String = "", _ en: String = "") -> String {
    workflowText(language, "metadata.panel." + key, fallback: zh.isEmpty ? en : zh)
}

struct AssetAnnotationRequest: Identifiable {
        let id = UUID()
        let snapshot: ProjectAssetMetadataSnapshot
        var context: String? = nil
        let validate: () throws -> Void
        let save: SharedLibraryAnnotationSave
    }

/// Same factual sections in library and exact workflow results; only the captured owner writes.
struct SharedAssetMetadataPanel: View {
    let snapshot: ProjectAssetMetadataSnapshot
    let library: SharedLibraryStore?
    let validate: () throws -> Void
    let save: SharedLibraryAnnotationSave?
    var onQuery: ((SharedLibraryPropertyQuery) -> Void)? = nil
    var onOpenSource: ((WorkflowAssetReference) -> Void)? = nil
    var onEdit: ((AssetAnnotationRequest) -> Void)? = nil
    @State private var editing: AssetAnnotationRequest?
    @State private var showsRaw = false
    @Environment(\.dLanguageStore) private var language
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    private var unknown: String { t("unknown") }
    private var logicalKey: String { "asset:" + snapshot.projectID.uuidString + ":" + snapshot.asset.id.uuidString }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(t("description")) {
                VStack(alignment: .leading, spacing: 7) {
                    row(t("displayName"), snapshot.asset.name)
                    row(t("note"), snapshot.asset.note.isEmpty ? unknown : snapshot.asset.note)
                    row(t("favorite"), snapshot.asset.isFavorite ? t("yes") : t("no"))
                    if let save {
                        Button(t("edit")) {
                            let request = AssetAnnotationRequest(snapshot: snapshot, validate: validate, save: save)
                            if let onEdit { onEdit(request) } else { editing = request }
                        }.accessibilityIdentifier("asset-annotations-edit").workbenchHelp("RESULT-INFO", target: "asset:\(snapshot.projectID):\(snapshot.instanceID):\(snapshot.asset.id):\(snapshot.record?.reference)")
                    }
                    SharedLibraryTagSection(store: library, target: .init(key: logicalKey, title: snapshot.asset.name, legacy: snapshot.asset.tags), validateTarget: validate)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(t("technical")) {
                VStack(alignment: .leading, spacing: 6) {
                    row(t("format"), snapshot.asset.mediaType)
                    if snapshot.asset.workflowContentKind == .image || snapshot.asset.workflowContentKind == .video {
                    dimension(t("width"), value: snapshot.asset.metadata.width, width: true)
                    dimension(t("height"), value: snapshot.asset.metadata.height, width: false)
                    row(t("depth"), snapshot.asset.metadata.bitDepth.map { "\($0) bit" } ?? unknown)
                    row(t("color"), snapshot.asset.metadata.colorSpace ?? unknown)
                    }
                    row(t("registered"), snapshot.asset.createdAt.formatted(date: .abbreviated, time: .standard))
                    if let audio = snapshot.asset.metadata.audio?.format {
                        row(t("audio"), "\(audio.sampleRate) Hz · \(audio.channelCount) ch · \(audio.bitDepth) bit")
                        if audio.sampleRate > 0 { row(t("duration"), String(format: "%.3f s", Double(audio.frameCount) / audio.sampleRate)) }
                    }
                    if let video = snapshot.asset.metadata.video {
                        row(t("video"), "\(video.width) × \(video.height) px · \(video.codec)")
                        row(t("fps"), "\(video.frameRate.numerator)/\(video.frameRate.denominator) fps")
                        if video.durationDenominator > 0 { row(t("duration"), String(format: "%.3f s", Double(video.durationNumerator) / Double(video.durationDenominator))) }
                    }
                    Text(t("unknownRule")).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(t("source")) {
                VStack(alignment: .leading, spacing: 7) {
                    if let issue = snapshot.sourceIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let model = snapshot.facts.model {
                        row(model.kind == .recordedIdentity ? t("model") : t("localModel"), model.kind == .recordedIdentity ? t("modelNameUnrecorded") : URL(fileURLWithPath: model.value).lastPathComponent)
                        row(t("revision"), model.revision == nil ? unknown : t("exactRecordedVersion"))
                        WorkflowTechnicalDetails(value: model.value + "\n" + (model.revision ?? unknown))
                        if let onQuery {
                            WorkbenchMenu(t("filterModel")) {
                                if model.revision != nil { WorkbenchMenuAction(t("exactVersion")) { onQuery(.init(model: model)) } }
                                WorkbenchMenuAction(t("allVersions")) { var source = model; source.revision = nil; onQuery(.init(model: source)) }
                            }
                        }
                    } else { row(t("model"), unknown) }
                    row(t("requestSeed"), snapshot.requestedSeed ?? unknown)
                    row(t("backend"), snapshot.record?.metadata["backend"] ?? snapshot.job?.resultMetadata["backend"] ?? unknown)
                    if let record = snapshot.record {
                        WorkflowTechnicalDetails(value: record.operationID)
                        if record.parents.isEmpty { Text(t("noParents")).font(.caption) }
                        ForEach(record.parents, id: \.self) { parent in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("sourceAsset"))
                                WorkflowTechnicalDetails(value: String(describing: parent))
                                if let onOpenSource { Button(t("openParent")) { onOpenSource(parent) } }
                                if let onQuery { Button(t("filterParent")) { onQuery(.init(directParent: parent)) } }
                            }
                        }
                    }
                    if snapshot.record == nil { Text(t("unknownParents")).font(.caption) }
                    if let occurrences = snapshot.occurrences, !occurrences.isEmpty {
                        DisclosureGroup(t("calls")) {
                            ForEach(Array(occurrences.enumerated()), id: \.offset) { _, value in
                                Text("Run \(value.runID)\nNode \(value.nodeID)\nCall \(value.stepID)").font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    DisclosureGroup(t("raw"), isExpanded: $showsRaw) {
                        if showsRaw { ScrollView { Text(rawSource).font(.caption2.monospaced()).textSelection(.enabled) }.frame(maxHeight: 200) }
                    }
                    row(t("rights"), t("rightsUnknown"))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("technicalDetails")) {
                VStack(alignment: .leading, spacing: 5) {
                    row(t("project"), snapshot.projectName)
                    row(t("instance"), snapshot.instanceID.uuidString)
                    row(t("asset"), snapshot.asset.id.uuidString)
                    if let record = snapshot.record {
                        row(t("version"), record.reference.version.uuidString)
                        DisclosureGroup(t("digest")) {
                            Text(record.reference.sha256).font(.caption.monospaced()).textSelection(.enabled)
                            Text(t("digestLimit")).font(.caption2)
                        }
                    } else { row(t("version"), unknown) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(t("files")) {
                row(t("relativePath"), snapshot.asset.relativePath)
                Text(t("fileLimit")).font(.caption)
                Text(t("exportLimit")).font(.caption)
            }
        }.font(.caption).textSelection(.enabled)
        .workbenchSheet(item: $editing, title: workflowText(language, "childPanel.name.metadata")) { request in
            AssetAnnotationEditor(snapshot: request.snapshot, validate: request.validate, save: request.save) { editing = nil }
        }
    }
    private var rawSource: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let record = snapshot.record { return (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? unknown }
        if let job = snapshot.job { return (try? encoder.encode(job)).map { String(decoding: $0, as: UTF8.self) } ?? unknown }
        return unknown
    }
    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
    private func dimension(_ title: String, value: Int?, width: Bool) -> some View {
        HStack {
            row(title, value.map { "\($0) px" } ?? ([WorkflowDataKind.image, .video].contains(snapshot.asset.workflowContentKind ?? .text) ? unknown : t("notApplicable")))
            Spacer(minLength: 0)
            if let value, value > 0, let onQuery {
                Button("≥ \(value)", systemImage: "line.3.horizontal.decrease.circle") {
                    onQuery(width ? .init(width: .init(minimum: value)) : .init(height: .init(minimum: value)))
                }.help(t("propertyFilter"))
            }
        }
    }
}

struct AssetAnnotationEditor: View {
    @State private var initial: WorkflowValueAnnotation
    @State private var identity: String
    @State private var ownershipKey: String
    @State private var context: String?
    @State private var validate: () throws -> Void
    @State private var save: (WorkflowValueAnnotation) async throws -> Void
    @Environment(\.workbenchChildClose) private var closeGate
    let dismiss: () -> Void
    @State private var name: String
    @State private var note: String
    @State private var favorite: Bool
    @State private var saving = false
    @State private var failure: (any Error)?
    @Environment(\.metadataEditorLifecycle) private var lifecycle
    @Environment(\.dLanguageStore) private var language
    init(snapshot: ProjectAssetMetadataSnapshot, context: String? = nil, validate: @escaping () throws -> Void, save: @escaping SharedLibraryAnnotationSave, dismiss: @escaping () -> Void) {
        let baseline = ProjectAssetEditBaseline(snapshot: snapshot)
        self.init(initial: .init(name: baseline.name, note: baseline.note, favorite: baseline.favorite),
            context: context ?? (snapshot.projectName + " · " + snapshot.asset.createdAt.formatted(date: .abbreviated, time: .standard)),
            identity: snapshot.projectID.uuidString + "\n" + snapshot.instanceID.uuidString + "\n" + snapshot.asset.id.uuidString,
            ownershipKey: "instanceWrite", validate: validate, save: { value in
                try await save(baseline, value.name.utf8.elementsEqual(baseline.name.utf8) ? nil : value.name,
                    value.note.utf8.elementsEqual(baseline.note.utf8) ? nil : value.note, value.favorite == baseline.favorite ? nil : value.favorite)
            }, dismiss: dismiss)
    }
    init(initial: WorkflowValueAnnotation, context: String?, identity: String, ownershipKey: String,
         validate: @escaping () throws -> Void, save: @escaping (WorkflowValueAnnotation) async throws -> Void, dismiss: @escaping () -> Void) {
        _initial = State(initialValue: initial); _context = State(initialValue: context)
        _identity = State(initialValue: identity); _ownershipKey = State(initialValue: ownershipKey)
        _validate = State(initialValue: validate); _save = State(initialValue: save)
        _name = State(initialValue: initial.name); _note = State(initialValue: initial.note)
        _favorite = State(initialValue: initial.favorite); self.dismiss = dismiss
    }
    private func t(_ key: String, _ zh: String = "", _ en: String = "") -> String { metadataText(language, key, zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("editResultInfo") + " · " + initial.name).font(.headline)
            Text(context ?? "").font(.caption).textSelection(.enabled)
            Text(t("annotationImpact")).font(.callout)
            Text(t("resultName")).font(.subheadline)
            TextField(t("resultName"), text: $name).textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("asset-annotation-name").workbenchHelp("ANNOTATION-NAME")
            Text(t("resultNote")).font(.subheadline)
            TextField(t("resultNote"), text: $note, axis: .vertical).lineLimit(4...10).textFieldStyle(WorkbenchGlassTextFieldStyle()).accessibilityIdentifier("asset-annotation-note").workbenchHelp("ANNOTATION-NOTE")
            Toggle(t("favorite"), isOn: $favorite)
            Text(metadataText(language, ownershipKey, "", "")).font(.caption)
            if let failure { Text(sharedLibraryErrorText(failure, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(t("cancel")) { if let closeGate { closeGate.requestClose() } else { dismiss() } }.workbenchHelp("ANNOTATION-CANCEL").keyboardShortcut(.cancelAction)
                Button(t("saveResultInfo")) {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try await saveDraft()
                            dismiss()
                        } catch { failure = error }
                    }
                }.workbenchHelp("ANNOTATION-SAVE").keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            WorkflowTechnicalDetails(value: identity)
        }.padding(24).frame(minWidth: 410, idealWidth: 480).disabled(saving).interactiveDismissDisabled()
        .workbenchCloseProtection(isDirty: name != initial.name || note != initial.note || favorite != initial.favorite,
                                  isSaving: saving, save: { try await saveDraft() })
        .onAppear { lifecycle.begin() }.onDisappear { lifecycle.end() }
    }
    private func saveDraft() async throws {
        try validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowIssue(t("resultName")) }
        try await save(.init(name: name, note: note, favorite: favorite))
    }
}


/// Runtime annotations reuse the same editor and tag transactions as saved assets.
/// Captured drafts never follow a new selection or mutate the frozen output.
struct RuntimeValueMetadataPanel: View {
    let value: WorkflowLibraryValue
    let identity: WorkflowValueIdentity
    let title: String
    let library: SharedLibraryStore
    let validate: () throws -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var draft: Draft?
    private struct Draft: Identifiable {
        let id = UUID()
        let expected: WorkflowValueAnnotation?
        let initial: WorkflowValueAnnotation
        let identity: WorkflowValueIdentity
        let validate: () throws -> Void
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let annotation = library.metadata.runtimeAnnotations[identity.storageKey]
            Text(annotation?.name ?? title).font(.headline).textSelection(.enabled)
            if let note = annotation?.note, !note.isEmpty { Text(note).textSelection(.enabled) }
            Button(metadataText(language, "edit", "", "")) {
                draft = Draft(expected: annotation, initial: annotation ?? .init(name: title), identity: identity, validate: validate)
            }.accessibilityIdentifier("runtime-annotations-edit")
            SharedLibraryTagSection(store: library,
                target: .init(key: identity.storageKey, title: annotation?.name ?? title, legacy: []), validateTarget: validate)
            Text(metadataText(language, "runtimeOwnership", "", "")).font(.caption).foregroundStyle(.secondary)
        }
        .workbenchSheet(item: $draft, title: workflowText(language, "childPanel.name.metadata")) { captured in
            AssetAnnotationEditor(initial: captured.initial, context: value.createdAt.formatted(date: .abbreviated, time: .standard),
                identity: captured.identity.storageKey, ownershipKey: "runtimeOwnership", validate: captured.validate, save: { updated in
                    // No suspension between target validation, CAS and durable publication.
                    try captured.validate()
                    try library.saveRuntimeAnnotation(identity: captured.identity, expected: captured.expected, value: updated)
                }, dismiss: { draft = nil })
        }
    }
}

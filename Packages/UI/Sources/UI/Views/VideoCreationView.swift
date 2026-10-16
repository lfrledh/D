import DInference
import DWorkbench
import Foundation
import SwiftUI

public enum VideoCreationPresentation { case complete, content, parameters }

public struct VideoCreationView: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    @Binding private var draft: VideoCreationDraft
    private let candidates: [ProjectAsset]
    private let selectedAssetID: UUID?
    private let adoptedAssetID: UUID?
    private let modelStatus: String
    private let canGenerate: Bool
    private let isBusy: Bool
    private let progress: Double?
    private let status: String?
    private let previewURL: URL?
    private let previewIdentity: UUID
    private let defaultMemoryBudgetBytes: UInt64
    private let actions: VideoCreationActions
    private var presentation: VideoCreationPresentation = .complete
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(draft: Binding<VideoCreationDraft>, candidates: [ProjectAsset], selectedAssetID: UUID?,
                adoptedAssetID: UUID?, modelStatus: String, canGenerate: Bool, isBusy: Bool,
                progress: Double?, status: String?, previewURL: URL?, previewIdentity: UUID,
                defaultMemoryBudgetBytes: UInt64, actions: VideoCreationActions) {
        _draft = draft
        self.candidates = candidates
        self.selectedAssetID = selectedAssetID
        self.adoptedAssetID = adoptedAssetID
        self.modelStatus = modelStatus
        self.canGenerate = canGenerate
        self.isBusy = isBusy
        self.progress = progress
        self.status = status
        self.previewURL = previewURL
        self.previewIdentity = previewIdentity
        self.defaultMemoryBudgetBytes = defaultMemoryBudgetBytes
        self.actions = actions
    }

    public func presenting(_ presentation: VideoCreationPresentation) -> Self {
        var copy = self
        copy.presentation = presentation
        return copy
    }

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView {
                let layout = viewport.size.width >= 720
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                VStack(alignment: .leading, spacing: 16) {
                    if presentation != .content { header }
                    if presentation == .parameters {
                        controls
                    } else if presentation == .content {
                        previewAndCandidates
                    } else {
                        layout { controls; previewAndCandidates }
                    }
                    if presentation != .content { statusArea }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .coordinateSpace(name: "video-workbench-layout")
        .onChange(of: isBusy) { _, busy in
            if busy && presentation != .parameters { actions.stop() }
        }
        .onDisappear {
            if presentation != .parameters { actions.stop() }
        }
        .accessibilityIdentifier("video-create-view")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(consistencyText(consistencyLanguage, "remaining.39ee71261b67")).font(.title2.weight(.semibold))
            Text(consistencyText(consistencyLanguage, "remaining.68097cb0369b"))
                .font(.caption).foregroundStyle(.secondary)
            Text(modelStatus).font(.caption).foregroundStyle(.secondary)
            Button(consistencyText(consistencyLanguage, "remaining.13a1ec97c00b"), action: actions.chooseModel).disabled(isBusy)
                .accessibilityIdentifier("video-create-choose-model")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(consistencyText(consistencyLanguage, "remaining.3f1777ba9835")).font(.subheadline.weight(.semibold))
            Text(consistencyText(consistencyLanguage, "remaining.e9f611bd6ace"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(consistencyText(consistencyLanguage, "remaining.c28e00a1ddda"), text: $draft.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(isBusy)
                .accessibilityIdentifier("video-create-prompt")
            TextField(consistencyText(consistencyLanguage, "remaining.f6e3cd4b59cb"), text: $draft.negativePrompt, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(isBusy)
                .accessibilityIdentifier("video-create-negative-prompt")
            parameterFields
            Text(consistencyText(consistencyLanguage, "remaining.313def65a502"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(memoryHint).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("video-create-memory-hint")
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
            layoutProbe?("video-create-controls", $0)
        }
    }

    private var parameterFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            parameterRow(consistencyText(consistencyLanguage, "remaining.8dd966ad496e"), text: $draft.widthText, id: "width")
            parameterRow(consistencyText(consistencyLanguage, "remaining.b1c27820fec2"), text: $draft.heightText, id: "height")
            parameterRow(consistencyText(consistencyLanguage, "remaining.64332ae340ca"), text: $draft.framesText, id: "frames")
            parameterRow(consistencyText(consistencyLanguage, "remaining.ea8a28328646"), text: $draft.fpsNumeratorText, id: "fps-numerator")
            parameterRow(consistencyText(consistencyLanguage, "remaining.edc70a1e68cc"), text: $draft.fpsDenominatorText, id: "fps-denominator")
            parameterRow(consistencyText(consistencyLanguage, "remaining.2986c7ee979b"), text: $draft.stepsText, id: "steps")
            parameterRow("Guidance", text: $draft.guidanceText, id: "guidance")
            parameterRow("Shift", text: $draft.shiftText, id: "shift")
            parameterRow("Seed", text: $draft.seedText, id: "seed")
            parameterRow(consistencyText(consistencyLanguage, "remaining.ef21c852ac60"), text: $draft.memoryBudgetMiBText, id: "memory-budget")
        }
    }

    private func parameterRow(_ title: String, text: Binding<String>, id: String) -> some View {
        GridRow {
            Text(title)
            TextField(title, text: text).textFieldStyle(WorkbenchGlassTextFieldStyle()).disabled(isBusy)
                .accessibilityIdentifier("video-create-\(id)")
        }
    }

    private var actionRow: some View {
        HStack {
            if isBusy {
                Button(consistencyText(consistencyLanguage, "remaining.2cd0f3be8738"), role: .destructive, action: actions.cancel)
                    .accessibilityIdentifier("video-create-cancel")
            } else {
                Button(consistencyText(consistencyLanguage, "remaining.1ad1463fe16f")) {
                    _ = VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: canGenerate,
                                                          isBusy: isBusy, actions: actions)
                }
                .buttonStyle(WorkbenchGlassButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier("video-create-generate")
            }
            Button(consistencyText(consistencyLanguage, "remaining.a3030bf8f16d"), action: actions.save).disabled(isBusy)
                .accessibilityIdentifier("video-create-save")
        }
    }

    private var previewAndCandidates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(consistencyText(consistencyLanguage, "remaining.13d61fea9f17")).font(.headline)
            VideoPreview(url: isBusy ? nil : previewURL, identity: previewIdentity)
                .frame(minHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("video-create-preview")
            Divider()
            Text(consistencyText(consistencyLanguage, "remaining.64af28c77281")).font(.headline)
            if candidates.isEmpty { Text(consistencyText(consistencyLanguage, "remaining.a5411c8ab0d6")).font(.caption).foregroundStyle(.secondary) }
            ForEach(candidates) { candidateRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func candidateRow(_ asset: ProjectAsset) -> some View {
        let rejected = draft.rejectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { _ = VideoCreationButtonHandler.select(asset.id, isBusy: isBusy, actions: actions) } label: {
                Text(asset.name).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isBusy).accessibilityIdentifier("video-create-select-\(asset.id.uuidString)")
            HStack {
                if selectedAssetID == asset.id { Text(consistencyText(consistencyLanguage, "remaining.3f4ebc4aad97")).font(.caption) }
                if adoptedAssetID == asset.id { Text(consistencyText(consistencyLanguage, "remaining.5e2cfe70a09c")).font(.caption) }
                if rejected { Text(consistencyText(consistencyLanguage, "remaining.f098218a3032")).font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button(consistencyText(consistencyLanguage, "remaining.13d61fea9f17")) { _ = VideoCreationButtonHandler.preview(asset.id, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-preview-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-preview-\(asset.id.uuidString)", $0)
                    }
                Button(consistencyText(consistencyLanguage, "remaining.6f6004072ae7")) { _ = VideoCreationButtonHandler.adopt(asset.id, isRejected: rejected, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy || rejected).accessibilityIdentifier("video-create-adopt-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-adopt-\(asset.id.uuidString)", $0)
                    }
                Button(rejected ? consistencyText(consistencyLanguage, "remaining.e0534b8a4e46") : consistencyText(consistencyLanguage, "remaining.136de7a8c46f")) { _ = VideoCreationButtonHandler.setRejected(asset.id, currentlyRejected: rejected, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-reject-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-reject-\(asset.id.uuidString)", $0)
                    }
                Button(consistencyText(consistencyLanguage, "remaining.76420433f22d")) { _ = VideoCreationButtonHandler.export(asset.id, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-export-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-export-\(asset.id.uuidString)", $0)
                    }
            }
            if rejected { Text(consistencyText(consistencyLanguage, "remaining.6157749829c0")).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("video-create-candidate-\(asset.id.uuidString)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
            layoutProbe?("video-create-candidate-\(asset.id.uuidString)", $0)
        }
    }

    private var canSubmit: Bool { !isBusy && canGenerate && VideoCreationButtonHandler.isValid(draft) }
    private var memoryHint: String {
        let historical = consistencyText(consistencyLanguage, "remaining.3dd65458449b")
        let selected: UInt64
        do {
            selected = try draft.selectedMemoryBudgetBytes() ?? defaultMemoryBudgetBytes
        } catch {
            return consistencyText(consistencyLanguage, "remaining.acf4b0bd7f71", arguments: ["v0": String(describing: draft.memoryBudgetMiBText), "v1": String(describing: historical)])
        }
        guard let request = try? draft.makeRequest(),
              let estimate = try? VideoExecutionCapability.wan21.estimatedPeakBytes(for: request) else {
            return consistencyText(consistencyLanguage, "remaining.d141fc383e34", arguments: ["v0": String(describing: historical)])
        }
        let selectedMiB = selected / 1_048_576
        let estimateMiB = estimate / 1_048_576
        let source = draft.memoryBudgetMiBText.isEmpty ? consistencyText(consistencyLanguage, "remaining.7eb336e42cb5") : consistencyText(consistencyLanguage, "remaining.a938aea253e8")
        let risk = selected < estimate ? consistencyText(consistencyLanguage, "remaining.0d072a6b71c8") : consistencyText(consistencyLanguage, "remaining.e035493114e5")
        return consistencyText(consistencyLanguage, "remaining.c897c684c9ce", arguments: ["v0": String(describing: estimateMiB), "v1": String(describing: source), "v2": String(describing: selectedMiB), "v3": String(describing: risk), "v4": String(describing: historical)])
    }
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress { ProgressView(value: progress).accessibilityIdentifier("video-create-progress") }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !isBusy { Text(VideoCreationButtonHandler.submissionMessage(draft, hostAllowsGeneration: canGenerate))
                .font(.caption).foregroundStyle(canSubmit ? Color.secondary : Color.orange)
                .accessibilityIdentifier("video-create-status") }
        }
    }
}

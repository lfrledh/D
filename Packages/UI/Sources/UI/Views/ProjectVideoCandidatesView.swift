import DInference
import DWorkbench
import SwiftUI

/// Saved video candidates keep their existing selection/adoption/export owner.
/// New video requests are edited and submitted by Quick or the canvas.
struct ProjectVideoCandidatesView: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    let draft: VideoCreationDraft
    let candidates: [ProjectAsset]
    let selectedAssetID: UUID?
    let adoptedAssetID: UUID?
    let isBusy: Bool
    let previewURL: URL?
    let previewIdentity: UUID
    let actions: VideoCreationActions
    private var layoutProbe: ((String, CGRect) -> Void)?
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self; copy.layoutProbe = observer; return copy
    }
    var body: some View {
        ScrollView { previewAndCandidates.padding(16) }
            .coordinateSpace(name: "video-workbench-layout")
            .onChange(of: isBusy) { _, busy in if busy { actions.stop() } }
            .onDisappear { actions.stop() }
            .accessibilityIdentifier("project-video-candidates")
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

}

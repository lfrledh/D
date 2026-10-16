import DInference
import DWorkbench
import SwiftUI

/// Renders the editable image-reference draft. The project session owns the reference ID;
/// this view deliberately has no separate selection, task, or persistence state.
struct ImageReferenceSection: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    @Bindable var model: WorkbenchModel
    let documentID: UUID?
    let navigationEpoch: UInt64
    private var layoutProbe: ((String, CGRect) -> Void)?

    init(model: WorkbenchModel, documentID: UUID?, navigationEpoch: UInt64,
         layoutProbe: ((String, CGRect) -> Void)? = nil) {
        self.model = model
        self.documentID = documentID
        self.navigationEpoch = navigationEpoch
        self.layoutProbe = layoutProbe
    }

    /// Used by the offscreen UI test to inspect SwiftUI geometry without relying on AppKit internals.
    func observingLayout(_ probe: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = probe
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(consistencyText(consistencyLanguage, "remaining.0b04d17d6729"), systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.semibold))
            Text(currentReferenceText)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("image-reference-current")
            Text(consistencyText(consistencyLanguage, "remaining.bde89cc3e3ef"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                actions(horizontal: true)
                actions(horizontal: false)
            }
        }
        .accessibilityIdentifier("image-reference-section")
    }

    @ViewBuilder private func actions(horizontal: Bool) -> some View {
        Group {
            if horizontal {
                HStack(alignment: .firstTextBaseline, spacing: 10) { actionButtons }
            } else {
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button {
            guard let documentID else { return }
            Task { await model.chooseImageReference(documentID: documentID, navigationEpoch: navigationEpoch) }
        } label: {
            Label(consistencyText(consistencyLanguage, "remaining.69da21e2ac2f"), systemImage: "square.and.arrow.down")
        }
        .disabled(model.isChangingProject || documentID == nil)
        .accessibilityIdentifier("image-reference-import")
        .imageReferenceActionMeasured("image-reference-import", probe: layoutProbe)

        Button {
            guard let documentID else { return }
            Task { await model.useSelectedImageReference(documentID: documentID, navigationEpoch: navigationEpoch) }
        } label: {
            Label(consistencyText(consistencyLanguage, "remaining.762cf05d29a5"), systemImage: "photo.badge.plus")
        }
        .disabled(!model.canUseSelectedImageReference || documentID == nil)
        .accessibilityIdentifier("image-reference-use-selected")
        .imageReferenceActionMeasured("image-reference-use-selected", probe: layoutProbe)

        Button(role: .destructive) {
            guard let documentID else { return }
            Task { await model.clearImageReference(documentID: documentID, navigationEpoch: navigationEpoch) }
        } label: {
            Label(consistencyText(consistencyLanguage, "remaining.66f62c0a690e"), systemImage: "xmark.circle")
        }
        .disabled(model.isChangingProject || model.referenceImageAsset == nil || documentID == nil)
        .accessibilityIdentifier("image-reference-clear")
        .imageReferenceActionMeasured("image-reference-clear", probe: layoutProbe)
    }

    private var currentReferenceText: String {
        Self.currentReferenceText(asset: model.referenceImageAsset, language: consistencyLanguage)
    }

    static func currentReferenceText(asset: ProjectAsset?, language: UILanguageStore?) -> String {
        guard let asset else { return consistencyText(language, "remaining.60d50cf29332") }
        let dimensions: String
        if let width = asset.metadata.width, let height = asset.metadata.height {
            dimensions = "（\(width) × \(height)）"
        } else {
            dimensions = consistencyText(language, "remaining.a05de6cc421b")
        }
        return consistencyText(language, "remaining.a034c683bb82", arguments: ["v0": String(describing: asset.name), "v1": String(describing: dimensions)])
    }

    static func submittedReferenceText(job: ProjectJob, manifest: ProjectManifest?, language: UILanguageStore?) -> String? {
        guard case .image(let image) = job.request.input,
              let reference = image.referenceImage else { return nil }
        let name = job.imageReferenceAssetID.flatMap { id in
            manifest?.assets.first(where: { $0.id == id })?.name
        } ?? consistencyText(language, "remaining.8df8abc32ddd")
        return consistencyText(language, "remaining.d41a00626f32", arguments: ["v0": String(describing: name), "v1": String(describing: reference.sha256), "v2": String(describing: reference.width), "v3": String(describing: reference.height), "v4": String(describing: reference.encoding)])
    }
}

private extension View {
    func imageReferenceActionMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("image-reference-scroll")) } action: { probe?(id, $0) }
    }
}

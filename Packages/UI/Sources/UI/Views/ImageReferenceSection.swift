import DInference
import DWorkbench
import SwiftUI

/// Renders the editable image-reference draft. The project session owns the reference ID;
/// this view deliberately has no separate selection, task, or persistence state.
struct ImageReferenceSection: View {
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
            Label("参考图片", systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.semibold))
            Text(currentReferenceText)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("image-reference-current")
            Text("根据参考图和描述生成新候选，原图会保留。模型可能同时改变其他区域，不能保证精确的局部修改。")
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
            Label("导入 PNG…", systemImage: "square.and.arrow.down")
        }
        .disabled(model.isChangingProject || documentID == nil)
        .accessibilityIdentifier("image-reference-import")
        .imageReferenceActionMeasured("image-reference-import", probe: layoutProbe)

        Button {
            guard let documentID else { return }
            Task { await model.useSelectedImageReference(documentID: documentID, navigationEpoch: navigationEpoch) }
        } label: {
            Label("使用已选图片", systemImage: "photo.badge.plus")
        }
        .disabled(!model.canUseSelectedImageReference || documentID == nil)
        .accessibilityIdentifier("image-reference-use-selected")
        .imageReferenceActionMeasured("image-reference-use-selected", probe: layoutProbe)

        Button(role: .destructive) {
            guard let documentID else { return }
            Task { await model.clearImageReference(documentID: documentID, navigationEpoch: navigationEpoch) }
        } label: {
            Label("移除参考", systemImage: "xmark.circle")
        }
        .disabled(model.isChangingProject || model.referenceImageAsset == nil || documentID == nil)
        .accessibilityIdentifier("image-reference-clear")
        .imageReferenceActionMeasured("image-reference-clear", probe: layoutProbe)
    }

    private var currentReferenceText: String {
        Self.currentReferenceText(asset: model.referenceImageAsset)
    }

    static func currentReferenceText(asset: ProjectAsset?) -> String {
        guard let asset else { return "未选择参考图片。" }
        let dimensions: String
        if let width = asset.metadata.width, let height = asset.metadata.height {
            dimensions = "（\(width) × \(height)）"
        } else {
            dimensions = "（尺寸未知）"
        }
        return "当前草稿：\(asset.name)\(dimensions)。"
    }

    static func submittedReferenceText(job: ProjectJob, manifest: ProjectManifest?) -> String? {
        guard case .image(let image) = job.request.input,
              let reference = image.referenceImage else { return nil }
        let name = job.imageReferenceAssetID.flatMap { id in
            manifest?.assets.first(where: { $0.id == id })?.name
        } ?? "已提交参考图片"
        return "本次提交的参考：\(name)；SHA-256 \(reference.sha256)，\(reference.width) × \(reference.height)，\(reference.encoding)。"
    }
}

private extension View {
    func imageReferenceActionMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("image-reference-scroll")) } action: { probe?(id, $0) }
    }
}

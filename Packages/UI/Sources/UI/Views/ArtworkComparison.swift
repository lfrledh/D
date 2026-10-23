import DInference
import DWorkbench
import SwiftUI

/// Comparison only changes presentation. Neither the document selection nor saved recipes are edited.
struct ArtworkComparison: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    @Bindable var model: WorkbenchModel
    @State private var zoom: ArtworkZoom = .fit
    @State private var pan = CGPoint(x: 0.5, y: 0.5)

    private var assets: [ProjectAsset] {
        model.comparisonAssetIDs.compactMap { id in model.manifest?.assets.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(consistencyText(consistencyLanguage, "remaining.e0fab102b11b"), systemImage: "xmark") { Task { await model.endComparison() } }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("end-comparison")
                Spacer()
                WorkbenchGlassSegments(title: consistencyText(consistencyLanguage, "remaining.b762aec769a3"), selection: $zoom,
                    choices: ArtworkZoom.allCases.map { ($0, $0 == .fit ? workflowText(consistencyLanguage, "workbench.zoom.fit") : $0.rawValue) }, owner: AnyHashable(model.comparisonAssetIDs))
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("comparison-zoom")
                Button(consistencyText(consistencyLanguage, "remaining.4cc3885c182e")) { pan = CGPoint(x: 0.5, y: 0.5) }
                    .accessibilityIdentifier("comparison-center")
            }.padding(12)
            Divider()
            HStack(spacing: 1) {
                ForEach(assets, id: \.id) { asset in
                    VStack(spacing: 0) {
                        Text(asset.name).font(.headline).lineLimit(2).padding(10)
                        ComparisonImage(url: model.assetURLs[asset.id], zoom: zoom, pan: $pan)
                            .accessibilityLabel(consistencyText(consistencyLanguage, "remaining.84082c2d5ae6", arguments: ["v0": String(describing: asset.name)]))
                            .accessibilityIdentifier("comparison-image-\(asset.id.uuidString)")
                        conditions(for: asset)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(consistencyText(consistencyLanguage, "remaining.f9e79300d683"))
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: zoom) { _, _ in pan = CGPoint(x: 0.5, y: 0.5) }
    }

    private func imageRequest(for asset: ProjectAsset) -> ImageRequest? {
        guard let job = model.manifest?.jobs.first(where: { $0.id == asset.jobID }),
              case .image(let image) = job.request.input else { return nil }
        return image
    }

    @ViewBuilder private func conditions(for asset: ProjectAsset) -> some View {
        if let request = imageRequest(for: asset) {
            let other = assets.first { $0.id != asset.id }.flatMap { imageRequest(for: $0) }
            VStack(alignment: .leading, spacing: 6) {
                Text(other?.prompt == request.prompt ? consistencyText(consistencyLanguage, "remaining.45fb7e799c32") : consistencyText(consistencyLanguage, "remaining.c2db9393fbed"))
                    .font(.caption.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(other?.prompt == request.prompt ? consistencyText(consistencyLanguage, "remaining.45fb7e799c32") : consistencyText(consistencyLanguage, "remaining.c2db9393fbed"))
                    .accessibilityIdentifier("comparison-prompt-difference-\(asset.id.uuidString)")
                ScrollView { Text(request.prompt).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 64)
                Text(consistencyText(consistencyLanguage, "remaining.ce691302fdb6", arguments: ["v0": String(describing: request.seed), "v1": String(describing: other?.seed == request.seed ? consistencyText(consistencyLanguage, "comparison.same") : consistencyText(consistencyLanguage, "comparison.different"))]))
                    .font(.caption).monospacedDigit().textSelection(.enabled)
                Text(consistencyText(consistencyLanguage, "remaining.71fd832f021e", arguments: ["v0": String(describing: request.width), "v1": String(describing: request.height), "v2": String(describing: request.steps)]))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)

        } else {
            Text(consistencyText(consistencyLanguage, "remaining.b8dd3e43bb41")).font(.caption).padding(12)
        }
    }
}

private struct ComparisonImage: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    let url: URL?
    let zoom: ArtworkZoom
    @Binding var pan: CGPoint
    @State private var image: CGImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image {
                PixelCanvas(image: image, zoom: zoom, synchronizedPan: $pan)
            } else if loading {
                ProgressView(consistencyText(consistencyLanguage, "remaining.5dfcd69c12fb"))
            } else {
                ContentUnavailableView(consistencyText(consistencyLanguage, "remaining.7ac3c0e49862"), systemImage: "photo.badge.exclamationmark",
                    description: Text(consistencyText(consistencyLanguage, "remaining.5d0f7e9c434c")))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            loading = true
            image = nil
            let result: CGImage?
            if let url { result = await ArtworkPreviewDecoder.shared.decode(url, thumbnail: false) }
            else { result = nil }
            guard !Task.isCancelled else { return }
            image = result
            loading = false
        }
    }
}

import DInference
import DWorkbench
import SwiftUI

/// Comparison only changes presentation. Neither the document selection nor saved recipes are edited.
struct ArtworkComparison: View {
    @Bindable var model: WorkbenchModel
    @State private var zoom: ArtworkZoom = .fit
    @State private var pan = CGPoint(x: 0.5, y: 0.5)

    private var assets: [ProjectAsset] {
        model.comparisonAssetIDs.compactMap { id in model.manifest?.assets.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("结束比较", systemImage: "xmark") { Task { await model.endComparison() } }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("end-comparison")
                Spacer()
                Picker("缩放", selection: $zoom) {
                    ForEach(ArtworkZoom.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 180)
                    .accessibilityIdentifier("comparison-zoom")
                Button("居中") { pan = CGPoint(x: 0.5, y: 0.5) }
                    .accessibilityIdentifier("comparison-center")
            }.padding(12)
            Divider()
            HStack(spacing: 1) {
                ForEach(assets, id: \.id) { asset in
                    VStack(spacing: 0) {
                        Text(asset.name).font(.headline).lineLimit(2).padding(10)
                        ComparisonImage(url: model.assetURLs[asset.id], zoom: zoom, pan: $pan)
                            .accessibilityLabel("比较作品：\(asset.name)")
                            .accessibilityIdentifier("comparison-image-\(asset.id.uuidString)")
                        conditions(for: asset)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("100% 时拖动任一图片，同步查看相同相对位置。比较不会修改作品或草稿。")
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
                Text(other?.prompt == request.prompt ? "提示词相同" : "提示词不同")
                    .font(.caption.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(other?.prompt == request.prompt ? "提示词相同" : "提示词不同")
                    .accessibilityIdentifier("comparison-prompt-difference-\(asset.id.uuidString)")
                ScrollView { Text(request.prompt).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 64)
                Text("实际 Seed：\(request.seed) · \(other?.seed == request.seed ? "相同" : "不同")")
                    .font(.caption).monospacedDigit().textSelection(.enabled)
                Text("\(request.width) × \(request.height) · \(request.steps) 步")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)

        } else {
            Text("原始生成条件不可用").font(.caption).padding(12)
        }
    }
}

private struct ComparisonImage: View {
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
                ProgressView("正在读取作品…")
            } else {
                ContentUnavailableView("作品暂时无法读取", systemImage: "photo.badge.exclamationmark",
                    description: Text("请连接项目所在磁盘并重新打开项目。作品记录仍会保留。"))
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

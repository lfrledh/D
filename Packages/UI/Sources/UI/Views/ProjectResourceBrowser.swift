import AppKit
import DWorkbench
import ImageIO
import SwiftUI

/// Internal test hook. These closures mutate the same state and invoke the same
/// open action as the rendered controls; they do not simulate a separate model.
struct ProjectResourceBrowserTestingActions {
    let select: (ProjectResourceID?) -> Void
    let setIncludeOtherModes: (Bool) -> Void
    let openSelected: () -> Void
    let selectedAudioDescription: () -> String?
}

@MainActor
public struct ProjectResourceBrowser: View {
    private let manifest: ProjectManifest
    private let mode: CreatorMode
    private let availableModes: [CreatorMode]
    private let assetURL: (UUID) -> URL?
    private let onOpenDocument: (UUID) -> Void

    @State private var includesOtherModes = false
    @State private var selectedID: ProjectResourceID?
    private var layoutProbe: ((String, CGRect) -> Void)?
    private var testingActions: ((ProjectResourceBrowserTestingActions) -> Void)?

    public init(manifest: ProjectManifest, mode: CreatorMode, availableModes: [CreatorMode],
                assetURL: @escaping (UUID) -> URL?, onOpenDocument: @escaping (UUID) -> Void) {
        self.manifest = manifest
        self.mode = mode
        self.availableModes = availableModes
        self.assetURL = assetURL
        self.onOpenDocument = onOpenDocument
    }

    private var resources: [ProjectResourceItem] {
        ProjectResourceCatalog.items(in: manifest, mode: mode, includeOtherModes: includesOtherModes)
    }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 420 {
                VStack(spacing: 0) {
                    resourceList
                        .frame(maxWidth: .infinity, maxHeight: max(120, geometry.size.height * 0.48))
                    Divider()
                    resourcePreview
                }
            } else {
                HStack(spacing: 0) {
                    resourceList.frame(width: min(210, geometry.size.width * 0.42))
                    Divider()
                    resourcePreview
                }
            }
        }
        .onChange(of: includesOtherModes) { _, _ in resetSelection() }
        .onChange(of: manifest.id) { _, _ in
            includesOtherModes = false
            resetSelection()
        }
        .onChange(of: mode) { _, next in
            includesOtherModes = false
            resetSelection()
        }
        .coordinateSpace(name: "project-resource-layout")
        .onAppear {
            testingActions?(ProjectResourceBrowserTestingActions(
                select: { selectedID = $0 }, setIncludeOtherModes: { includesOtherModes = $0 },
                openSelected: { open(selectedItem) },
                selectedAudioDescription: { selectedAsset?.metadata.audio.map { recordedAudioDescription($0) } }
            ))
        }
    }

    /// Internal rendered-geometry observation used by native layout tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    func observingActions(_ observer: @escaping (ProjectResourceBrowserTestingActions) -> Void) -> Self {
        var copy = self
        copy.testingActions = observer
        return copy
    }

    private var resourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("也显示其他模态", isOn: $includesOtherModes)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assets-filter-other")
                .resourceMeasured("assets-filter-other", probe: layoutProbe)
            List(resources, selection: $selectedID) { item in
                ResourceRow(item: item)
                    .tag(item.id)
                    .accessibilityIdentifier(resourceIdentifier(item.id))
                    .resourceMeasured(resourceIdentifier(item.id), probe: layoutProbe)
            }
            .listStyle(.sidebar)
        }
        .padding(10)
    }

    private var resourcePreview: some View {
        ScrollView {
            ResourcePreview(item: selectedItem, asset: selectedAsset, assetURL: assetURL,
                            originIsAvailable: originIsAvailable, onOpen: open)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .accessibilityIdentifier("asset-preview")
        .resourceMeasured("asset-preview", probe: layoutProbe)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedItem: ProjectResourceItem? {
        guard let selectedID else { return nil }
        return resources.first { $0.id == selectedID }
    }

    private var selectedAsset: ProjectAsset? {
        guard case .media(let id) = selectedID else { return nil }
        return manifest.assets.first { $0.id == id }
    }

    private func originIsAvailable(_ id: UUID) -> Bool {
        guard let document = manifest.documents.first(where: { $0.id == id }) else { return false }
        return availableModes.contains(CreatorMode(document.kind))
    }

    private func resetSelection() { selectedID = nil }

    private func open(_ item: ProjectResourceItem?) {
        guard let item else { return }
        switch item.id {
        case .document(let documentID): onOpenDocument(documentID)
        case .media:
            guard let origin = item.originDocumentID, originIsAvailable(origin) else { return }
            onOpenDocument(origin)
        }
    }

    private func resourceIdentifier(_ id: ProjectResourceID) -> String {
        switch id {
        case .media(let id): "resource-media-\(id.uuidString)"
        case .document(let id): "resource-document-\(id.uuidString)"
        }
    }
}

private struct ResourceRow: View {
    let item: ProjectResourceItem

    var body: some View {
        Label {
            Text(item.title).lineLimit(2)
        } icon: {
            Image(systemName: symbol)
        }
    }

    private var symbol: String {
        if item.textPreview != nil { return "doc.text" }
        if item.mediaType.hasPrefix("image/") { return "photo" }
        if item.mediaType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}

private struct ResourcePreview: View {
    let item: ProjectResourceItem?
    let asset: ProjectAsset?
    let assetURL: (UUID) -> URL?
    let originIsAvailable: (UUID) -> Bool
    let onOpen: (ProjectResourceItem?) -> Void
    @State private var image: NSImage?
    @State private var imageUnavailable = false

    var body: some View {
        Group {
            if let item {
                preview(item)
            } else {
                ContentUnavailableView("选择一项资产", systemImage: "square.stack.3d.up")
            }
        }
    }

    @ViewBuilder private func preview(_ item: ProjectResourceItem) -> some View {
        if let text = item.textPreview, case .document(let documentID) = item.id {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title2.weight(.semibold))
                Text(text.prefix(8_192)).textSelection(.enabled)
                if text.count > 8_192 { Text("仅显示正文前 8,192 个字符。").font(.caption).foregroundStyle(.secondary) }
                Button("打开文稿") { onOpen(item) }
                    .accessibilityIdentifier("resource-open-document-\(documentID.uuidString)")
            }
        } else if let asset {
            assetPreview(item: item, asset: asset)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.title2.weight(.semibold))
                Text("这是项目中的创作文稿引用；此处不生成路径或摘要。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func assetPreview(item: ProjectResourceItem, asset: ProjectAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.title2.weight(.semibold))
            Text("记录的 MIME：\(asset.mediaType)").font(.callout).foregroundStyle(.secondary)
            if isCommonImage(asset.mediaType) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 500)
                } else if imageUnavailable {
                    ContentUnavailableView("图片不可用", systemImage: "photo.badge.exclamationmark",
                                           description: Text("没有可读取的授权本地文件，或文件超过预览预算。"))
                } else {
                    ProgressView("正在读取本地预览…")
                }
            } else if isKnownAudio(asset.mediaType) {
                Text(recordedAudioDescription(asset.metadata.audio))
                    .foregroundStyle(.secondary)
                Text("音频不会在资产浏览器中自动播放。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("不能预览此格式", systemImage: "doc.questionmark",
                                       description: Text("只保留记录的 MIME；未知格式不会按扩展名猜测，也不会读取 URL。"))
            }
            if let origin = item.originDocumentID, originIsAvailable(origin) {
                Button("打开来源文稿") { onOpen(item) }
                    .accessibilityIdentifier("asset-open-origin-\(origin.uuidString)")
            }
        }
        .task(id: asset.id) { await loadImageIfAllowed(asset) }
    }

    private func isCommonImage(_ type: String) -> Bool {
        ["image/png", "image/jpeg", "image/tiff"].contains(type.lowercased())
    }

    private func isKnownAudio(_ type: String) -> Bool {
        ["audio/wav", "audio/x-wav", "audio/wave", "audio/x-caf", "audio/mpeg", "audio/flac"].contains(type.lowercased())
    }

    private func loadImageIfAllowed(_ asset: ProjectAsset) async {
        image = nil
        imageUnavailable = false
        guard isCommonImage(asset.mediaType), let url = assetURL(asset.id), url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 32 * 1_024 * 1_024 else {
            imageUnavailable = true
            return
        }
        image = boundedThumbnail(url)
        imageUnavailable = image == nil
    }

    private func boundedThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 20_000, height <= 20_000, width * height <= 20_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

private func recordedAudioDescription(_ metadata: AudioAssetMetadata?) -> String {
    guard let metadata else { return "没有记录可用的音频元数据。" }
    let format = metadata.format
    return "记录的音频：\(format.container.rawValue.uppercased()) · \(Int(format.sampleRate)) Hz · \(format.channelCount) 声道 · \(format.frameCount) 帧"
}

private extension View {
    func resourceMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("project-resource-layout")) } action: {
            probe?(id, $0)
        }
    }
}

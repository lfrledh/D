import AVFoundation
import DWorkbench
import ImageIO
import SwiftUI

/// Owned by one browser state. At most two reads/decodes and 64 / 32 MiB retained images.
actor WorkflowLibraryPreviewCache {
    struct Preview: Sendable {
        var image: CGImage?
        var excerpt: String?
        var duration: Double?
        var cost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    }
    private struct Entry { var preview: Preview; var used: UInt64 }
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private var active = 0
    private var posterGenerators: [UUID: AVAssetImageGenerator] = [:]
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: i).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancelPoster(_ id: UUID) { posterGenerators[id]?.cancelAllCGImageGeneration() }
    func preview(version: String?, pixels requested: Int, load: @MainActor @Sendable () async throws -> ProjectReadOnlyContent) async throws -> Preview {
        try await acquire(UUID()); defer { release() }
        let pixels = min(1024, max(160, requested))
        let key = version.map { $0 + "/\(pixels)" }
        tick &+= 1
        if let key, var hit = entries[key] { hit.used = tick; entries[key] = hit; return hit.preview }
        let content = try await load(); try Task.checkCancellation()
        let token = content.token
        var result = Preview()
        if token.kind == .image {
            guard let source = CGImageSourceCreateWithData(content.data as CFData, nil) else { throw WorkflowIssue("图像无法读取。") }
            result.image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
            guard result.image != nil else { throw WorkflowIssue("图像预览无法解码。") }
        } else if token.kind == .video {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("D-Poster-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("preview.mp4")
            try content.data.write(to: url, options: .withoutOverwriting)
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: pixels, height: pixels); generator.appliesPreferredTrackTransform = true
            defer { generator.cancelAllCGImageGeneration() }
            let posterID = UUID(); posterGenerators[posterID] = generator
            defer { posterGenerators.removeValue(forKey: posterID) }
            result.image = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, result, error in
                        if result == .succeeded, let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? CancellationError()) }
                    }
                }
            } onCancel: { Task { await self.cancelPoster(posterID) } }
            let seconds = try await asset.load(.duration).seconds
            if seconds.isFinite, seconds >= 0 { result.duration = seconds }
        } else if let text = content.text { result.excerpt = String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ") }
        try Task.checkCancellation()
        if let key { entries[key] = .init(preview: result, used: tick) }
        while entries.count > 64 || entries.values.reduce(0, { $0 + $1.preview.cost }) > 32 * 1_024 * 1_024 {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
        return result
    }
}

struct WorkflowLibraryPreview: View {
    let entry: SharedLibraryBrowserEntry
    let cache: WorkflowLibraryPreviewCache
    let pixels: Int
    let load: @MainActor @Sendable () async throws -> ProjectReadOnlyContent
    @Environment(\.workbenchContentVisible) private var visible
    @Environment(\.dLanguageStore) private var language
    @State private var preview: WorkflowLibraryPreviewCache.Preview?
    @State private var failure: String?
    @State private var retry = 0
    private var version: String? {
        if let runtime = entry.runtimeValue, let reference = runtime.reference {
            return "\(runtime.projectID)/\(runtime.instanceID)/\(reference.assetID)/\(reference.sha256)"
        }
        guard let snapshot = entry.metadataSnapshot,
              let hash = snapshot.record?.reference.sha256 ?? snapshot.asset.metadata.imageContentSHA256
                ?? snapshot.asset.metadata.audio?.contentSHA256 ?? snapshot.asset.metadata.video?.contentSHA256
                ?? snapshot.asset.fileLocations?.sha256 else { return nil }
        return "\(snapshot.projectID)/\(snapshot.instanceID)/\(snapshot.asset.id)/\(hash)"
    }
    private var identity: String { entry.id + "/" + (version ?? "unverified") + "/\(pixels)/\(retry)/\(visible)" }
    var body: some View {
        ZStack {
            if let image = preview?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                if let seconds = preview?.duration {
                    Text(String(format: "%.1f s", seconds)).font(.caption.monospacedDigit()).padding(4)
                        .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            } else if let excerpt = preview?.excerpt { Text(excerpt).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
            else if failure != nil {
                Button { retry += 1 } label: { Label(workflowText(language, "workflow.preview.retry"), systemImage: "arrow.clockwise") }.font(.caption).help(failure ?? "")
            } else { Image(systemName: entry.item.contentKind == .video ? "film" : entry.item.contentKind == .text ? "text.alignleft" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: identity) {
            preview = nil; failure = nil
            guard visible else { return }
            do {
                if case .data(.text(let value)) = entry.runtimeValue?.value {
                    preview = .init(excerpt: String(value.prefix(300))); return
                }
                if case .collection(let values) = entry.runtimeValue?.value {
                    preview = .init(excerpt: "\(values.count) · " + (entry.item.detail)); return
                }
                let result = try await cache.preview(version: version, pixels: pixels, load: load)
                try Task.checkCancellation(); preview = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

import AppKit
import AVKit
import DWorkbench
import SwiftUI

/// A bounded preview; zoom and pan never change an asset or the next request.
struct QuickMediaViewport: View {
    let store: ProjectStore
    let reference: WorkflowAssetReference
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var issue: String?
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack {
                    Color.primary.opacity(0.04)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(zoom * magnification)
                            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                    } else if let player {
                        VideoPlayer(player: player).frame(width: proxy.size.width, height: proxy.size.height)
                    } else if let issue { Text(issue).foregroundStyle(.red).padding().textSelection(.enabled) }
                    else { ProgressView("正在读取预览…") }
                }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($dragOffset) { value, state, _ in
                        if image != nil && zoom > 1 { state = value.translation }
                    }.onEnded { value in
                        if image != nil && zoom > 1 {
                            offset.width += value.translation.width; offset.height += value.translation.height
                        }
                    }, including: image == nil ? .none : .all)
                    .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                        if image != nil { state = value.magnification }
                    }.onEnded { value in
                        if image != nil { zoom = min(12, max(1, zoom * value.magnification)) }
                    }, including: image == nil ? .none : .all)
                    .accessibilityIdentifier("quick-media-viewport")
            }.frame(minHeight: 100)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if image != nil {
                HStack {
                    Spacer()
                    Button("缩小", systemImage: "minus") { zoom = max(1, zoom / 1.25); if zoom == 1 { offset = .zero } }.labelStyle(.iconOnly)
                    Text("\(Int(zoom * 100))%").monospacedDigit().font(.caption)
                    Button("放大", systemImage: "plus") { zoom = min(12, zoom * 1.25) }.labelStyle(.iconOnly)
                    Button("适合窗口", systemImage: "arrow.up.left.and.arrow.down.right") { zoom = 1; offset = .zero }
                        .accessibilityIdentifier("quick-media-fit")
                }
            }
        }
        .task(id: reference) {
            player?.pause(); player = nil; image = nil; issue = nil; zoom = 1; offset = .zero
            do {
                if reference.kind == .video || reference.kind == .audio {
                    let (url, _) = try await store.workflowMedia(reference)
                    try Task.checkCancellation()
                    player = AVPlayer(url: url)
                } else if reference.kind == .image {
                    let data = try await store.workflowData(reference)
                    try Task.checkCancellation()
                    guard let decoded = NSImage(data: data) else { throw WorkflowIssue("图像不可读取；原素材仍保留。") }
                    image = decoded
                } else { issue = "该结果请从详情查看。" }
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
        .onDisappear { player?.pause() }
    }
}

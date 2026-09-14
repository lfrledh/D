import AVFoundation
import AVKit
import SwiftUI

/// A local, host-authorized preview.  It neither discovers files nor starts playback itself.
public struct VideoPreview: View {
    public let url: URL?
    public let identity: UUID
    @State private var session = Session()

    public init(url: URL?, identity: UUID) {
        self.url = url
        self.identity = identity
    }

    init(url: URL?, identity: UUID, session: Session) {
        self.url = url
        self.identity = identity
        _session = State(initialValue: session)
    }

    public var body: some View {
        PlayerSurface(url: url, identity: identity, session: session)
            .onDisappear { session.stopAndClear() }
    }

    public final class Session {
        let player = AVPlayer()
        private var activeURL: URL?
        private var activeIdentity: UUID?
        private var activeAsset: AVURLAsset?
        private(set) var replacementCount = 0
        private let assetFactory: (URL) -> AVURLAsset
        private let cancelAssetLoading: (AVURLAsset) -> Void

        init(assetFactory: @escaping (URL) -> AVURLAsset = { AVURLAsset(url: $0) },
             cancelAssetLoading: @escaping (AVURLAsset) -> Void = { $0.cancelLoading() }) {
            self.assetFactory = assetFactory
            self.cancelAssetLoading = cancelAssetLoading
        }

        func replace(url: URL?, identity: UUID) {
            guard activeURL != url || activeIdentity != identity else { return }
            stopAndClear()
            activeURL = url
            activeIdentity = identity
            guard let url, url.isFileURL else { return }
            let asset = assetFactory(url)
            activeAsset = asset
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.pause()
            replacementCount += 1
        }

        func stopAndClear() {
            player.pause()
            if let activeAsset { cancelAssetLoading(activeAsset) }
            activeAsset = nil
            player.replaceCurrentItem(with: nil)
            activeURL = nil
            activeIdentity = nil
        }
    }

    private struct PlayerSurface: NSViewRepresentable {
        let url: URL?
        let identity: UUID
        let session: Session

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .floating
            view.player = session.player
            session.replace(url: url, identity: identity)
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            session.replace(url: url, identity: identity)
            if view.player !== session.player { view.player = session.player }
        }

        static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
        }
    }
}

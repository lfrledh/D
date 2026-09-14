import Foundation
import AppKit
import SwiftUI
import Testing
@testable import UI

@Suite("Video preview", .serialized)
@MainActor
struct VideoPreviewTests {
    @Test
    func replacingIdentityStopsAndReplacesTheCurrentItemWithoutAutoplay() {
        let session = VideoPreview.Session()
        let first = URL(fileURLWithPath: "/fixtures/first.mp4")
        let second = URL(fileURLWithPath: "/fixtures/second.mp4")
        let identity = UUID()
        session.replace(url: first, identity: identity)
        #expect(session.player.currentItem != nil)
        #expect(session.player.rate == 0)
        #expect(session.replacementCount == 1)
        session.replace(url: first, identity: identity)
        #expect(session.replacementCount == 1)
        session.replace(url: first, identity: UUID())
        #expect(session.player.currentItem != nil)
        #expect(session.player.rate == 0)
        #expect(session.replacementCount == 2)
        session.replace(url: second, identity: UUID())
        #expect(session.replacementCount == 3)
        session.stopAndClear()
        #expect(session.player.currentItem == nil)
    }

    @Test
    func nilURLClearsAnExistingPreview() {
        let session = VideoPreview.Session()
        session.replace(url: URL(fileURLWithPath: "/fixtures/fixture.mp4"), identity: UUID())
        session.replace(url: nil, identity: UUID())
        #expect(session.player.currentItem == nil)
        session.replace(url: URL(string: "https://example.invalid/fixture.mp4"), identity: UUID())
        #expect(session.player.currentItem == nil)
    }

    @Test
    func removingHostedPreviewClearsItemAndCancelsItsOldAsset() async throws {
        var cancelled = 0
        let session = VideoPreview.Session(cancelAssetLoading: { _ in cancelled += 1 })
        let root = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let view = VideoPreview(url: URL(fileURLWithPath: root).appendingPathComponent("preview-fixture.mp4"),
                                identity: UUID(), session: session)
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.player.currentItem != nil)
        #expect(session.replacementCount == 1)
        host.rootView = AnyView(EmptyView())
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.player.currentItem == nil)
        #expect(cancelled == 1)
    }
}

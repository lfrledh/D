import Foundation
import Testing
@testable import SwiftStreamingMarkdown

@Suite("Chat code appearance updates", .timeLimit(.minutes(1)))
@MainActor struct ChatCodeHighlightTests {
    @Test func pendingAppearanceKeepsItsOwnCompletionAndCoalesces() async {
        let renderer = ControlledHighlighter()
        let manager = HighlightTaskManager { code, _ in await renderer.render(code) }
        let (events, continuation) = AsyncStream<String>.makeStream()
        let colors = CodeBlockConfig.Theme.xcode.highlightColors(for: .light)
        await manager.enqueueCode("light", colors: colors) {
            continuation.yield("light callback: " + String($0.characters))
        }
        await renderer.waitUntilStarted("light")
        await manager.enqueueCode("superseded", colors: colors) { _ in
            continuation.yield("unexpected superseded callback")
        }
        await manager.enqueueCode("dark", colors: CodeBlockConfig.Theme.xcode.highlightColors(for: .dark)) {
            continuation.yield("dark callback: " + String($0.characters))
        }
        await renderer.finish("light")
        await renderer.waitUntilStarted("dark")
        await renderer.finish("dark")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == "light callback: light")
        #expect(await iterator.next() == "dark callback: dark")
        #expect(await renderer.started == ["light", "dark"])
        continuation.finish()
    }
}

private actor ControlledHighlighter {
    private(set) var started: [String] = []
    private var jobs: [String: CheckedContinuation<AttributedString?, Never>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]

    func render(_ code: String) async -> AttributedString? {
        await withCheckedContinuation { continuation in
            jobs[code] = continuation
            started.append(code)
            observers.removeValue(forKey: code)?.resume()
        }
    }

    func waitUntilStarted(_ code: String) async {
        if started.contains(code) { return }
        await withCheckedContinuation { observers[code] = $0 }
    }

    func finish(_ code: String) {
        jobs.removeValue(forKey: code)?.resume(returning: AttributedString(code))
    }
}

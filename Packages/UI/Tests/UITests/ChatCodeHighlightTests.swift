import Foundation
import AppKit
import SwiftUI
import Testing
@testable import SwiftStreamingMarkdown

@Suite("Chat code appearance updates", .timeLimit(.minutes(1)))
@MainActor struct ChatCodeHighlightTests {
    @Test func nativeCodeKeepsSelectionAndHighlightAcrossWidthChanges() throws {
        let code = "// 🛶\n\n" + (1...45).map { "let sample\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let fonts = TextFonts(normal: font, italic: nil, bold: nil, boldItalic: nil,
                              preferredLetterSpacing: nil, preferredLineHeight: nil)
        var highlighted = AttributedString(code)
        highlighted.foregroundColor = .systemGreen
        let host = NSHostingView(rootView: CodeBlockNativeText(content: highlighted, fonts: fonts, foreground: .labelColor).frame(width: 500))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 1000)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { find($0) }.first
        }
        let text = try #require(find(host))
        let range = (code as NSString).range(of: "sample30")
        text.setSelectedRange(range)
        let wideHeight = host.fittingSize.height
        #expect(text.isSelectable && !text.isEditable)
        #expect(text.string == code)
        #expect(wideHeight > 45 * 12)
        highlighted.foregroundColor = .systemOrange
        host.rootView = CodeBlockNativeText(content: highlighted, fonts: fonts, foreground: .white).frame(width: 100)
        host.frame.size.width = 100
        host.layoutSubtreeIfNeeded()
        #expect(find(host) === text)
        #expect(text.string == code && text.selectedRange() == range)
        #expect(host.fittingSize.height > wideHeight)
        #expect(text.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .systemOrange)
        #expect(text.intrinsicContentSize.height == NSView.noIntrinsicMetric)
        let unwrapped = NSHostingView(rootView: CodeBlockNativeText(content: highlighted, fonts: fonts, foreground: .white)
            .fixedSize(horizontal: true, vertical: true))
        unwrapped.frame = NSRect(x: 0, y: 0, width: 100, height: 1000)
        unwrapped.layoutSubtreeIfNeeded()
        #expect(unwrapped.fittingSize.width > 100)
        #expect(unwrapped.fittingSize.height == wideHeight)
        #expect(find(unwrapped)?.string == code)

    }

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

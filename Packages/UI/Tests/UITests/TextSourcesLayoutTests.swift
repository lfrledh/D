import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct TextSourcesLayoutTests {
    @Test func resizeKeepsQuestionEditorIdentityAndReachableScrollViewport() throws {
        let note = TextSourcesNotebook(question: "中文 e\u{301}👩‍💻")
        let view = TextSourcesView(notebook: note, partialAnswer: "", isRunning: false, isCancelling: false,
            isSaving: false, canAsk: false, canUndo: false, errorMessage: nil, canAccept: { _ in false },
            citationSummary: { _ in "未验证" }, actions: .init(importSource: {}, removeSource: { _ in },
                useExcerpt: { _, _ in }, changeQuestion: { _ in }, ask: {}, cancel: {}, accept: { _ in },
                reject: { _ in }, undo: {}, save: {}))
        let host = NSHostingView(rootView: view)
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        func settle(_ width: CGFloat) {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded()
        }
        settle(900)
        let first = try #require(descendants(host).compactMap { $0 as? NSTextView }.filter { $0.isEditable }.first)
        for width: CGFloat in [600, 1000, 500, 800] {
            settle(width)
            let current = try #require(descendants(host).compactMap { $0 as? NSTextView }.filter { $0.isEditable }.first)
            #expect(current === first, "Width changes must not replace a question editor that may have an IME composition.")
            #expect(current.string.utf8.elementsEqual(note.question.utf8))
            #expect(host.fittingSize.width <= width + 1)
            let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
            let visibleScroll = scrolls.contains { scroll in
                let rect = scroll.convert(scroll.bounds, to: host)
                return rect.width > 100 && rect.height > 50 && rect.minX >= -1 && rect.maxX <= width + 1 &&
                    rect.minY >= -1 && rect.maxY <= 481
            }
            #expect(visibleScroll, "Content must have a scroll viewport within the actual available bounds.")
        }
    }
}

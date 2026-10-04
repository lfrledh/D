import AppKit
import DWorkbench
import Observation
import SwiftUI
import Testing
import XCTest
@testable import UI

@MainActor @Observable
private final class QuoteSelectionFixture {
    var source: ChatQuoteSource
    var uses: [(ChatQuoteSelection, ChatQuoteSelectionAction)] = []
    @ObservationIgnored var frames: [ChatQuoteSelectionAction: CGRect] = [:]

    init(source: ChatQuoteSource) { self.source = source }
}

@MainActor
private struct QuoteSelectionHarness: View {
    @Bindable var fixture: QuoteSelectionFixture

    var body: some View {
        ChatQuoteSelectionView(source: fixture.source) { selection, action in
            fixture.uses.append((selection, action))
        } actionFrameProbe: { action, frame in fixture.frames[action] = frame }
    }
}

@Suite("Native chat quote selection", .serialized)
@MainActor struct ChatQuoteSelectionViewTests {
    @Test func coordinatorPreservesSelectionForSameSourceAndResetsOnReplacement() throws {
        let id = UUID()
        let first = try ChatQuoteSource(kind: .message, id: id, version: "1", text: "原文👩‍💻e\u{301}")
        let replacement = try ChatQuoteSource(kind: .message, id: id, version: "1", text: "替换正文")
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        let coordinator = ChatQuoteSelectionView.NativeTextView.Coordinator()
        var events: [ChatQuoteSelection?] = []

        coordinator.update(source: first, textView: textView) { events.append($0) }
        #expect(textView.string == first.text)
        #expect(events.count == 1 && events[0] == nil)
        let emoji = (first.text as NSString).range(of: "👩‍💻")
        textView.setSelectedRange(emoji)
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: textView))
        let selected = try #require(events.last ?? nil)
        #expect(selected.text == "👩‍💻")
        #expect(selected.range == emoji)
        try selected.validate(against: first)

        let count = events.count
        coordinator.update(source: first, textView: textView) { events.append($0) }
        #expect(textView.selectedRange() == emoji)
        #expect(events.count == count)

        // The same ID and version with changed raw text must still replace the view.
        coordinator.update(source: replacement, textView: textView) { events.append($0) }
        #expect(textView.string == replacement.text)
        #expect(textView.selectedRange().length == 0)
        #expect((events.last ?? nil) == nil)
        #expect(throws: ChatQuoteSelectionError.sourceChanged) {
            try selected.validate(against: replacement)
        }

        // A queued notification from the previous native view cannot create a
        // quote for the replacement source.
        let oldView = NSTextView()
        oldView.string = first.text
        oldView.setSelectedRange(emoji)
        let afterReset = events.count
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: oldView))
        #expect(events.count == afterReset)
    }

    @Test func coordinatorUsesCurrentCallbackAndDisablesInvalidNativeRanges() throws {
        let source = try ChatQuoteSource(kind: .document, id: UUID(), version: "revision", text: "A👩‍💻Z")
        let textView = NSTextView()
        let coordinator = ChatQuoteSelectionView.NativeTextView.Coordinator()
        var oldCalls = 0
        var received: ChatQuoteSelection?
        coordinator.update(source: source, textView: textView) { _ in oldCalls += 1 }
        coordinator.update(source: source, textView: textView) { received = $0 }
        let emoji = (source.text as NSString).range(of: "👩‍💻")
        textView.setSelectedRange(emoji)
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: textView))
        #expect(oldCalls == 1)
        #expect(received?.text == "👩‍💻")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: textView))
        #expect(received == nil)
        #expect(textView.string == source.text)
    }
}

// This fixture uses XCTest’s synchronous host loop: the observed Swift Testing
// async-main helper exited during event tracking before reporting the method.
@MainActor final class ChatQuoteSelectionHostingTests: XCTestCase {
    private enum ClickFailure: Error { case notDispatched }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func click(_ action: ChatQuoteSelectionAction, fixture: QuoteSelectionFixture, host: NSView) throws {
        let rect = try XCTUnwrap(fixture.frames[action]), window = try XCTUnwrap(host.window)
        XCTAssertTrue(rect.width > 0 && rect.height > 0)
        // SwiftUI's virtual AX elements are absent in this test-process host. Use
        // the production button geometry with the existing process-only event helper.
        let geometry = NSAccessibilityElement()
        geometry.setAccessibilityIdentifier("chat-quote-" + action.rawValue)
        geometry.setAccessibilityFrame(window.convertToScreen(host.convert(rect, to: nil)))
        guard HostingControlClick.send(to: geometry, in: host) else {
            XCTFail("The expected mouse pair was not dispatched")
            throw ClickFailure.notDispatched
        }
    }

    private func settle(_ host: NSView) {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
        }
    }

    private func select(_ range: NSRange, in textView: NSTextView) throws {
        textView.setSelectedRange(range)
        let coordinator = try XCTUnwrap(textView.delegate as? ChatQuoteSelectionView.NativeTextView.Coordinator)
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: textView))
    }

    func testHostedSelectionClearsActionsAfterDeselectOversizeAndSourceReset() throws {
        let raw = "Quote " + String(repeating: "a", count: ChatQuoteSelection.maximumUTF8Bytes + 1)
        let source = try ChatQuoteSource(kind: .document, id: UUID(), version: "v1", text: raw)
        let fixture = QuoteSelectionFixture(source: source)
        let host = NSHostingView(rootView: QuoteSelectionHarness(fixture: fixture))
        host.frame = CGRect(x: 0, y: 0, width: 850, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.isVisible)
        settle(host)
        let textView = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }
            .first { $0.string == source.text })
        XCTAssertTrue(fixture.frames.count == ChatQuoteSelectionAction.allCases.count)

        try select(NSRange(location: 0, length: 5), in: textView)
        settle(host)

        try click(.ask, fixture: fixture, host: host)
        settle(host)
        XCTAssertTrue(fixture.uses.count == 1)
        XCTAssertTrue(fixture.uses.first?.0.text == "Quote")
        XCTAssertTrue(fixture.uses.first?.0.sourceKind == .document)
        XCTAssertTrue(fixture.uses.first?.1 == .ask)

        try select(NSRange(location: 0, length: 0), in: textView)
        settle(host)
        XCTAssertTrue(fixture.frames.count == ChatQuoteSelectionAction.allCases.count)
        try click(.ask, fixture: fixture, host: host)
        settle(host)
        XCTAssertTrue(fixture.uses.count == 1)

        try select(NSRange(location: 0, length: ChatQuoteSelection.maximumUTF8Bytes + 1), in: textView)
        settle(host)
        XCTAssertTrue(fixture.frames.count == ChatQuoteSelectionAction.allCases.count)
        try click(.explain, fixture: fixture, host: host)
        settle(host)
        XCTAssertTrue(fixture.uses.count == 1)

        try select(NSRange(location: 0, length: 5), in: textView)
        settle(host)

        let replacement = try ChatQuoteSource(kind: .document, id: source.id,
                                              version: source.version, text: "Replacement")
        fixture.source = replacement
        settle(host)
        XCTAssertTrue(textView.string == replacement.text)
        XCTAssertTrue(textView.selectedRange().length == 0)
        XCTAssertTrue(fixture.frames.count == ChatQuoteSelectionAction.allCases.count)
        try click(.translate, fixture: fixture, host: host)
        settle(host)
        XCTAssertTrue(fixture.uses.count == 1)
    }

}

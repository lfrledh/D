import AppKit
import DWorkbench
import Observation
import SwiftUI
import Testing
@testable import UI

@MainActor @Observable
private final class QuoteSelectionFixture {
    var source: ChatQuoteSource
    var uses: [(ChatQuoteSelection, ChatQuoteSelectionAction)] = []

    init(source: ChatQuoteSource) { self.source = source }
}

@MainActor
private struct QuoteSelectionHarness: View {
    @Bindable var fixture: QuoteSelectionFixture

    var body: some View {
        ChatQuoteSelectionView(source: fixture.source) { selection, action in
            fixture.uses.append((selection, action))
        }
    }
}

@Suite("Native chat quote selection", .serialized)
@MainActor struct ChatQuoteSelectionViewTests {
    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func action(_ action: ChatQuoteSelectionAction, in root: NSView) -> (any NSAccessibilityProtocol)? {
        var pending: [NSObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), visited.count < 2_000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let element = object as? any NSAccessibilityProtocol {
                if element.accessibilityIdentifier() == "chat-quote-\(action.rawValue)" { return element }
                pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            }
            if let view = object as? NSView { pending += view.subviews }
        }
        return nil
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func select(_ range: NSRange, in textView: NSTextView) throws {
        textView.setSelectedRange(range)
        let coordinator = try #require(textView.delegate as? ChatQuoteSelectionView.NativeTextView.Coordinator)
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,
                                                            object: textView))
    }

    private func expectActionsEnabled(_ enabled: Bool, in host: NSView) throws {
        for actionKind in ChatQuoteSelectionAction.allCases {
            let control = try #require(action(actionKind, in: host))
            #expect(control.isAccessibilityEnabled() == enabled)
        }
    }

    @Test func hostedSelectionClearsActionsAfterDeselectOversizeAndSourceReset() async throws {
        let raw = "Quote " + String(repeating: "a", count: ChatQuoteSelection.maximumUTF8Bytes + 1)
        let source = try ChatQuoteSource(kind: .document, id: UUID(), version: "v1", text: raw)
        let fixture = QuoteSelectionFixture(source: source)
        let host = NSHostingView(rootView: QuoteSelectionHarness(fixture: fixture))
        host.frame = CGRect(x: 0, y: 0, width: 850, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        let textView = try #require(descendants(host).compactMap { $0 as? NSTextView }
            .first { $0.string == source.text })
        try expectActionsEnabled(false, in: host)

        try select(NSRange(location: 0, length: 5), in: textView)
        try await settle(host)
        try expectActionsEnabled(true, in: host)
        let ask = try #require(action(.ask, in: host))
        #expect(HostingControlClick.send(to: ask, in: host))
        #expect(fixture.uses.count == 1)
        #expect(fixture.uses.first?.0.text == "Quote")
        #expect(fixture.uses.first?.0.sourceKind == .document)
        #expect(fixture.uses.first?.1 == .ask)

        try select(NSRange(location: 0, length: 0), in: textView)
        try await settle(host)
        try expectActionsEnabled(false, in: host)
        let disabledAsk = try #require(action(.ask, in: host))
        #expect(HostingControlClick.send(to: disabledAsk, in: host))
        #expect(fixture.uses.count == 1)

        try select(NSRange(location: 0, length: ChatQuoteSelection.maximumUTF8Bytes + 1), in: textView)
        try await settle(host)
        try expectActionsEnabled(false, in: host)
        let disabledExplain = try #require(action(.explain, in: host))
        #expect(HostingControlClick.send(to: disabledExplain, in: host))
        #expect(fixture.uses.count == 1)

        try select(NSRange(location: 0, length: 5), in: textView)
        try await settle(host)
        try expectActionsEnabled(true, in: host)
        let replacement = try ChatQuoteSource(kind: .document, id: source.id,
                                              version: source.version, text: "Replacement")
        fixture.source = replacement
        try await settle(host)
        #expect(textView.string == replacement.text)
        #expect(textView.selectedRange().length == 0)
        try expectActionsEnabled(false, in: host)
        let disabledTranslate = try #require(action(.translate, in: host))
        #expect(HostingControlClick.send(to: disabledTranslate, in: host))
        #expect(fixture.uses.count == 1)
    }

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

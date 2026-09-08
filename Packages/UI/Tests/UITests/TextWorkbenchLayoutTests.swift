import AppKit
import DInference
import DWorkbench
import SwiftUI
import Testing
@testable import UI

private actor LayoutOnlyEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() },
                     cancel: {}, outcome: { .cancelled })
    }
}

@Suite @MainActor
struct TextWorkbenchLayoutTests {
    @Test func shrinkingAfterExpansionKeepsNativeEditorInsideViewportAndPreservesSelection() throws {
        let document = try TextDraftDocument(text: "中文 e\u{301} 👩‍💻 🇯🇵")
        let session = TextDraftSession(document: document, engine: LayoutOnlyEngine(), backendID: "layout.fixture")
        let view = TextWorkbenchView(session: session, selection: NSRange(location: 0, length: 2),
            instruction: .constant("简洁改写"), modelStatus: "Qwen2.5 0.5B Instruct 4-bit — 已准备好",
            canGenerate: true, canAccept: false, canUndo: false, isSaving: false, saveStatus: "正文已保存在项目中",
            onEdit: { _ in }, onSelection: { _ in }, onGenerate: {}, onCancel: {}, onAccept: {},
            onReject: {}, onUndo: {}, onSave: {}, onChooseModel: {})
        let host = NSHostingView(rootView: view)
        func settle(_ width: CGFloat, _ height: CGFloat) {
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        func descendants(_ parent: NSView) -> [NSView] {
            parent.subviews.flatMap { [$0] + descendants($0) }
        }
        settle(1100, 680)
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        let scroll = try #require(editor.enclosingScrollView)
        let identity = ObjectIdentifier(editor)
        for width: CGFloat in [620, 1000, 580, 900, 620] {
            settle(width, 530)
            let current = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
            let rectangle = scroll.convert(scroll.bounds, to: host)
            print("layout viewport=\(host.bounds) editor=\(rectangle)")
            print("minimum fitting size=\(host.fittingSize)")
            #expect(host.fittingSize.width <= width + 1, "The detail must not force its parent wider than the viewport.")
            #expect(ObjectIdentifier(current) == identity, "Resizing must not recreate an IME editor.")
            #expect(current.string.utf8.elementsEqual(document.text.utf8))
            #expect(current.selectedRange() == NSRange(location: 0, length: 2))
            #expect(rectangle.minX >= -1 && rectangle.maxX <= host.bounds.maxX + 1)
            #expect(rectangle.minY >= -1 && rectangle.maxY <= host.bounds.maxY + 1)
            #expect(rectangle.width > 120 && rectangle.height > 20)
            if width <= 620 {
                #expect(rectangle.width >= width - 40, "A narrow detail stacks panels and gives the editor the available width.")
            }
        }
    }
}

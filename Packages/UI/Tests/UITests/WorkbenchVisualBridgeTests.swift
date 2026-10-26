import AppKit
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct WorkbenchVisualBridgeTests {
    @Test func surfaceAndPopupResolveTheSamePreferencesAndFallback() {
        for dark in [false, true] {
            for strength in [0.0, 0.55, 1.0] {
                for restricted in [false, true] {
                    var preferences = ChatDisplayPreferences()
                    preferences.theme = dark ? .dark : .light
                    var appearance = WorkbenchAppearance()
                    appearance.local = .init(); appearance.local?.material = .glass; appearance.local?.strength = strength
                    preferences.appearance = appearance
                    let resolved = WorkbenchResolvedAppearance(preferences: preferences, scheme: .light,
                        reduceMotion: restricted, reduceTransparency: restricted, increasedContrast: restricted)
                    let popup = WorkbenchPopupStyle.resolved(owner: nil, preferences: preferences, scheme: .light,
                        reduceMotion: restricted, reduceTransparency: restricted, increasedContrast: restricted)
                    #expect(popup.palette == resolved.palette && popup.nativeGlass == resolved.nativeGlass)
                    #expect(popup.colorScheme == resolved.scheme)
                    #expect(abs(popup.nativeTint.alphaComponent - resolved.nativeTintOpacity) < 0.00001)
                    #expect(popup.nativeGlass == !restricted)
                    #expect(!restricted || resolved.effects.morphAnimation == nil)
                }
            }
        }
    }

    private func window() -> (NSWindow, WorkbenchBackgroundOwner) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let owner = WorkbenchBackgroundOwner(), root = NSView(frame: window.contentView!.bounds)
        let canvas = WorkbenchBackgroundNSView(frame: root.bounds)
        canvas.owner = owner; canvas.isCanvas = true; owner.root = canvas
        root.addSubview(canvas); window.contentView = root
        canvas.stylesWindowTitlebar = true
        window.orderFront(nil)
        return (window, owner)
    }
    private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }

    @Test func commandChildUpdatesWithoutRetitlingAndKeepsExactOwnerAndEditor() throws {
        let (first, firstOwner) = window(), (second, secondOwner) = window()
        let firstState = ChatDisplayPreferencesState(), secondState = ChatDisplayPreferencesState()
        var dark = secondState.preferences; dark.theme = .dark; #expect(secondState.update(dark))
        let firstRecord = VisualRecord(), secondRecord = VisualRecord()
        let one = try #require(WorkbenchChildPanelHandle(owner: first, title: "First", content: AnyView(VisualEditor(record: firstRecord)), preferences: firstState, language: nil))
        let two = try #require(WorkbenchChildPanelHandle(owner: second, title: "Second", content: AnyView(VisualEditor(record: secondRecord)), preferences: secondState, language: nil))
        defer { two.close(); one.close(); first.close(); second.close() }
        settle()
        let editor = try #require(firstRecord.editor)
        editor.string = "Kept draft"; editor.setSelectedRange(.init(location: 2, length: 4))
        editor.setMarkedText("pin", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        let contents = editor.string, selected = editor.selectedRange(), undo = editor.undoManager
        var next = firstState.preferences; next.theme = .dark
        var appearance = next.resolvedAppearance; appearance.dark.accent = "#FAEBD7"; next.appearance = appearance
        #expect(firstState.update(next)); settle()
        #expect(firstRecord.preferences == next)
        #expect(firstRecord.background === firstOwner && secondRecord.background === secondOwner)
        #expect(secondRecord.preferences == dark)
        #expect(firstRecord.editor === editor && editor.string == contents && editor.selectedRange() == selected)
        #expect(editor.hasMarkedText() && editor.undoManager === undo)
    }

    @Test func retainedHostCarriesLivePreferencesWithoutReplacingEditor() throws {
        let (window, owner) = window(); let state = ChatDisplayPreferencesState(), record = VisualRecord()
        let content = RetainedContentHost(content: VisualEditor(record: record), visible: true, identifier: "visual-retained")
            .environment(\.workbenchAppearanceState, state).environment(\.workbenchBackground, owner)
        let host = NSHostingView(rootView: content); window.contentView?.addSubview(host); host.frame = .init(x: 0, y: 0, width: 400, height: 400)
        defer { window.close() }
        settle()
        let editor = try #require(record.editor); editor.string = "Retained"; editor.setSelectedRange(.init(location: 1, length: 3))
        var next = state.preferences; next.theme = .dark
        #expect(state.update(next)); settle()
        #expect(record.preferences == next && record.background === owner)
        #expect(record.editor === editor && editor.string == "Retained" && editor.selectedRange() == .init(location: 1, length: 3))
    }
    @Test func nestedConfirmationEscapeResolvesOnlyTopRequestOnce() async throws {
        let (window, owner) = self.window(), state = ChatDisplayPreferencesState()
        owner.presentationState = state
        let parent = try #require(WorkbenchChildPanelHandle(owner: window, title: "Parent", content: AnyView(Text("Retained parent")), preferences: state, language: nil))
        defer { parent.close(); window.close() }
        let alert = NSAlert(); alert.messageText = "Confirm"; alert.addButton(withTitle: "Keep"); alert.addButton(withTitle: "Remove")
        var response: NSApplication.ModalResponse?, finishes = 0
        let job = Task { response = await WorkbenchConfirmation.present(alert, owner: window, cancelResponse: .alertThirdButtonReturn, destructiveIndices: [1]); finishes += 1 }
        defer { job.cancel() }
        for _ in 0..<10 { await Task.yield() }
        let surface = try #require(WorkbenchChildPanels.frontmostSurface(on: window))
        let host = try #require(surface.subviews.first as? WorkbenchChildHostingView)
        host.cancelOperation(nil); host.cancelOperation(nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(response == .alertThirdButtonReturn && finishes == 1)
        #expect(parent.isVisible && WorkbenchChildPanels.isPresented(on: window))
    }

}

@MainActor private final class VisualRecord {
    weak var editor: NSTextView?
    var preferences: ChatDisplayPreferences?
    weak var background: WorkbenchBackgroundOwner?
}
private struct VisualEditor: NSViewRepresentable {
    let record: VisualRecord
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.workbenchBackground) private var background
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(); view.allowsUndo = true; record.editor = view; return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        record.preferences = preferences; record.background = background
    }
}

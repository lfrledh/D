import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct QuickAudioCompositionTests {
    @Test func audioEditorKeepsIdentityMarkedTextAndUndoAcrossSaveLanguageAndResize() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("audio-editor-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "Audio editor fixture")
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("No inference") }
        await quick.load(); quick.select(operationID: "d.music.generate", modelID: "fixture:audio")
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        func input(compact: Bool) -> some View {
            WorkbenchScrollView { QuickAudioInput(quick: quick, continueInWorkflow: { _ in }, compact: compact) }
                .frame(height: compact ? 78 : 94).environment(\.dLanguageStore, language)
        }
        let host = NSHostingView(rootView: input(compact: true))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 230), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        func settle() async throws { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) } }
        func editor() throws -> NSTextView {
            func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
            return try #require(all(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        }
        try await settle(); let text = try editor(); #expect(window.makeFirstResponder(text))
        text.insertText("Piano ", replacementRange: .init(location: 0, length: 0))
        try await settle()
        text.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: 6, length: 0))
        #expect(text.hasMarkedText())
        try await quick.flush(); try language.select("en"); window.setContentSize(.init(width: 360, height: 220)); host.rootView = input(compact: false); try await settle()
        #expect(try editor() === text); #expect(text.hasMarkedText()); #expect(text.string == "Piano zhong")
        text.insertText("中", replacementRange: text.markedRange()); try await settle()
        #expect(quick.draft?.node.parameters["promptText"] == .text("Piano 中"))
        #expect(text.undoManager?.canUndo == true)
        text.undoManager?.undo(); try await settle()
        #expect(!text.hasMarkedText()); #expect(quick.state.runs.isEmpty)
        #expect(language.text("quick.audio.description", fallback: "missing") == "Music description")
        #expect(workflowText(language, "workflow.action.chooseModel") == "Choose Model")
        try language.select("zh-Hans"); #expect(language.text("quick.audio.generate", fallback: "missing") == "生成音频")
        try await quick.prepareForTermination(); try await store.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_TREE_AX"] == "1",
        "Requires visible native AX hosting"), arguments: ["zh-Hans", "en"])
    func candidateOrdinalsAndSelectionFollowReferenceNotRow(locale: String) async throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        let language = UILanguageStore(preferredLanguages: [locale])
        // Equal spoken names are intentional: only position and selected state distinguish these outputs.
        let first = UUID(), second = UUID(), inserted = UUID()
        var references = [first, second], selected = first, pressed: [UUID] = []
        func rows() -> some View {
            VStack {
                ForEach(Array(references.enumerated()), id: \.element) { index, reference in
                    Button("Same model, 5.20 s, attempt 1") { selected = reference; pressed.append(reference) }
                        .accessibilityIdentifier(reference.uuidString)
                        .modifier(QuickAudioCandidateAccessibility(enabled: true, index: index,
                            count: references.count, selected: selected == reference))
                }
                Button("Other modality") { }.accessibilityIdentifier("other")
                    .modifier(QuickAudioCandidateAccessibility(enabled: false, index: 0, count: 2, selected: true))
            }.frame(width: 400, height: 200).environment(\.dLanguageStore, language)
        }
        let host = NSHostingView(rootView: rows())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 {
            if window.isVisible && window.isKeyWindow && host.window === window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.isVisible && window.isKeyWindow && host.window === window)
        func settle() async throws {
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func button(_ id: String) throws -> any NSAccessibilityProtocol {
            var pending: [NSObject] = [host], seen = Set<ObjectIdentifier>()
            var observed: [String] = []
            while let object = pending.popLast(), seen.count < 1000 {
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
                if let ax = object as? any NSAccessibilityProtocol {
                    observed.append("\(ax.accessibilityRole()?.rawValue ?? "nil"):\(ax.accessibilityIdentifier() ?? "nil")")
                    if ax.accessibilityRole() == .button && ax.accessibilityIdentifier() == id { return ax }
                    pending += (ax.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                }
                if let view = object as? NSView { pending += view.subviews }
            }
            throw WorkflowIssue("Missing actual candidate button: " + id + "; actual: " + observed.joined(separator: ","))
        }
        func position(_ index: Int, _ count: Int) -> String {
            locale == "en" ? "Item \(index) of \(count)" : "第\(index)项，共\(count)项"
        }
        try await settle()
        #expect(try button(first.uuidString).accessibilityValue() as? String == position(1, 2))
        #expect(try button(second.uuidString).accessibilityValue() as? String == position(2, 2))
        #expect(try button(first.uuidString).isAccessibilitySelected())
        #expect(try !button(second.uuidString).isAccessibilitySelected())
        #expect(try !button("other").isAccessibilitySelected())
        #expect(try button("other").accessibilityValue() as? String != position(1, 2))
        #expect(pressed.isEmpty)
        try #require(button(second.uuidString).accessibilityPerformPress())
        host.rootView = rows(); try await settle()
        #expect(selected == second && pressed == [second])
        #expect(try button(second.uuidString).isAccessibilitySelected())
        #expect(try !button(first.uuidString).isAccessibilitySelected())
        references.insert(inserted, at: 0); host.rootView = rows(); try await settle()
        #expect(selected == second && pressed == [second])
        #expect(try button(second.uuidString).accessibilityValue() as? String == position(3, 3))
        #expect(try button(second.uuidString).isAccessibilitySelected())
    }

}

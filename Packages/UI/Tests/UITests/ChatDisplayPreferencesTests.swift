import AppKit
import SwiftUI
import Foundation
import DWorkbench
import SwiftStreamingMarkdown
import Testing
@testable import UI

@Suite("Chat display preferences")
@MainActor struct ChatDisplayPreferencesTests {
    @Test func unmarkWithoutSyntheticChangeNotificationKeepsNativeTextOnEcho() {
        let editor = NSTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        editor.delegate = coordinator
        var accepted = "original ", edits: [String] = []
        let publish: (String) -> Void = { accepted = $0; edits.append($0) }
        coordinator.update(editor, value: accepted, isEditable: true, onEdit: publish)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.update(editor, value: accepted, isEditable: true, onEdit: publish)
        let composed = editor.string
        editor.unmarkText()
        print("D_IME_UNMARK", "callbacks", edits.count, "marked", editor.hasMarkedText(),
              "nativeCount", editor.string.utf16.count, "acceptedCount", accepted.utf16.count)
        coordinator.update(editor, value: accepted, isEditable: true, onEdit: publish)
        #expect(editor.string == composed)
    }

    @Test func nativeInputReceivesReadableAccessibilityName() throws {
        let editor = TextSourcesQuestionEditor(value: "original", editEpoch: 0, isEditable: true,
            accessibilityIdentifier: "fixture-chat-draft", accessibilityLabel: "Message draft", onEdit: { _ in })
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            if let value = view as? NSTextView { return value }
            return view.subviews.compactMap { find($0) }.first
        }
        let text = try #require(find(host))
        #expect(text.accessibilityLabel() == "Message draft")
        #expect(text.accessibilityIdentifier() == "fixture-chat-draft")
        #expect(text.string == "original")
    }

    @Test func preferencesDuringCompositionApplyAfterConfirmationWithoutReplacingOwnerOrText() {
        let editor = NSTextView(), coordinator = TextSourcesQuestionEditor.Coordinator()
        editor.delegate = coordinator
        var submitted = 0, wrongOwner = 0, edited = ""
        coordinator.update(editor, value: "original", isEditable: true, onEdit: { edited = $0 },
            pointSize: 14, sendsOnReturn: false, onSubmit: { submitted += 1 })
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let composed = editor.string
        coordinator.update(editor, value: "stale overwrite", isEditable: true,
            onEdit: { _ in wrongOwner += 1 }, pointSize: 28, sendsOnReturn: true, onSubmit: { wrongOwner += 1 })
        #expect(editor.string == composed && editor.hasMarkedText())
        #expect(editor.font?.pointSize == 14)
        #expect(!coordinator.submitIfAllowed(editor, modifiers: []))
        editor.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(editor.string == composed && edited == composed && editor.font?.pointSize == 28)
        #expect(coordinator.submitIfAllowed(editor, modifiers: []))
        #expect(submitted == 1 && wrongOwner == 0)
    }

    @Test func sendShortcutAlwaysDefersMarkedTextAndModifiedNewlines() {
        typealias C = TextSourcesQuestionEditor.Coordinator
        #expect(!C.shouldSubmit(markedText: true, sendsOnReturn: true, modifiers: []))
        #expect(!C.shouldSubmit(markedText: true, sendsOnReturn: false, modifiers: .command))
        #expect(C.shouldSubmit(markedText: false, sendsOnReturn: true, modifiers: []))
        #expect(C.shouldSubmit(markedText: false, sendsOnReturn: false, modifiers: .command))
        #expect(!C.shouldSubmit(markedText: false, sendsOnReturn: true, modifiers: .shift))
        #expect(!C.shouldSubmit(markedText: false, sendsOnReturn: false, modifiers: [.command, .shift]))
        #expect(!C.shouldSubmit(markedText: false, sendsOnReturn: true, modifiers: .option))
    }

    @Test func globalAndProjectModelsShareOnePreferenceOwner() throws {
        let suiteName = "chat-display-models-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let global = WorkbenchModel(sessionFactory: { _ in throw WorkflowIssue("No inference") }, settings: settings)
        let project = WorkbenchModel(sessionFactory: { _ in throw WorkflowIssue("No inference") },
            settings: settings, displaySettingsOwner: global)
        var choice = global.chatDisplaySettings.preferences; choice.textPointSize = 22
        #expect(global.chatDisplaySettings.update(choice))
        #expect(project.chatDisplaySettings.preferences.textPointSize == 22)
        choice = project.chatDisplaySettings.preferences; choice.theme = .dark
        #expect(project.chatDisplaySettings.update(choice))
        #expect(global.chatDisplaySettings.preferences.theme == .dark)
        #expect(ChatDisplayPreferencesState(settings: settings).preferences.textPointSize == 22)
    }

    @Test func defaultsAndMemoryOnlyState() {
        let state = ChatDisplayPreferencesState()
        #expect(state.preferences == ChatDisplayPreferences())
        #expect(state.preferences.theme == .system)
        #expect(state.preferences.textPointSize == 14)
        #expect(state.preferences.transcriptWidth == 760)
        #expect(!state.preferences.wrapsCode)
        #expect(state.preferences.sendShortcut == .commandReturn)
        #expect(state.preferences.preferredColorScheme == nil)

        var choice = state.preferences
        choice.theme = .dark
        choice.sendShortcut = .`return`
        #expect(state.update(choice))
        #expect(state.preferences.preferredColorScheme == .dark)
        #expect(ChatDisplayPreferencesState().preferences == ChatDisplayPreferences())
    }

    @Test func validRecordPersistsOnlyInInjectedSuite() throws {
        let suiteName = "chat-display-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let state = ChatDisplayPreferencesState(settings: settings)
        var choice = state.preferences
        choice.theme = .light
        choice.textPointSize = 28
        choice.transcriptWidth = 1100
        choice.wrapsCode = true
        choice.sendShortcut = .`return`
        #expect(state.update(choice))
        #expect(ChatDisplayPreferencesState(settings: settings).preferences == choice)
        #expect(ChatDisplayPreferencesState().preferences == ChatDisplayPreferences())
        let otherName = "chat-display-other-\(UUID().uuidString)"
        let otherSettings = try #require(UserDefaults(suiteName: otherName))
        defer { otherSettings.removePersistentDomain(forName: otherName) }
        #expect(ChatDisplayPreferencesState(settings: otherSettings).preferences == ChatDisplayPreferences())

        choice.textPointSize = 29
        #expect(!state.update(choice))
        #expect(ChatDisplayPreferencesState(settings: settings).preferences.textPointSize == 28)
    }

    @Test func invalidRecordIsProtectedUntilExplicitReset() throws {
        let suiteName = "chat-display-invalid-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let original = Data(#"{"theme":"dark","textPointSize":11,"transcriptWidth":760,"wrapsCode":false,"sendShortcut":"return"}"#.utf8)
        settings.set(original, forKey: ChatDisplayPreferences.storageKey)
        let state = ChatDisplayPreferencesState(settings: settings)
        #expect(state.hasInvalidStoredRecord)
        #expect(state.preferences == ChatDisplayPreferences())
        #expect(!state.update(ChatDisplayPreferences()))
        #expect(settings.data(forKey: ChatDisplayPreferences.storageKey) == original)
        state.reset()
        #expect(!state.hasInvalidStoredRecord)
        #expect(settings.object(forKey: ChatDisplayPreferences.storageKey) == nil)
        #expect(state.update(ChatDisplayPreferences()))
    }

    @Test func externallyDamagedRecordCannotBeOverwritten() throws {
        let suiteName = "chat-display-race-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let state = ChatDisplayPreferencesState(settings: settings)
        settings.set("unknown version", forKey: ChatDisplayPreferences.storageKey)
        var choice = ChatDisplayPreferences()
        choice.theme = .dark
        #expect(!state.update(choice))
        #expect(state.hasInvalidStoredRecord)
        #expect(settings.string(forKey: ChatDisplayPreferences.storageKey) == "unknown version")
    }

    @Test func markdownUsesConfiguredPointSizeAndKeepsImagesDisabled() async {
        var preferences = ChatDisplayPreferences()
        preferences.textPointSize = 22
        preferences.wrapsCode = true
        let config = ChatMarkdownPresentation.config(for: preferences)
        #expect(config.paragraphStyle.textFonts.normal.pointSize == 22)
        #expect(config.codeBlockConfig.codeTextFonts.normal.pointSize == 22)
        #expect(config.inlineStyle.codeTextFont.pointSize == 22)
        #expect(!config.imageConfig.enabled)
        #expect(config.codeBlockConfig.wrapsLines)
        #expect(!ChatMarkdownPresentation.config.codeBlockConfig.wrapsLines)
        let document = await ChatMarkdownPresentation.parse("**Hello**", pointSize: 22)
        #expect(document != .empty)
        #expect(ChatMarkdownPresentation.literalText(rendered: "**Hello**", raw: "original",
                    streaming: false, showingRaw: true, parsed: "**Hello**", document: document) == "original")
    }
}

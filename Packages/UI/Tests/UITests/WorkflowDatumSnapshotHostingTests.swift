import AppKit
import DWorkbench
import Observation
import SwiftUI
import Testing
@testable import UI

@MainActor @Observable
private final class SnapshotFixture {
    var result: WorkflowDatum
    var number: WorkflowDatum? = .number(73, unit: nil)
    var text: WorkflowDatum? = .text("保留 é 👩🏽‍🎨 草稿")
    var progress = 0
    init(_ result: WorkflowDatum) { self.result = result }
}

@MainActor
private struct SnapshotHarness: View {
    @Bindable var fixture: SnapshotFixture
    var body: some View {
        VStack {
            WorkflowDatumSnapshotView(value: fixture.result)
            WorkflowDatumEditor(value: $fixture.number)
            WorkflowDatumEditor(value: $fixture.text)
            Text(String(fixture.progress))
        }
    }
}

/// Mount the production result view once, then replace its value without
/// replacing the host or surrounding identity. Pure value tests miss this bug.
@Suite(.serialized) @MainActor
struct WorkflowDatumSnapshotHostingTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func numbers(_ host: NSView) -> [String] {
        descendants(host).flatMap { view -> [String] in
            if let field = view as? NSTextField { return [field.stringValue] }
            if let text = view as? NSTextView { return text.string.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }
            return []
        }
    }

    private func labels(_ root: NSObject) -> Set<String> {
        var pending = [root]; var seen: Set<ObjectIdentifier> = []; var result: Set<String> = []
        while let object = pending.popLast(), seen.count < 2_000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let ax = object as? any NSAccessibilityProtocol {
                if let text = ax.accessibilityLabel() ?? ax.accessibilityTitle() { result.insert(text) }
                if let text = ax.accessibilityValue() as? String { result.insert(text) }
                pending += (ax.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            }
            if let field = object as? NSTextField { result.insert(field.stringValue) }
            if let button = object as? NSButton { result.insert(button.title) }
            if let view = object as? NSView { pending += view.subviews }
        }
        return result
    }

    @Test func samePortRefreshesNumberAndTypeWithoutResettingNeighborDrafts() async throws {
        let fixture = SnapshotFixture(.number(1, unit: nil))
        let host = NSHostingView(rootView: SnapshotHarness(fixture: fixture))
        host.frame = CGRect(x: 0, y: 0, width: 650, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await settle(host)
        #expect(numbers(host).contains("1.0"))
        let number = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == "73.0" })
        number.stringValue = "-"
        number.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: number))
        let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == "保留 é 👩🏽‍🎨 草稿" })
        window.makeFirstResponder(text)
        let selection = NSRange(location: 0, length: 2)
        text.setSelectedRange(selection)
        fixture.result = .number(2, unit: nil); fixture.progress += 1
        try await settle(host)
        #expect(numbers(host).contains("2.0") && !numbers(host).contains("1.0"))
        #expect(number.stringValue == "-")
        #expect(descendants(host).contains { $0 === number })
        #expect(fixture.number == .number(73, unit: nil)) // Preserve the last valid value, as the existing editor contract requires.
        #expect(descendants(host).contains { $0 === text })
        #expect(window.firstResponder === text && text.selectedRange() == selection)
        fixture.result = .text("新类型的结果")
        try await settle(host)
        #expect(descendants(host).compactMap { $0 as? NSTextView }.contains { $0.string == "新类型的结果" })
        #expect(number.stringValue == "-" && window.firstResponder === text && text.selectedRange() == selection)
    }

    @Test func sameRecordFieldAndListItemRefreshNestedNumberAndSchema() async throws {
        func value(_ n: Double, _ choices: [String]) -> WorkflowDatum {
            let fields: [WorkflowRecordField] = [.init("items", .list(.number(unit: nil))), .init("choice", .enumeration(choices))]
            return .record(schema: fields, fields: [
                "items": .list(element: .number(unit: nil), items: [.init(id: "stable-item", value: .number(n, unit: nil))]),
                "choice": .enumeration(choices.last!, choices: choices)
            ])
        }
        let fixture = SnapshotFixture(value(11, ["Before-A", "Before-B"]))
        let host = NSHostingView(rootView: SnapshotHarness(fixture: fixture))
        host.frame = CGRect(x: 0, y: 0, width: 750, height: 1100)
        try await settle(host)
        #expect(numbers(host).contains("11.0"))
        fixture.result = value(22, ["After-A", "After-B"])
        try await settle(host)
        #expect(numbers(host).contains("22.0") && !numbers(host).contains("11.0"))
        // The same field can change schema while the native read-only reader stays mounted.
        fixture.result = .record(schema: [.init("choice", .number(unit: nil))], fields: ["choice": .number(33, unit: nil)])
        try await settle(host)
        #expect(numbers(host).contains("33.0") && !numbers(host).contains("22.0"))
    }

    @Test func unchangedSnapshotPreservesItsOwnSelectionDuringLayoutAndProgress() async throws {
        let fixture = SnapshotFixture(.text("只读结果保持选择"))
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let host = NSHostingView(rootView: SnapshotHarness(fixture: fixture).environment(\.dLanguageStore, language))
        host.frame = CGRect(x: 0, y: 0, width: 750, height: 700)
        try await settle(host)
        let text = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == "只读结果保持选择" })
        let selection = NSRange(location: 0, length: 2); text.setSelectedRange(selection)
        fixture.result = .text("只读结果保持选择"); fixture.progress += 1
        host.frame.size.width = 580
        try language.select("en")
        try await settle(host)
        #expect(descendants(host).contains { $0 === text })
        #expect(text.selectedRange() == selection)
    }
    @Test func snapshotUsesSelectableReadOnlyReaderWithoutEditorCommands() async throws {
        let value = WorkflowDatum.record(schema: [.init("title", .text)], fields: ["title": .text("原文 👩🏽‍🎨")])
        let host = NSHostingView(rootView: WorkflowDatumSnapshotView(value: value))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        try await settle(host)
        let readers = descendants(host).compactMap { $0 as? NSTextView }
        #expect(readers.count == 1)
        #expect(readers.allSatisfy { !$0.isEditable && $0.isSelectable && !$0.drawsBackground })
        #expect(readers.first?.string.contains("原文 👩🏽‍🎨") == true)
        #expect(!descendants(host).contains { $0 is NSButton || $0 is NSTextField })
        #expect(value.fields?["title"] == .text("原文 👩🏽‍🎨"))
    }

    @Test func snapshotTextDistinguishesMissingEmptyNoneAndResultWithoutChangingData() throws {
        let language = UILanguageStore(preferredLanguages: ["en"])
        let fields: [WorkflowRecordField] = [.init("second", .text), .init("first", .optional(.text), required: false)]
        let value = WorkflowDatum.record(schema: fields, fields: ["second": .text("")])
        let rendered = WorkflowDatumSnapshotText.render(value, language: language)
        #expect(rendered.range(of: "second")!.lowerBound < rendered.range(of: "first")!.lowerBound)
        #expect(rendered.contains("(Empty text)") && rendered.contains("Value not provided"))
        #expect(WorkflowDatumSnapshotText.render(.none(.text), language: language).contains("No value"))
        let list = WorkflowDatum.list(element: .number(unit: "s"), items: [.init(id: "b", value: .number(2, unit: "s")), .init(id: "a", value: .number(1, unit: "s"))])
        #expect(WorkflowDatumSnapshotText.render(list, language: language) == "List · Number (s)\n[1]\n  2.0 s\n\n[2]\n  1.0 s")
        let result = WorkflowDatum.result(.init(status: .failed, expected: .text, issues: ["原始 diagnostic"]))
        #expect(WorkflowDatumSnapshotText.render(result, language: language).contains("Failed\n\nResult · Text\n\nValue not provided\n\n原始 diagnostic"))
        #expect(WorkflowDatumSnapshotText.render(.enumeration("A", choices: ["A", "B"]), language: language) != WorkflowDatumSnapshotText.render(.enumeration("A", choices: ["A", "C"]), language: language))
        #expect(WorkflowDatumSnapshotText.render(.list(element: .text, items: []), language: language) != WorkflowDatumSnapshotText.render(.list(element: .number(unit: nil), items: []), language: language))
        #expect(WorkflowDatumSnapshotText.render(result, language: language) != WorkflowDatumSnapshotText.render(.result(.init(status: .failed, expected: .boolean, issues: ["原始 diagnostic"])), language: language))
        try language.select("zh-Hans")
        #expect(WorkflowDatumSnapshotText.render(result, language: language).contains("处理失败"))
        #expect(value.fields?["second"] == .text("") && value.fields?["first"] == nil)
    }

    @Test func recordLanguageRefreshKeepsSelectedOriginalTextAndReaderIdentity() async throws {
        let fixture = SnapshotFixture(.record(schema: [.init("title", .text)], fields: ["title": .text("原文 preserved 👩🏽‍🎨")]))
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let host = NSHostingView(rootView: SnapshotHarness(fixture: fixture).environment(\.dLanguageStore, language))
        host.frame = CGRect(x: 0, y: 0, width: 750, height: 700)
        try await settle(host)
        let reader = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string.contains("原文 preserved") })
        reader.setSelectedRange((reader.string as NSString).range(of: "原文 preserved"))
        try language.select("en");fixture.progress += 1
        try await settle(host)
        #expect(descendants(host).contains { $0 === reader })
        #expect((reader.string as NSString).substring(with: reader.selectedRange()) == "原文 preserved")
        #expect(reader.string.contains("Text") && reader.string.contains("Required"))
        #expect(!reader.isEditable)
    }

}

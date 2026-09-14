import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct TextSourcesLayoutTests {
    @Test func workbenchMountsOneQuestionEditorAndKeepsRewriteSeparate() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("sources-shell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: SourcesLayoutEngine(), backendID: "fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        }, settings: SourcesLayoutDefaults(), textSourcesEnabled: true)
        await service.createProject(at: root.appendingPathComponent("Shell.dproject"))
        await service.createTextDocument()
        let sources = try #require(service.textSources)
        sources.changeQuestion("同一份问题 👩‍💻")
        let model = WorkbenchModel(projectSession: service)
        model.showingTextSources = true
        let host = NSHostingView(rootView: WorkbenchView(model: model))
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        func settle(_ width: CGFloat) async throws {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 680)
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        for width: CGFloat in [1440, 900, 1440] {
            try await settle(width)
            let questions = descendants(host).compactMap { $0 as? NSTextView }
                .filter { $0.isEditable && $0.string == sources.notebook.question }
            #expect(questions.count == 1, "Inspector must not duplicate the editable question or source controls.")
        }
        model.showingTextSources = false
        try await settle(1440)
        #expect(descendants(host).compactMap { $0 as? NSTextView }
            .filter { $0.isEditable && $0.string == sources.notebook.question }.isEmpty)
        #expect(service.textSources?.notebook.question == "同一份问题 👩‍💻")
        #expect(await service.requestClose())
    }

    @Test func resizeKeepsQuestionEditorIdentityAndReachableScrollViewport() async throws {
        let note = TextSourcesNotebook(question: "中文 e\u{301}👩‍💻")
        let view = TextSourcesView(notebook: note, partialAnswer: "", isRunning: false, isCancelling: false,
            isSaving: false, canAsk: false, canUndo: false, errorMessage: nil, canAccept: { _ in false },
            citationSummary: { _ in "未验证" }, actions: .init(importSource: {}, removeSource: { _ in },
                useExcerpt: { _, _ in }, changeQuestion: { _ in }, ask: {}, cancel: {}, accept: { _ in },
                reject: { _ in }, undo: {}, save: {}))
        let host = NSHostingView(rootView: view)
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        func settle(_ width: CGFloat) async throws {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            host.layoutSubtreeIfNeeded()
            // Yield the main actor so other hosted views can finish their scheduled layout tasks.
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        }
        try await settle(900)
        let first = try #require(descendants(host).compactMap { $0 as? NSTextView }.filter { $0.isEditable }.first)
        for width: CGFloat in [600, 1000, 500, 800] {
            try await settle(width)
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

private actor SourcesLayoutEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        .init(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}
private final class SourcesLayoutDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

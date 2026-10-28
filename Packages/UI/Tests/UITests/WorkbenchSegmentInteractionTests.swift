import AppKit
import DWorkbench
import DInference
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import UI

/// Deterministic AppKit component state tests. This window models key ownership;
/// these do not claim desktop input, native animation timing or IME acceptance.
@MainActor private final class SegmentFixtureWindow: NSWindow {
    var admitted = true
    override var isKeyWindow: Bool { admitted }
}

@Suite @MainActor struct WorkbenchSegmentInteractionTests {
    @Test(arguments: [WorkbenchSegmentGeometry.Direction.horizontal, .vertical], [CGFloat(32), 44])
    func oneGeometryKeepsAxisLengthAndAllowsCrossAxisLift(direction: WorkbenchSegmentGeometry.Direction, thickness: CGFloat) {
        for count in [0, 1, 2, 4, 7] {
            let g = WorkbenchSegmentGeometry(direction: direction, count: count, length: CGFloat(count) * 66, thickness: thickness)
            #expect(g.itemLength == (count == 0 ? 0 : 66))
            for i in 0..<count {
                let idle = g.lens(CGFloat(i), engagement: 0), held = g.lens(CGFloat(i), engagement: 1)
                #expect(idle.midX == held.midX && idle.midY == held.midY)
                #expect(CGRect(origin: .zero, size: g.slotSize).contains(held))
                if direction == .horizontal { #expect(idle.width == held.width && held.height == thickness + 4) }
                else { #expect(idle.height == held.height && held.width == thickness + 4) }
            }
            #expect(g.target(2, available: [], original: 0) == nil)
        }
        let g = WorkbenchSegmentGeometry(direction: direction, count: 4)
        #expect(g.target(1.5, available: [0, 1, 2, 3], original: 1) == 1)
        #expect(g.target(1.5, available: [0, 1, 2, 3], original: 2) == 2)
        #expect(g.target(1.5, available: [0, 3], original: 3) == 3)
        #expect(g.target(2.8, available: [0, 1], original: 0) == 1)
    }

    @Test(arguments: [WorkbenchSegmentGeometry.Direction.horizontal, .vertical])
    func releaseOnlyAndContextCancellation(direction: WorkbenchSegmentGeometry.Direction) throws {
        let geometry = WorkbenchSegmentGeometry(direction: direction, count: 4, length: 264, thickness: 32)
        let window = SegmentFixtureWindow(contentRect: .init(origin: .zero, size: geometry.slotSize), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: .init(origin: .zero, size: geometry.slotSize))
        let receiver = WorkbenchCategoryDragView(frame: root.bounds)
        window.contentView = root; root.addSubview(receiver)
        defer { receiver.cancel(); window.contentView = nil; window.close() }
        receiver.geometry = geometry; receiver.presentation = geometry.lens(0, engagement: 0)
        #expect(!receiver.mouseDownCanMoveWindow && receiver.acceptsFirstMouse(for: nil))
        let owner = NSObject(); receiver.owner = AnyHashable(ObjectIdentifier(owner))
        var values: [CGFloat?] = [], commits: [Int] = []
        var finishes = 0; receiver.onFinish = { finishes += 1 }
        receiver.onPreview = { values.append($0) }; receiver.onCommit = { commits.append($0) }
        let start = CGPoint(x: receiver.presentation.midX, y: receiver.presentation.midY)
        func point(_ i: CGFloat) -> CGPoint {
            direction == .horizontal ? .init(x: start.x + i * 66, y: start.y) : .init(x: start.x, y: start.y + i * 66)
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: receiver.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: receiver.mouseDown(with: event)
            case .leftMouseDragged: receiver.mouseDragged(with: event)
            default: receiver.mouseUp(with: event)
            }
        }
        try send(.leftMouseDown, start)
        for i in [CGFloat(1), 2, 3, 0] { try send(.leftMouseDragged, point(i)); #expect(commits.isEmpty) }
        try send(.leftMouseUp, start); #expect(commits.isEmpty && finishes == 1)
        try send(.leftMouseDown, start); try send(.leftMouseDragged, point(3)); try send(.leftMouseUp, point(3))
        try send(.leftMouseUp, point(3)); #expect(commits == [3] && finishes == 2)
        // The binding may reject the choice; the receiver still uses its actual
        // authoritative selection on the next gesture, rather than the preview.
        #expect(receiver.selection == 0 && values.last! == nil)
        try send(.leftMouseDown, start); try send(.leftMouseDragged, point(2))
        receiver.geometry.length = 300
        #expect(values.last! == nil)
        try send(.leftMouseUp, point(2)); #expect(commits == [3] && finishes == 2)
        receiver.geometry = geometry
        try send(.leftMouseDown, start); receiver.options = ["a", "c", "d", "e"]
        try send(.leftMouseUp, point(3)); #expect(commits == [3] && values.last! == nil)
        try send(.leftMouseDown, start); receiver.available = [0, 1]
        try send(.leftMouseUp, point(3)); #expect(commits == [3])
        try send(.leftMouseDown, start); try send(.leftMouseDragged, point(3)); try send(.leftMouseUp, point(3))
        #expect(commits == [3, 1], "Nearest enabled destination")
        try send(.leftMouseDown, start); root.isHidden = true; try send(.leftMouseUp, point(3))
        #expect(commits == [3, 1] && values.last! == nil); root.isHidden = false
        try send(.leftMouseDown, start); window.admitted = false; try send(.leftMouseUp, point(3))
        #expect(commits == [3, 1]); window.admitted = true
        try send(.leftMouseDown, start); try send(.leftMouseUp, .init(x: 1000, y: 1000))
        #expect(commits == [3, 1])
        receiver.available = [0, 1, 2, 3]; receiver.selection = 3
        receiver.presentationSelection = 1.5; receiver.presentation = geometry.lens(1.5, engagement: 0)
        let grabbed = CGPoint(x: receiver.presentation.midX, y: receiver.presentation.midY)
        try send(.leftMouseDown, grabbed); #expect(values.last! == 1.5)
        receiver.cancel(); #expect(values.last! == nil)
    }

    @Test func importCommandRejectsChangedTargetAndKeepsCancellationSideEffectFree() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("A.dproject"), name: "A")
        let other = try await ProjectStore.create(at: root.appendingPathComponent("B.dproject"), name: "B")
        let source = root.appendingPathComponent("Source.txt"); try Data("Original".utf8).write(to: source)
        let before = await store.snapshot(), otherBefore = await other.snapshot()
        var active: ProjectStore = store
        var refreshes = 0
        let command = WorkbenchAssetImportCommand(store: store, controller: nil, staleMessage: "target changed", isCurrent: { active === store }, didImport: { refreshes += 1 })
        do {
            _ = try await command.perform { active = other; return (source, .copy) }
            Issue.record("A replaced destination must be rejected")
        } catch { #expect(error.localizedDescription.contains("target changed")) }
        #expect(await store.snapshot() == before)
        #expect(await other.snapshot() == otherBefore)
        active = store
        #expect(try await command.perform { nil } == false)
        #expect(await store.snapshot() == before)
        let provider = NSItemProvider(object: source as NSURL)
        let imported = try await command.perform {
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            let url = try #require(URL(dataRepresentation: bytes, relativeTo: nil))
            #expect(url.isFileURL && url == source)
            return (url, .copy)
        }
        #expect(imported)
        #expect(refreshes == 1)
        #expect(await store.snapshot().assets.count == before.assets.count + 1)
        #expect(await other.snapshot() == otherBefore)
        #expect(try Data(contentsOf: source) == Data("Original".utf8))
        try await store.close(); try await other.close()
    }

    @Test func workflowImportFailureReachesVisibleCommandWithoutSuccessCallback() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Import.dproject"), name: "Import")
        let engine = ImportNoInferenceEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: .init(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load()
        let before = await store.snapshot()
        let invalid = root.appendingPathComponent("Invalid.mp4")
        let bytes = Data("This is not a video".utf8); try bytes.write(to: invalid)
        var refreshed = 0
        let command = WorkbenchAssetImportCommand(store: store, controller: controller,
            staleMessage: "target changed", isCurrent: { true }, didImport: { refreshed += 1 })
        do {
            _ = try await command.perform { (invalid, .copy) }
            Issue.record("Invalid media must reach the command caller, not report success")
        } catch { #expect(!error.localizedDescription.isEmpty) }
        #expect(refreshed == 0)
        #expect(await store.snapshot() == before)
        #expect(controller.availableAssets.isEmpty && controller.runs.isEmpty)
        #expect(try Data(contentsOf: invalid) == bytes)
        let valid = root.appendingPathComponent("Valid.txt")
        try Data("Full original content".utf8).write(to: valid)
        let result = try await command.perform { (valid, .copy) }
        #expect(result && refreshed == 1 && controller.availableAssets.count == 1)
        #expect(controller.runs.isEmpty)
        #expect(await engine.calls == 0)
        try await store.close()
    }

    @Test func removedSelectionKeepsLabelsWithoutInventingAnotherSelection() throws {
        var preferences = ChatDisplayPreferences(); preferences.appearance = WorkbenchAppearance(lightweight: true)
        let renderer = ImageRenderer(content: WorkbenchCategoryLensTrack(selection: 0, titles: ["A", "C"],
            geometry: .init(count: 2, length: 132, thickness: 32), available: [0, 1], showsSelection: false)
            .environment(\.chatDisplayPreferences, preferences))
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        // Both labels survive while the area around them remains transparent.
        for xRange in [20..<46, 86..<112] {
            #expect(xRange.contains { x in (8..<32).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 } })
        }
        #expect((0..<132).allSatisfy { (bitmap.colorAt(x: $0, y: 4)?.alphaComponent ?? 0) == 0 })
    }

    @Test func migratedCommandsResolveThroughBothLanguageResources() throws {
        let keys = ["quick", "workflow", "models", "nodeLibrary", "assetLibrary", "expandNodes", "expandAssets", "importAsset", "save", "projectFiles", "workspaceFiles", "independent", "quickDestination", "enableQuick", "legacy", "saveFilter", "exportLocation", "addDocument", "manageNodes", "project", "currentContent", "recent", "advanced", "currentProject", "temporary", "switchHelp", "legacyHelp", "noProject", "temporaryHelp", "exportHelp", "documentHelp", "noDocument", "staleImport", "libraryScope", "legacyChanged"]
        for locale in ["zh-Hans", "en"] {
            let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
            for key in keys {
                let text = layoutText(language, key, arguments: ["name": "User title", "source": "Document A", "target": "Graph B"])
                #expect(!text.isEmpty && !text.contains("layoutInteraction.") && !text.contains("{"), "Resolve the actual bundled sentence, including placeholders")
            }
            #expect(layoutText(language, "quick") == (locale == "en" ? "Quick Generate" : "快速生成"))
            #expect(layoutText(language, "workflow") == (locale == "en" ? "Node Workflow" : "节点工作流"))
            #expect(layoutText(language, "currentProject", arguments: ["name": "User title"]).contains("User title"))
        }
    }

    @Test(arguments: QuickCategory.allCases)
    func fullNodeLibraryKeepsQuickCategoryIntersection(category: QuickCategory) {
        let cache = SharedLibraryProjectionCache()
        _ = cache.entries(models: [], readiness: [:], tools: [], projects: [], language: nil, metadata: [:], tags: ModelNodeTagStore())
        let expected = cache.selection(canvasMode: nil, family: category).filter { $0.item.kind == .model || $0.item.kind == .component }
        let actual = cache.selection(canvasMode: .nodes, family: category)
        #expect(actual == expected && !actual.isEmpty)
    }
}

private actor ImportNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        throw WorkflowIssue("Import must not run inference")
    }
}

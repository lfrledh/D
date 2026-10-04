import AppKit
import CoreGraphics
import DWorkbench
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UI

@MainActor private final class QuickResolverGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdIgnoringCancellation() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("Quick explicit attachment import", .serialized) @MainActor
struct QuickInputImportTests {
    private func folder() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let url = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("quick-input-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func quick(at folder: URL, operation: String) async throws -> (ProjectStore, QuickGenerationController) {
        let store = try await ProjectStore.create(at: folder.appendingPathComponent("Quick.dproject"), name: "Quick input fixture")
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("Import must not start generation") }
        await quick.load()
        quick.select(operationID: operation, modelID: "fixture:never-run")
        _ = try #require(quick.draft)
        return (store, quick)
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage()), bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    @Test func mixedFileBatchReportsBadFileAndBindsGoodImagesInOrder() async throws {
        let root = try folder()
        let (store, quick) = try await quick(at: root, operation: WorkflowModelRoutes.qwen35)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let draft = try #require(quick.draft)
        let first = root.appendingPathComponent("first.png"), bad = root.appendingPathComponent("bad.png")
        let last = root.appendingPathComponent("last.png")
        try png().write(to: first); try Data("bad".utf8).write(to: bad); try png().write(to: last)
        let result = await QuickInputImport.run([.file(first), .file(bad), .file(last)],
                                                quick: quick, draft: draft, port: port)
        #expect(result.published == 2 && result.bound == 2)
        #expect(result.failures.count == 1 && result.failures[0].contains("bad.png"))
        let bound = try port.resolveAssets(#require(quick.draft?.inputs[port.id]))
        let manifest = await store.snapshot()
        #expect(bound.compactMap { ref in manifest.assets.first { $0.id == ref.assetID }?.name } == ["first.png", "last.png"])
        #expect(quick.visibleRuns.isEmpty)
        try await quick.flush(); try await store.close()
    }

    @Test func wrongKindAndStaleOwnerOrInputLeavePublishedAssetsInLibrary() async throws {
        let root = try folder()
        let (store, quick) = try await quick(at: root, operation: WorkflowModelRoutes.qwen35)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let text = root.appendingPathComponent("wrong.txt")
        try Data("text asset".utf8).write(to: text)
        let wrong = await QuickInputImport.run([.file(text)], quick: quick,
                                               draft: try #require(quick.draft), port: port)
        #expect(wrong.published == 1 && wrong.bound == 0 && wrong.message?.contains("类型") == true)
        #expect(quick.draft?.inputs[port.id] == nil)

        let captured = try #require(quick.draft)
        quick.setInput(port.id, value: .data(.text("changed")), draftID: captured.id)
        let stale = await QuickInputImport.run([.png(try png())], quick: quick, draft: captured, port: port)
        #expect(stale.published == 1 && stale.bound == 0)
        #expect(quick.draft?.inputs[port.id] == .data(.text("changed")))
        #expect(stale.message != nil)
        let invalid = try #require(quick.draft)
        let preserved = await QuickInputImport.run([.png(try png())], quick: quick, draft: invalid, port: port)
        #expect(preserved.published == 1 && preserved.bound == 0)
        #expect(quick.draft?.inputs[port.id] == invalid.inputs[port.id])
        let old = try #require(quick.draft)
        quick.select(operationID: WorkflowModelRoutes.ace, modelID: "fixture:other")
        let owner = await QuickInputImport.run([.png(try png())], quick: quick, draft: old, port: port)
        #expect(owner.published == 1 && owner.bound == 0)
        #expect(quick.draft?.node.operationID == WorkflowModelRoutes.ace)
        #expect((await store.snapshot()).assets.count >= 4)
        #expect(quick.visibleRuns.isEmpty)
        try await quick.flush(); try await store.close()
    }

    @Test func singlePortMultipleCompatibleItemsRequireExplicitChoice() async throws {
        let root = try folder()
        let (store, quick) = try await quick(at: root, operation: WorkflowModelRoutes.ace)
        let port = try #require(quick.definition?.inputs.first { $0.id == "prompt" })
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("one".utf8).write(to: a); try Data("two".utf8).write(to: b)
        let result = await QuickInputImport.run([.file(a), .file(b)], quick: quick,
                                                draft: try #require(quick.draft), port: port)
        #expect(result.published == 2 && result.bound == 0)
        #expect(result.message?.contains("只能绑定一个") == true)
        #expect(quick.draft?.inputs[port.id] == nil)
        #expect((await store.snapshot()).assets.count == 2)
        #expect(quick.visibleRuns.isEmpty)
        try await quick.flush(); try await store.close()
    }

    @Test func foreignManagedDropCopiesPinnedVersionAndProtectsOriginal() async throws {
        let root = try folder()
        let source = try await ProjectStore.create(at: root.appendingPathComponent("Source.dproject"), name: "Source")
        let original = try await source.importWorkflowPNG(png(), name: "source.png").record.reference
        let sourceBefore = await source.snapshot()
        let (destination, quick) = try await quick(at: root, operation: WorkflowModelRoutes.qwen35)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let item = WorkflowCanvasTransfer.assetInstance(projectID: sourceBefore.id,
            instanceID: sourceBefore.effectiveInstanceID, assetID: original.assetID)
        let result = await QuickInputImport.run([.managed(item)], quick: quick,
            draft: try #require(quick.draft), port: port,
            resolveSharedAsset: { project, instance, asset in
                #expect(project == sourceBefore.id && instance == sourceBefore.effectiveInstanceID && asset == original.assetID)
                return (source, try await source.pinWorkflowAsset(asset), "source.png")
            })
        #expect(result.published == 1 && result.copied == 1 && result.bound == 1)
        let copied = try #require(port.resolveAssets(#require(quick.draft?.inputs[port.id])).first)
        #expect(copied.projectID == (await destination.snapshot()).id)
        let copiedBytes = try await destination.workflowData(copied)
        let originalBytes = try await source.workflowData(original)
        #expect(copiedBytes == originalBytes)
        #expect((await source.snapshot()).assets == sourceBefore.assets)
        #expect(quick.visibleRuns.isEmpty)
        try await quick.flush(); try await destination.close(); try await source.close()
    }

    @Test func cancellationWhileLastForeignResolverIgnoresItKeepsEarlierAssetWithoutBindingOrLateCopy() async throws {
        let root = try folder()
        let source = try await ProjectStore.create(at: root.appendingPathComponent("Source.dproject"), name: "Source")
        let original = try await source.importWorkflowPNG(png(), name: "source.png").record.reference
        let before = await source.snapshot()
        let pinned = try await source.pinWorkflowAsset(original.assetID)
        let (destination, quick) = try await quick(at: root, operation: WorkflowModelRoutes.qwen35)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let draft = try #require(quick.draft)
        let item = WorkflowCanvasTransfer.assetInstance(projectID: before.id,
            instanceID: before.effectiveInstanceID, assetID: original.assetID)
        let gate = QuickResolverGate()
        let earlierImage = try png()
        let runTask = Task {
            await QuickInputImport.run([.png(earlierImage), .managed(item)], quick: quick,
                draft: draft, port: port, resolveSharedAsset: { _, _, _ in
                    await gate.holdIgnoringCancellation()
                    return (source, pinned, "source.png")
                })
        }
        await gate.waitUntilEntered()
        runTask.cancel()
        gate.release()
        let result = await runTask.value
        #expect(result.cancelled && result.bound == 0 && result.published == 1 && result.copied == 0)
        #expect(result.message?.contains("取消") == true)
        #expect(quick.draft?.inputs == draft.inputs)
        #expect(quick.draft?.inputs[port.id] == nil)
        #expect((await destination.snapshot()).assets.map(\.name) == ["Clipboard PNG"])
        #expect((await source.snapshot()).assets == before.assets)
        try await quick.flush(); try await destination.close(); try await source.close()
    }

    @Test func cancellationBeforeCallDoesNotImportOrBind() async throws {
        let root = try folder()
        let (store, quick) = try await quick(at: root, operation: WorkflowModelRoutes.qwen35)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let draft = try #require(quick.draft)
        let image = try png()
        let runTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await QuickInputImport.run([.png(image)], quick: quick, draft: draft, port: port)
        }
        let result = await runTask.value
        #expect(result.cancelled && result.published == 0 && result.bound == 0)
        #expect(quick.draft?.inputs == draft.inputs)
        #expect(quick.draft?.inputs[port.id] == nil)
        #expect((await store.snapshot()).assets.isEmpty)
        try await quick.flush(); try await store.close()
    }
}

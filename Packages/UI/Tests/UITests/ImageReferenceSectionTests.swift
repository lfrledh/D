import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Image reference section")
@MainActor
struct ImageReferenceSectionTests {
    @Test
    func currentDraftAndSubmittedSnapshotHaveSeparateProvenance() throws {
        let assetID = UUID()
        let current = ProjectAsset(id: assetID, relativePath: "Images/\(assetID)/original.png",
            role: .original, metadata: .init(width: 512, height: 768,
                                               imageContentSHA256: String(repeating: "b", count: 64)),
            name: "保留的原图")
        let reference = ImageReference(url: URL(fileURLWithPath: "/private/tmp/frozen.rgb"),
            sha256: String(repeating: "a", count: 64), byteCount: 512 * 768 * 3, width: 512, height: 768)
        let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/private/tmp/model")),
            input: .image(.init(prompt: "提交时的描述", width: 512, height: 512, steps: 4,
                                guidanceScale: 1, seed: 4,
                                executionProfile: ImageExecutionCapability.referenceKlein4B.profile,
                                referenceImage: reference)))
        let job = ProjectJob(id: request.id, documentID: UUID(), request: request, imageReferenceAssetID: assetID)
        let manifest = ProjectManifest(name: "Reference", jobs: [job], assets: [current])

        #expect(ImageReferenceSection.currentReferenceText(asset: nil) == "未选择参考图片。")
        #expect(ImageReferenceSection.currentReferenceText(asset: current).contains("保留的原图（512 × 768）"))
        let submitted = try #require(ImageReferenceSection.submittedReferenceText(job: job, manifest: manifest))
        #expect(submitted.contains("本次提交的参考：保留的原图"))
        #expect(submitted.contains(reference.sha256))
        #expect(submitted.contains("512 × 768"))
        #expect(submitted.contains("rgb8-srgb-v1"))
    }

    @Test
    func narrowAndWideOffscreenSectionKeepsAllReferenceActionsReachable() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-reference-section-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: ImageReferenceSectionEngine(), backendID: "image-reference-section.fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: UserDefaults(suiteName: "D.ImageReferenceSection.\(UUID())")!)
        await service.createProject(at: folder.appendingPathComponent("Reference.dproject"))
        let model = WorkbenchModel(projectSession: service)
        var rectangles: [String: CGRect] = [:]
        let section = ImageReferenceSection(model: model, documentID: model.activeDocumentID,
                                            navigationEpoch: model.projectSession.navigationEpoch)
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: AnyView(
            ScrollView { section.padding(12) }
                .coordinateSpace(name: "image-reference-scroll")
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        try await settle(host, window: window, size: NSSize(width: 230, height: 280))
        let narrow = try actionFrames(from: rectangles)
        assertReachable(narrow, in: host.bounds)
        #expect(narrow.import.maxY < narrow.useSelected.minY)
        #expect(narrow.useSelected.maxY < narrow.clear.minY)

        rectangles.removeAll()
        try await settle(host, window: window, size: NSSize(width: 680, height: 280))
        let wide = try actionFrames(from: rectangles)
        assertReachable(wide, in: host.bounds)
        #expect(abs(wide.import.midY - wide.useSelected.midY) < 2)
        #expect(abs(wide.useSelected.midY - wide.clear.midY) < 2)
        #expect(model.referenceImageAsset == nil)
        #expect(await service.requestClose())
    }

    private func settle(_ host: NSHostingView<AnyView>, window: NSWindow, size: NSSize) async throws {
        window.setContentSize(size)
        host.frame.size = size
        let deadline = ContinuousClock.now + .milliseconds(300)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
    }

    private func actionFrames(from rectangles: [String: CGRect]) throws -> (import: CGRect, useSelected: CGRect, clear: CGRect) {
        (try #require(rectangles["image-reference-import"]),
         try #require(rectangles["image-reference-use-selected"]),
         try #require(rectangles["image-reference-clear"]))
    }

    private func assertReachable(_ actions: (import: CGRect, useSelected: CGRect, clear: CGRect), in viewport: CGRect) {
        for frame in [actions.import, actions.useSelected, actions.clear] {
            #expect(frame.width > 0 && frame.height > 0)
            #expect(frame.minX >= -1 && frame.maxX <= viewport.maxX + 1,
                    "Reference action \(frame) must remain inside the parent ScrollView width \(viewport)")
            #expect(frame.minY >= -1 && frame.maxY <= viewport.maxY + 1,
                    "Reference action \(frame) must be reachable in the parent ScrollView viewport \(viewport)")
        }
    }
}

private actor ImageReferenceSectionEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { .cancelled })
    }
}

import AppKit
import DInference
import DWorkbench
import Foundation
import Observation
import Synchronization
import Testing
import UI

private actor PresentationOutcomeGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor PresentationEngine: InferenceEngine {
    let gate: PresentationOutcomeGate
    init(gate: PresentationOutcomeGate) { self.gate = gate }
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {}, outcome: { [gate] in
            await gate.wait()
            return .cancelled
        })
    }
}

@Suite @MainActor
struct WorkbenchFacadeTests {
    private func session(gate: PresentationOutcomeGate) -> ProjectSession {
        let engine = PresentationEngine(gate: gate)
        return ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "presentation.fixture", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: UserDefaults(suiteName: "D.Presentation.\(UUID())")!)
    }

    @Test func facadeBindingsObserveServiceChangesWithoutDuplicatingState() {
        let service = session(gate: PresentationOutcomeGate())
        let facade = WorkbenchModel(projectSession: service)
        let changed = Mutex(false)
        withObservationTracking { _ = facade.prompt } onChange: { changed.withLock { $0 = true } }
        service.prompt = "Changed by a headless caller"
        #expect(changed.withLock { $0 })
        #expect(facade.prompt == service.prompt)
        facade.seedText = "-"
        #expect(service.seedText == "-")
    }

    @Test func removingPresentationDoesNotCancelOrAbandonAnOwnedTask() async throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("presentation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = PresentationOutcomeGate()
        let service = session(gate: gate)
        await service.createProject(at: folder.resolvingSymlinksInPath().appendingPathComponent("Headless.dproject"))
        try #require(service.manifest != nil, Comment(rawValue: service.errorMessage ?? "Project unavailable"))
        await service.registerModel(at: folder)
        var facade: WorkbenchModel? = WorkbenchModel(projectSession: service)
        facade?.prompt = "This job belongs to the application service"
        await facade?.generate()
        #expect(service.isBusy)
        weak let previousFacade = facade
        facade = nil
        #expect(previousFacade == nil)
        #expect(service.isBusy)
        await gate.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while service.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!service.isBusy)
        let replacement = WorkbenchModel(projectSession: service)
        #expect(replacement.manifest?.jobs.first?.state == .cancelled)
        #expect(await service.requestClose())
    }
    @Test func facadeDocumentsAndComparisonKeepPersistentSelectionIndependent() async throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("exploration-presentation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.resolvingSymlinksInPath().appendingPathComponent("Exploration.dproject")
        let firstDocument = ProjectDocument(name: "First")
        let secondDocument = ProjectDocument(name: "Second")
        var assets: [ProjectAsset] = []
        var jobs: [ProjectJob] = []
        for index in 0..<2 {
            let jobID = UUID()
            let relative = "Tasks/\(jobID)-\(UUID())/image.png"
            let location = project.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<8 { for x in 0..<8 { bitmap.setColor(index == 0 ? .red : .blue, atX: x, y: y) } }
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: location)
            let asset = ProjectAsset(jobID: jobID, relativePath: relative, name: "Candidate \(index)")
            assets.append(asset)
            jobs.append(ProjectJob(id: jobID, documentID: firstDocument.id,
                request: .init(id: jobID, model: .init(directory: folder), input: .image(.init(
                    prompt: "Actual recipe \(index)", width: 512, height: 512, steps: 4, guidanceScale: 1, seed: UInt64(index)))),
                state: .completed, artifactIDs: [asset.id]))
        }
        var first = firstDocument
        first.selectedAssetID = assets[0].id
        let manifest = ProjectManifest(name: "Exploration", jobs: jobs, assets: assets,
            documents: [first, secondDocument], activeDocumentID: first.id)
        try JSONEncoder().encode(manifest).write(to: project.appendingPathComponent("project.json"))
        let service = session(gate: PresentationOutcomeGate())
        let facade = WorkbenchModel(projectSession: service)
        await facade.openProject(at: project)
        try #require(facade.manifest != nil, Comment(rawValue: facade.errorMessage ?? "No project"))
        #expect(facade.selectedAssetID == assets[0].id)
        facade.beginEditing()
        #expect(!(await facade.requestClose()))
        #expect(facade.editorCloseAttempted)
        #expect(facade.manifest != nil)
        facade.endEditing()
        facade.toggleComparisonCandidate(assets[0].id)
        facade.toggleComparisonCandidate(assets[1].id)
        facade.beginComparison()
        #expect(facade.isComparing)
        #expect(facade.comparisonAssetIDs == assets.map(\.id))
        #expect(facade.selectedAssetID == assets[0].id)
        await facade.endComparison()
        #expect(facade.selectedAssetID == assets[0].id)
        await facade.updateAsset(id: assets[1].id, name: "Chosen blue", note: "Better silhouette", isFavorite: true)
        await facade.adoptAsset(assets[1].id)
        await facade.selectAsset(assets[1].id)
        await facade.switchDocument(to: secondDocument.id)
        #expect(facade.visibleAssets.isEmpty)
        await facade.showAllArtworks()
        #expect(facade.visibleAssets.count == 2)
        await facade.selectAsset(assets[0].id)
        await facade.switchDocument(to: first.id)
        #expect(facade.selectedAssetID == assets[1].id)
        #expect(facade.activeDocument?.adoptedAssetID == assets[1].id)
        await facade.createDocument(name: "Third")
        await facade.renameDocument(id: try #require(facade.activeDocumentID), name: "Renamed")
        #expect(facade.documents.last?.name == "Renamed")
        #expect(await facade.requestClose())
        await facade.openProject(at: project)
        #expect(facade.documents.last?.name == "Renamed")
        #expect(facade.manifest?.assets.last?.name == "Chosen blue")
        #expect(facade.manifest?.assets.last?.note == "Better silhouette")
        #expect(facade.manifest?.assets.last?.isFavorite == true)
        #expect(await facade.requestClose())
    }

}

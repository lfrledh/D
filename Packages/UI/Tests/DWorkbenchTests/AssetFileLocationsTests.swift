import Foundation
import Testing
import Synchronization
@testable import DWorkbench

@Suite("Fixed media versions and locations", .serialized)
struct AssetFileLocationsTests {
    private func fixture() async throws -> (URL, ProjectStore, URL) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("Location-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("原声说明 👩🏽‍🎨.txt")
        try Data("原文 e\u{301} 👩🏽‍🎨".utf8).write(to: source)
        return (root, try await ProjectStore.create(at: root.appendingPathComponent("项目.dproject"), name: "位置"), source)
    }
    @Test func browsingDoesNotHashButExplicitVerificationAndUseStillDo() async throws {
        let (_, store, source) = try await fixture()
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: source.path)
        let count = Mutex(0)
        try await AssetLocationFiles.$didHash.withValue({ count.withLock { $0 += 1 } }) {
            for _ in 0..<3 {
                _ = try await store.projectFileOverview()
                let detail = try await store.assetLocationOverview(asset.asset.id)
                #expect(detail.locations.first?.status == .pendingVerification)
                #expect(detail.locations.first?.issue == .metadataChanged)
            }
            #expect(count.withLock { $0 } == 0)
            #expect(await store.snapshot() == before)
            try await store.verifyAssetLocation(asset.asset.id)
            #expect(count.withLock { $0 } == 1)
            _ = try await store.workflowData(asset.record.reference)
            #expect(count.withLock { $0 } > 1)
        }
        try Data("different content".utf8).write(to: source)
        do { try await store.collectAsset(asset.asset.id); Issue.record("Changed bytes accepted") }
        catch let failure as AssetFileOperationFailure { #expect(failure.issue == .contentMismatch) }
        await #expect(throws: (any Error).self) { try await store.workflowData(asset.record.reference) }
        try await store.close()
    }

    @Test func moveKeepsIndependentSourceAndPreferredLocationAcrossColdOpenAndExport() async throws {
        let (root, store, source) = try await fixture()
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("new location")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try await store.collectAsset(asset.asset.id, to: destination)
        let locations = try #require((await store.snapshot()).assets.first?.fileLocations)
        let selected = try #require(locations.locations.first { $0.id == locations.preferredLocationID })
        #expect(selected.role == .independentCopy)
        let copy = try #require(selected.url)
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: copy) == original)
        #expect(try AssetLocationFiles.fingerprint(source).inode != AssetLocationFiles.fingerprint(copy).inode)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect((await reopened.snapshot()).assets.first?.fileLocations == locations)
        let isolated = root.appendingPathComponent("source isolated.txt")
        try FileManager.default.moveItem(at: source, to: isolated)
        #expect(try await reopened.workflowData(asset.record.reference) == original)
        let output = root.appendingPathComponent("delivery.txt")
        try await reopened.export(assetID: asset.asset.id, to: output)
        #expect((await reopened.snapshot()).assets.first?.fileLocations == locations)
        try Data("changed export".utf8).write(to: output)
        #expect(try await reopened.workflowData(asset.record.reference) == original)
        try FileManager.default.moveItem(at: isolated, to: source)
        try await reopened.close()
    }

    @Test(arguments: [0, 1, 2]) func publishedCopyFailuresRetainBothFilesAndDoNotClaimSuccess(point: Int) async throws {
        let (root, store, source) = try await fixture()
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot(), original = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("failed destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try await store.collectAsset(asset.asset.id, to: destination, checkpoint: { phase in
                switch (point, phase) {
                case (0, .published), (1, .verified), (2, .beforeCommit): throw CancellationError()
                default: break
                }
            })
            Issue.record("Expected published failure")
        } catch let failure as AssetFileOperationFailure {
            #expect(failure.stage == (point == 0 ? .writtenSync : (point == 1 ? .writtenVerification : .writtenCommit)))
            let copy = try #require(failure.destination)
            #expect(try Data(contentsOf: copy) == original)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(await store.snapshot() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
        try await store.close()
    }

    @Test func realManifestConflictAfterCopyRetainsSourceAndPublishedCopy() async throws {
        let (root, store, source) = try await fixture()
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let manifestURL = store.rootURL.appendingPathComponent(ProjectStore.manifestFilename)
        let originalManifest = try Data(contentsOf: manifestURL)
        var external = before
        external.name = "Changed by another writer"
        let conflictingManifest = try ProjectFiles.manifestData(external)
        let destination = root.appendingPathComponent("commit conflict")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try await store.collectAsset(asset.asset.id, to: destination, checkpoint: { phase in
                if case .beforeCommit = phase { try conflictingManifest.write(to: manifestURL) }
            })
            Issue.record("Actual commit must reject external manifest change")
        } catch let failure as AssetFileOperationFailure {
            #expect(failure.stage == .writtenCommit)
            #expect(try Data(contentsOf: #require(failure.destination)) == Data(contentsOf: source))
        }
        #expect(await store.snapshot() == before)
        #expect(try Data(contentsOf: manifestURL) == conflictingManifest)
        try originalManifest.write(to: manifestURL)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect((await reopened.snapshot()).assets.first?.fileLocations == before.assets.first?.fileLocations)
        try await reopened.close()
    }

    @Test func cancellationReturnsCommittedBatchRowsAndUnprocessedNames() async throws {
        let (root, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let secondSource = root.appendingPathComponent("second.txt")
        try Data("second content".utf8).write(to: secondSource)
        let second = try await store.importWorkflowMediaFile(at: secondSource, mode: .reference)
        let job = Task {
            try await store.collectProjectMedia(afterItem: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        let rows = try await job.value
        #expect(rows.count == 2 && rows[0].matched && !rows[1].matched)
        #expect(rows[0].outcome == .collected && rows[1].outcome == .notProcessed)
        #expect(Set(rows.map(\.id)) == Set([first.asset.id, second.asset.id]))
        #expect(rows.allSatisfy { $0.assetName != nil })
        #expect(try await store.projectFileOverview().externalCount == 1)
        try await store.close()
    }

    @Test func referenceDoesNotCopyAndInputSnapshotDoesNotChange() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let ref = imported.record.reference
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent(imported.asset.relativePath).path))
        let original = try Data(contentsOf: source)
        #expect(try await store.workflowData(ref) == original)
        let snapshot = try await store.workflowMedia(ref).0
        try Data("外部替换".utf8).write(to: source)
        #expect(try Data(contentsOf: snapshot) == original)
        await #expect(throws: (any Error).self) { try await store.workflowData(ref) }
        let info = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(info.locations.first?.status == .changed)
        #expect(try await store.workflowState().archive?.assets.first?.reference == ref)
        try await store.close()
    }
    @Test func copiedAssetDeepInspectionChecksPublishedDigest() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        #expect(imported.asset.fileLocations == nil)
        let unchanged = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(unchanged.locations.first?.status == .verified)
        try Data("changed copy".utf8).write(to: store.rootURL.appendingPathComponent(imported.asset.relativePath))
        let changed = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(changed.locations.first?.status == .changed)
        #expect(changed.contentSHA256 == imported.record.reference.sha256)
        try await store.close()
    }
    @Test func legacyProjectCopyMaterializesOnlyAfterKnownDigestMatches() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let path = store.rootURL.appendingPathComponent(imported.asset.relativePath)
        #expect((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations == nil)
        let original = try Data(contentsOf: path)
        try Data("different".utf8).write(to: path)
        await #expect(throws: (any Error).self) { try await store.verifyAssetLocation(imported.asset.id) }
        #expect((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations == nil)
        try original.write(to: path)
        try await store.verifyAssetLocation(imported.asset.id)
        let placement = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?.fileLocations)
        #expect(placement.sha256 == imported.record.reference.sha256)
        #expect(placement.locations.count == 1 && placement.locations[0].role == .projectCopy)
        #expect(placement.locations[0].lastVerifiedAt != nil)
        #expect(placement.locations[0].contentCreatedAt == nil)
        try await store.close()
    }
    @Test func collectThenMoveSourceReopenAndExportKeepsOldVersion() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try Data(contentsOf: source)
        #expect(try await store.projectFileOverview().externalCount == 1)
        try await store.collectAsset(imported.asset.id)
        #expect(try await store.projectFileOverview().externalCount == 0)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("moved.txt"))
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowData(imported.record.reference) == original)
        let out = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let receipt = try await reopened.exportWorkflowAssets([imported.record.reference], name: "作品", exportID: UUID(), directory: out)
        #expect(!receipt.names.isEmpty)
        #expect(try await reopened.workflowData(imported.record.reference) == original)
        try await reopened.close()
    }
    @Test func independentLibraryCopyAndSameVersionRelocation() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try Data(contentsOf: source)
        let lib = root.appendingPathComponent("外置库"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: false)
        try await store.collectAsset(imported.asset.id, to: lib)
        try Data("改动源".utf8).write(to: source)
        #expect(try await store.workflowData(imported.record.reference) == original)
        let info = try await store.assetLocationOverview(imported.asset.id, deep: true)
        #expect(info.locations.count == 2)
        #expect(info.locations.contains { $0.status == .changed })
        await #expect(throws: (any Error).self) { try await store.relocateAsset(imported.asset.id, to: source) }
        let replacement = root.appendingPathComponent("同版本.txt"); try original.write(to: replacement)
        try await store.relocateAsset(imported.asset.id, to: replacement)
        #expect(try await store.workflowData(imported.record.reference) == original)
        #expect(try await store.workflowState().archive?.assets.first?.reference == imported.record.reference)
        try await store.close()
    }
    @Test func cancelledCollectionAndRequiredSymlinkPreserveRecord() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let job = Task { try await Task.sleep(for: .milliseconds(30)); try await store.collectAsset(imported.asset.id) }
        job.cancel(); await #expect(throws: (any Error).self) { try await job.value }
        #expect(await store.snapshot() == before)
        let link = root.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: (any Error).self) { try await store.importWorkflowMediaFile(at: link, mode: .reference) }
        #expect(await store.snapshot() == before)
        try await store.close()
    }
    @Test func legacyNineteenMigrationPreservesBytesAndLocationsAbsent() async throws {
        let (_, store, _) = try await fixture()
        var legacy = await store.snapshot(); legacy.schemaVersion = 19; legacy.instanceID = nil
        let path = store.rootURL.appendingPathComponent("project.json")
        try await store.close()
        let old = try JSONEncoder().encode(legacy); try old.write(to: path)
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let current = await reopened.snapshot()
        #expect(current.schemaVersion == 20 && current.id == legacy.id && current.effectiveInstanceID == legacy.id)
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.v19.backup.json")) == old)
        try await reopened.close()
    }

    @Test func failedCollectionDoesNotPublishAndProjectCopyExportChecksDigest() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let workflow = try await store.workflowState().archive
        await #expect(throws: (any Error).self) { try await store.collectAsset(imported.asset.id, to: root.appendingPathComponent("missing")) }
        #expect(await store.snapshot() == before)
        #expect(try await store.workflowState().archive == workflow)
        try await store.collectAsset(imported.asset.id)
        try Data("modified".utf8).write(to: store.rootURL.appendingPathComponent(imported.asset.relativePath))
        let output = root.appendingPathComponent("export.txt")
        await #expect(throws: (any Error).self) { try await store.export(assetID: imported.asset.id, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try await store.close()
    }

    @Test func explicitVerificationPersistsOnlyMatchingSelectedPlacement() async throws {
        let (root, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let other = root.appendingPathComponent("unrelated.txt")
        try Data("other".utf8).write(to: other)
        _ = try await store.importWorkflowMediaFile(at: other, mode: .reference)
        let before = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try await store.verifyAssetLocation(first.asset.id)
        let verified = try await store.assetLocationOverview(first.asset.id)
        #expect(verified.locations.first?.status == .verified)
        let persisted = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        let originalCheck = try #require(before.lastVerifiedAt)
        let newCheck = try #require(persisted.lastVerifiedAt)
        #expect(persisted.lastVerifiedAt != nil)
        #expect(newCheck >= originalCheck)
        #expect(persisted.fingerprint != nil)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let reopenedLocation = try #require((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        #expect(reopenedLocation.lastVerifiedAt == persisted.lastVerifiedAt)
        #expect(reopenedLocation.fingerprint == persisted.fingerprint)
        try Data("changed content".utf8).write(to: source)
        await #expect(throws: (any Error).self) { try await reopened.verifyAssetLocation(first.asset.id) }
        #expect((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first?.lastVerifiedAt == persisted.lastVerifiedAt)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reopened.verifyAssetLocation(first.asset.id)
        }
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect((await reopened.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first?.lastVerifiedAt == persisted.lastVerifiedAt)
        try await reopened.close()
    }

    @Test func independentCopyKeepsOriginalCreationAndRecordsItsOwn() async throws {
        let (root, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let original = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations.first)
        let folder = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await store.collectAsset(first.asset.id, to: folder)
        let locations = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?.fileLocations?.locations)
        let retained = try #require(locations.first(where: { $0.id == original.id }))
        let copy = try #require(locations.first(where: { $0.role == .independentCopy }))
        #expect(retained.contentCreatedAt == original.contentCreatedAt)
        #expect(retained.registeredAt == original.registeredAt)
        #expect(copy.id != original.id && copy.contentCreatedAt != nil)
        #expect(copy.registeredAt >= original.registeredAt)
        try await store.relocateAsset(first.asset.id, to: try #require(copy.url))
        let sameCopy = try #require((await store.snapshot()).assets.first(where: { $0.id == first.asset.id })?
            .fileLocations?.locations.first(where: { $0.id == copy.id }))
        #expect(sameCopy.role == .independentCopy)
        #expect(sameCopy.contentCreatedAt == copy.contentCreatedAt)
        #expect(sameCopy.registeredAt == copy.registeredAt)
        try await store.close()
    }

    @Test func movedProjectCopyRelocatesAsExternalAndRemainsReadable() async throws {
        let (root, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let original = try Data(contentsOf: source)
        try await store.verifyAssetLocation(imported.asset.id)
        let before = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?
            .fileLocations?.locations.first)
        let packageFile = store.rootURL.appendingPathComponent(imported.asset.relativePath)
        let moved = root.appendingPathComponent("moved-project-copy.txt")
        try FileManager.default.moveItem(at: packageFile, to: moved)
        try await store.relocateAsset(imported.asset.id, to: moved)
        let relocated = try #require((await store.snapshot()).assets.first(where: { $0.id == imported.asset.id })?
            .fileLocations?.locations.first)
        #expect(relocated.id == before.id)
        #expect(relocated.role == .externalOriginal)
        #expect(relocated.registeredAt == before.registeredAt)
        if let created = before.contentCreatedAt { #expect(relocated.contentCreatedAt == created) }
        try await store.verifyAssetLocation(imported.asset.id)
        #expect(try await store.workflowData(imported.record.reference) == original)
        let output = root.appendingPathComponent("exported-copy.txt")
        try await store.export(assetID: imported.asset.id, to: output)
        #expect(try Data(contentsOf: output) == original)
        try await store.close()
    }

    @Test func knownUsesCollectStructuredFieldsMusicSourcesAndDeduplicateEachOwner() async throws {
        let (_, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let second = try await store.publishWorkflowAsset(data: Data("second".utf8), mediaType: "text/plain",
            name: "second", operationID: "d.asset.import")
        let unused = try await store.publishWorkflowAsset(data: Data("unused".utf8), mediaType: "text/plain",
            name: "unused", operationID: "d.asset.import")
        let ref = first.record.reference, other = second.record.reference
        func node() throws -> WorkflowNode {
            try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        }
        var value = try node(); value.dataConfiguration = .init(value: .asset(ref))
        var duplicates = try node(); duplicates.assetReference = ref
        duplicates.dataConfiguration = .init(value: .asset(ref),
            rules: [.init(comparison: .equals, value: .asset(ref))],
            items: [.init(id: "first", value: .asset(ref)), .init(id: "other", value: .asset(other))])
        var itemOnly = try node()
        itemOnly.dataConfiguration = .init(value: .text("item references"), items: [.init(id: "source", value: .asset(ref))])
        var ruleOnly = try node()
        ruleOnly.dataConfiguration = .init(value: .text("rule references"), rules: [.init(comparison: .equals, value: .asset(other))])
        var music = try node()
        music.dataConfiguration = .init(value: try WorkflowNoteSequence(clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 0.2, velocity: 0.5)], duration: 0.2,
            sources: [ref, other]).datum())
        let graph = WorkflowGraph(name: "structured references", nodes: [value, duplicates, itemOnly, ruleOnly, music])
        let derived = try await store.publishWorkflowAsset(data: Data("derived".utf8), mediaType: "text/plain",
            name: "derived once", parents: [ref, ref], operationID: "test.derived")
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: archive.revision)
        let firstUses = try await store.assetLocationOverview(first.asset.id)
        #expect(firstUses.knownUseCount == 5)
        #expect(firstUses.knownUses.filter { $0.kind == .graph }.count == 4)
        #expect(firstUses.knownUses.contains { $0.nodeID == itemOnly.id })
        #expect(firstUses.knownUses.filter { $0.nodeID == duplicates.id }.count == 1)
        #expect(firstUses.knownUses.filter { $0.assetID == derived.asset.id }.count == 1)
        let secondUses = try await store.assetLocationOverview(second.asset.id)
        #expect(secondUses.knownUseCount == 3)
        #expect(Set(secondUses.knownUses.compactMap(\.nodeID)) == Set([duplicates.id, ruleOnly.id, music.id]))
        #expect(firstUses.knownUses.filter { $0.kind == .graph }.allSatisfy { $0.graphID == graph.id })
        #expect(try await store.assetLocationOverview(unused.asset.id).knownUseCount == 0)
        try await store.close()
    }

    @Test func nestedUsesNavigateRootContainerAndToolsAndHistoryHaveNoInventedTarget() async throws {
        let (_, store, source) = try await fixture()
        let first = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let second = try await store.publishWorkflowAsset(data: Data("second".utf8), mediaType: "text/plain",
            name: "second", operationID: "d.asset.import")
        func node(_ operation: String, _ title: String) throws -> WorkflowNode {
            var node = try #require(WorkflowRegistry.standard.operation(operation)).definition.makeNode()
            node.title = title; return node
        }
        var yes = try node("d.value.input", "inner first")
        yes.dataConfiguration = .init(value: .asset(first.record.reference))
        var no = try node("d.value.input", "inner second")
        no.dataConfiguration = .init(value: .asset(second.record.reference))
        let yesGraph = WorkflowGraph(name: "then graph", nodes: [yes])
        let noGraph = WorkflowGraph(name: "otherwise graph", nodes: [no])
        var branch = try node("d.control.branch", "branch")
        branch.control = .branch(predicate: .init(comparison: .equals, value: .boolean(true)),
            then: yesGraph, otherwise: noGraph)
        var loop = try node("d.control.loop", "loop")
        loop.control = .loop(body: WorkflowGraph(name: "loop body", nodes: [branch]), stateSchema: .text,
            maximumIterations: 2, until: .init(comparison: .equals, value: .text("done")))
        var map = try node("d.control.map", "root container")
        map.control = .map(body: WorkflowGraph(name: "map body", nodes: [loop]), continueOnFailure: false)
        let graph = WorkflowGraph(name: "root workflow", nodes: [map])
        var toolGraph = WorkflowGraph(name: "tool body", nodes: [yes])
        toolGraph.interface = .init(outputs: [.init(name: "output", nodeID: yes.id, schema: .asset(.text))])
        let tool = WorkflowToolDefinition(name: "retained tool", graph: toolGraph)
        // The frozen history reuses node/graph identities but must remain a separate use.
        var history = WorkflowRun(graph: yesGraph, targetNodeID: yes.id)
        var step = WorkflowStepRun(node: yes, signature: "legacy history",
            inputs: ["other": .asset(second.record.reference)],
            outputs: ["first": .asset(first.record.reference),
                "duplicates": .collection([.init(asset: first.record.reference, seed: "1"),
                    .init(asset: first.record.reference, seed: "2")])])
        step.humanTask = .init(id: step.id, kind: .editText, title: "materials",
            materials: .asset(second.record.reference), resultSchema: .asset(.text))
        history.steps = [step]
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [history], expectedRevision: archive.revision, tools: [tool])
        let uses = try await store.assetLocationOverview(first.asset.id).knownUses
        #expect(uses.count == 3)
        let nested = try #require(uses.first { $0.graphID != nil })
        #expect(nested.graphID == graph.id && nested.nodeID == map.id)
        #expect(nested.detail.contains("Map body") && nested.detail.contains("Loop body") && nested.detail.contains("Branch then"))
        #expect(nested.detail.contains(yesGraph.id.uuidString) && nested.detail.contains(yes.id.uuidString))
        let toolUse = try #require(uses.first { $0.title.contains(tool.name) })
        #expect(toolUse.detail.contains("工具定义") && toolUse.graphID == nil && toolUse.nodeID == nil)
        let runUse = try #require(uses.first { $0.kind == .run })
        #expect(runUse.detail.contains("历史流程") && runUse.graphID == nil && runUse.nodeID == nil)
        #expect(runUse.detail.contains(yesGraph.id.uuidString) && runUse.detail.contains(yes.id.uuidString))
        #expect(uses.filter { $0.kind == .run }.count == 1)
        let otherUses = try await store.assetLocationOverview(second.asset.id).knownUses
        #expect(otherUses.count == 2)
        #expect(otherUses.contains { $0.graphID == graph.id && $0.nodeID == map.id && $0.detail.contains("Branch otherwise") })
        #expect(otherUses.filter { $0.kind == .run }.count == 1)
        try await store.close()
    }

    @Test func checkpointOnlyAssetArgumentsAreKnownRunUses() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        var node = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        node.parameters["publicName"] = .text("source")
        node.dataConfiguration = .init(schema: .asset(.text))
        var graph = WorkflowGraph(name: "checkpoint history", nodes: [node])
        graph.interface = .init(inputs: [.init("source", .asset(.text))])
        let plan = try WorkflowPlanCompiler().compile(graph, target: node.id)
        var run = WorkflowRun(graph: graph, targetNodeID: node.id)
        run.planCheckpoint = .init(runID: run.id, plan: plan,
            arguments: ["source": .asset(imported.record.reference)])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [], runs: [run], expectedRevision: archive.revision)
        let overview = try await store.assetLocationOverview(imported.asset.id)
        #expect(overview.knownUseCount == 1)
        #expect(overview.knownUses.first?.kind == .run)
        #expect(overview.knownUses.first?.graphID == nil && overview.knownUses.first?.nodeID == nil)
        try await store.close()
    }

    @Test(arguments: ["project", "version", "kind", "digest"])
    func historyReferenceWithSameAssetIDButDifferentIdentityDoesNotCount(difference: String) async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .copy)
        let ref = imported.record.reference
        let mismatch = WorkflowAssetReference(projectID: difference == "project" ? UUID() : ref.projectID,
            assetID: ref.assetID, version: difference == "version" ? UUID() : ref.version,
            kind: difference == "kind" ? .image : ref.kind,
            sha256: difference == "digest" ? String(repeating: "0", count: 64) : ref.sha256)
        var node = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        node.dataConfiguration = .init(value: .text("no local references"))
        let graph = WorkflowGraph(name: "legacy materials history", nodes: [node])
        var step = WorkflowStepRun(node: node, signature: "legacy history")
        // Legacy human materials may describe an external version; matching the local
        // asset ID alone must not turn that description into a use of our published version.
        step.humanTask = .init(id: step.id, kind: .editText, title: "external materials",
            materials: .asset(mismatch), resultSchema: .asset(mismatch.kind))
        let run = WorkflowRun(graph: graph, targetNodeID: node.id, steps: [step])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [run], expectedRevision: archive.revision)
        #expect(try await store.assetLocationOverview(imported.asset.id).knownUseCount == 0)
        // The exact reference in that same field must produce one run use.
        step.humanTask?.materials = .asset(ref)
        var exact = run; exact.steps = [step]
        let current = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [exact], expectedRevision: current.revision)
        #expect(try await store.assetLocationOverview(imported.asset.id).knownUseCount == 1)
        try await store.close()
    }

    @Test func knownUsesNameGraphNodeAndDerivedAsset() async throws {
        let (_, store, source) = try await fixture()
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let child = try await store.publishWorkflowAsset(data: Data("derived".utf8), mediaType: "text/plain",
            name: "派生版本", parents: [imported.record.reference], operationID: "test.derived")
        var node = try #require(WorkflowRegistry.standard.operation("d.asset.reference")).definition.makeNode()
        node.assetReference = imported.record.reference
        let graph = WorkflowGraph(name: "使用素材的流程", nodes: [node])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: archive.revision)
        let overview = try await store.assetLocationOverview(imported.asset.id)
        #expect(overview.knownUseCount == 2)
        #expect(overview.knownUses.contains { $0.kind == .graph && $0.graphID == graph.id && $0.nodeID == node.id && $0.title == graph.name })
        #expect(overview.knownUses.contains { $0.kind == .derivedAsset && $0.assetID == child.asset.id && $0.title == "派生版本" })
        try await store.close()
    }
}

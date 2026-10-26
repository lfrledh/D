import AppKit
import CoreTransferable
import DWorkbench
import DInference
import Foundation
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import UI

@Suite @MainActor
struct SharedLibraryBrowserTests {
    @Test(arguments: [
        ("Read-only sample.txt", "txt", "Read-only sample.txt"),
        ("Read-only sample.TXT", "txt", "Read-only sample.TXT"),
        ("Read-only sample", "txt", "Read-only sample.txt"),
        ("报告.v2", "txt", "报告.v2.txt"),
        ("photo.jpeg", "jpg", "photo.jpeg"),
        ("photo.source", "png", "photo.source.png")
    ])
    func externalCopySuggestionPreservesNamesWithoutRepeatingFormat(value: (String, String, String)) {
        #expect(suggestedExternalCopyName(value.0, suffix: value.1) == value.2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_TREE_AX"] == "1", "Requires a visible AX host; hidden native geometry is checked separately"), arguments: [260.0, 360.0], ["zh-Hans", "en"])
    func nativeCompactOperationTreeIndentsEveryExpandedLevel(width: Double, locale: String) async throws {
        let language = UILanguageStore(preferredLanguages: [locale])
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: language)
        let model = try #require(entries.first { $0.item.kind == .model && $0.item.title.contains("Qwen") })
        let store = try SharedLibraryStore(), state = SharedLibraryBrowserState(selectedKeys: [model.id], focusedKey: model.id)
        var actions = 0
        let browser = SharedLibraryBrowser(entries: [model], store: store, compact: true, canvasMode: .nodes,
            state: state, onUse: { _ in actions += 1 }, onAdd: { _ in actions += 1 },
            onPreview: { _ in actions += 1 }, onPrepare: { _ in actions += 1 },
            onImport: { actions += 1 }, onClose: { actions += 1 })
            .environment(\.dLanguageStore, language)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 1400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: browser); window.contentView = host
        host.frame = .init(x: 0, y: 0, width: width, height: 1400)
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil) // Only the explicitly enabled native AX fixture.
        func settle() async throws {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func accessible() -> [any NSAccessibilityProtocol] {
            var pending: [NSObject] = [host], seen = Set<ObjectIdentifier>(), result: [any NSAccessibilityProtocol] = []
            while let object = pending.popLast(), seen.count < 3000 {
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
                if let value = object as? any NSAccessibilityProtocol {
                    result.append(value)
                    pending += (value.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                }
                if let view = object as? NSView { pending += view.subviews }
            }
            return result
        }
        try await settle()
        var path = try #require(WorkflowOperationTree.make([model], models: true, language: language).first)
        var origins: [CGFloat] = [], firstButton: (any NSAccessibilityProtocol)?
        while path.entry == nil {
            let button = try #require(accessible().first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == path.title }, "Real group button: \(path.title)")
            if firstButton == nil { firstButton = button }
            origins.append(button.accessibilityFrame().minX)
            #expect(button.accessibilityValue() as? String == (locale == "en" ? "Collapsed" : "已收起"))
            try #require(button.accessibilityPerformPress())
            try await settle()
            path = try #require(path.children?.first)
        }
        #expect(origins.count == 2) // Modality → registered family; specifications live on the model card.
        for pair in zip(origins, origins.dropFirst()) { #expect(abs(pair.1 - pair.0 - 12) < 1) }
        let leaf = try #require(accessible().first { $0.accessibilityIdentifier() == "shared-library-entry-" + model.id })
        #expect(abs(leaf.accessibilityFrame().minX - (try #require(origins.last)) - 12) < 1)
        #expect(leaf.accessibilityFrame().maxX <= window.convertToScreen(host.convert(host.bounds, to: nil)).maxX + 1)
        #expect(state.selectedKeys == [model.id] && state.focusedKey == model.id && actions == 0)
        try #require(firstButton?.accessibilityPerformPress() == true)
        try await settle()
        #expect(!accessible().contains { $0.accessibilityIdentifier() == "shared-library-entry-" + model.id })
        #expect(state.selectedKeys == [model.id] && actions == 0)
    }

    @Test(arguments: [260.0, 360.0], ["zh-Hans", "en"])
    func operationDisclosureStyleLaysOutEachLevelAndCollapses(width: Double, locale: String) async throws {
        let language = UILanguageStore(preferredLanguages: [locale])
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: language)
        let model = try #require(entries.first { $0.item.kind == .model && $0.item.title.contains("Qwen") })
        let tree = WorkflowOperationTree.make([model], models: true, language: language)
        var path = try #require(tree.first), groups: [WorkflowOperationTree] = []
        while path.entry == nil { groups.append(path); path = try #require(path.children?.first) }
        let state = OperationDisclosureFixtureState(); state.expanded = Set(groups.map(\.id))
        let host = NSHostingView(rootView: OperationDisclosureFixture(nodes: tree, state: state)
            .disclosureGroupStyle(WorkflowOperationTreeDisclosureStyle()).environment(\.dLanguageStore, language))
        host.frame = .init(x: 0, y: 0, width: width, height: 1000)
        func settle() async throws {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func frame(_ id: String) throws -> CGRect {
            let probe = try #require(views(host).first { $0.identifier?.rawValue == id })
            return probe.convert(probe.bounds, to: host)
        }
        try await settle()
        let labels = try groups.map { try frame($0.id) }
        #expect(labels.count == 2) // Current two-level operation library, not the retired four-level tree.
        for pair in zip(labels, labels.dropFirst()) { #expect(abs(pair.1.minX - pair.0.minX - 12) < 1) }
        let leaf = try frame(model.id)
        // Group labels follow a 12 pt chevron plus a 6 pt gap. Leaves have no chevron.
        #expect(abs(leaf.minX - (try #require(labels.last)).minX - 12 + 18) < 1)
        #expect(leaf.maxX <= width + 1 && leaf.width > 180)
        state.expanded.remove(try #require(groups.first).id); try await settle()
        #expect(!views(host).contains { $0.identifier?.rawValue == model.id })
        state.expanded.insert(try #require(groups.first).id); try await settle()
        #expect(try frame(model.id) == leaf)
    }

    @Test func libraryProjectionReuseKeepsLiveFactsAndExactSelections() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("projection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Fixture.dproject"), name: "Original")
        let asset = try await store.publishWorkflowAsset(data: Data("unchanged".utf8), mediaType: "text/plain",
            name: "Asset", operationID: "fixture.projection")
        var project = await store.snapshot()
        let cache = SharedLibraryProjectionCache(), tags = ModelNodeTagStore()
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        var choices: [WorkflowModelChoice] = [], readiness: [String:SharedLibraryReadiness] = [:]
        var tools: [WorkflowToolDefinition] = [], metadata: [String:ProjectAssetMetadataSnapshot] = [:]
        func read(_ currentTags: ModelNodeTagStore? = nil) -> [SharedLibraryBrowserEntry] {
            cache.entries(models: choices, readiness: readiness, tools: tools, projects: [project],
                language: language, metadata: metadata, tags: currentTags ?? tags)
        }
        func expectFresh() {
            let expected = SharedLibraryProjection.entries(models: choices, readiness: readiness, tools: tools,
                projects: [project], language: language, metadata: metadata).map { entry in
                    var value = entry
                    if entry.item.kind == .model || entry.item.kind == .program {
                        let old = SharedLibraryTagTarget.legacy(tags.readState(for: entry.item.key))
                        value.legacyTags = old.names; value.legacyFailure = old.failure
                    }
                    return value
                }
            #expect(read() == expected)
        }
        let first = read(), selected = cache.selection(canvasMode: .nodes, family: nil)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { #expect(read() == first); #expect(cache.selection(canvasMode: .nodes, family: nil) == selected) }
        let reusedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let referenceStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { _ = SharedLibraryProjection.entries(models: choices, readiness: readiness, tools: tools,
            projects: [project], language: language, metadata: metadata) }
        print("LIBRARY_PROJECTION_COMPONENT iterations=200 reused_ms=\(reusedMS) uncached_ms=\((ProcessInfo.processInfo.systemUptime-referenceStart)*1000) not_FPS=true")
        #expect(cache.projectionCount == 1)
        let modelRow = try #require(first.first { $0.item.kind == .model && $0.item.readiness == .unprepared })
        guard case .operation(_, let id?) = modelRow.selection else { Issue.record("Expected exact model binding"); return }
        let descriptor = try #require(ModelNodeCatalog.entries.first { $0.id == modelRow.id })
        choices = [.init(id: id, kind: try #require(SharedLibraryProjection.modelKind(descriptor)), displayName: "User choice")]
        for value in [SharedLibraryReadiness.available, .unavailable] {
            readiness[id] = value; expectFresh()
            #expect(read().first { $0.id == modelRow.id }?.item.readiness == value)
            #expect(cache.selection(canvasMode: .nodes, family: nil).first { $0.id == modelRow.id }?.item.readiness == value)
        }
        // Same IDs/revisions deliberately change: a revision-only cache is insufficient.
        project.name = "Renamed"; project.assets[0].note = "Changed note"; expectFresh()
        #expect(read().first { $0.item.kind == .asset }?.item.assetFacts?.note == "Changed note")
        metadata["asset-instance:" + project.effectiveInstanceID.uuidString + ":" + asset.record.reference.assetID.uuidString] =
            .init(project: project, asset: project.assets[0], record: asset.record, job: nil, occurrences: [], sourceIssue: nil)
        expectFresh()
        tools = [.init(name: "Tool", graph: WorkflowGraph(name: "Tool graph"))]; expectFresh()
        tools[0].name = "Changed same version"; expectFresh()
        #expect(read().contains { $0.item.title == "Changed same version" })
        try tags.setTags(["live tag"], for: modelRow.item.key); expectFresh()
        #expect(read().first { $0.id == modelRow.id }?.legacyTags == ["live tag"])
        #expect(cache.selection(canvasMode: .nodes, family: nil).first { $0.id == modelRow.id }?.legacyTags == ["live tag"])
        #expect(read(ModelNodeTagStore()).first { $0.id == modelRow.id }?.legacyTags == [])
        expectFresh()
        try language.select("en"); expectFresh()
        language.testingBuiltIn(.init(schemaVersion: 1, locale: "en", displayName: "English",
            strings: ["consistency.copy.verifyBeforeRun": "Updated bundle text"]))
        let before = cache.projectionCount; expectFresh(); #expect(cache.projectionCount == before + 1)
        #expect(read().first { $0.id == modelRow.id }?.facts.contains("Updated bundle text") == true)
        try await store.close()
    }

    @Test(arguments: ["all", "nodes", "programs", "text", "image", "video", "audio"])
    func projectionSelectionMatchesExistingCommandFilter(mode: String) {
        let cache = SharedLibraryProjectionCache(), tags = ModelNodeTagStore()
        let rows = cache.entries(models: [], readiness: [:], tools: [], projects: [], language: nil, metadata: [:], tags: tags)
        let canvas: WorkflowCanvasLibraryMode? = mode == "nodes" ? .nodes : mode == "programs" ? .programs : nil
        let family = QuickCategory(rawValue: mode)
        let expected = rows.filter { value in
            if let canvas { return canvas == .nodes ? value.item.kind == .model || value.item.kind == .component : value.item.kind == .program || value.item.kind == .tool }
            guard let family else { return true }
            guard case .operation(let operation, _) = value.selection else { return false }
            return QuickCategory.category(for: operation) == family
        }
        for _ in 0..<5 { #expect(cache.selection(canvasMode: canvas, family: family) == expected) }
        #expect(!expected.isEmpty)
    }

    @Test func restoredInstanceHasSeparateRowsAndDragWhileTagKeyRemainsLogical() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("library-instances-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("one content version".utf8).write(to: source)
        let original = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Original")
        let asset = try await original.importWorkflowMediaFile(at: source)
        let backup = root.appendingPathComponent("Backup.dbackup")
        _ = try await original.createBackup(at: backup)
        _ = try await ProjectStore.restoreBackup(at: backup, to: root.appendingPathComponent("Restored.dproject"))
        let restored = try await ProjectStore.open(at: root.appendingPathComponent("Restored.dproject"))
        let first = await original.snapshot(), second = await restored.snapshot()
        #expect(first.id == second.id)
        #expect(first.effectiveInstanceID != second.effectiveInstanceID)
        let rows = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [],
            projects: [first, second], language: nil).filter { $0.item.kind == .asset }
        #expect(rows.count == 2)
        #expect(rows[0].id != rows[1].id)
        #expect(rows[0].item.key == rows[1].item.key)
        #expect(rows[0].item.key == "asset:\(first.id.uuidString):\(asset.asset.id.uuidString)")
        #expect(SharedLibraryProjection.resolvedInstanceID(projectID: first.id, instanceID: nil,
            projects: [first, second]) == nil)
        #expect(SharedLibraryProjection.resolvedInstanceID(projectID: first.id,
            instanceID: second.effectiveInstanceID, projects: [first, second]) == second.effectiveInstanceID)
        let payload = try #require(SharedLibraryBrowserLogic.canvasTransfer(for: rows[1]))
        #expect(try WorkflowCanvasTransfer.decode(payload.encoded()) ==
            .assetInstance(projectID: first.id, instanceID: second.effectiveInstanceID, assetID: asset.asset.id))
        let metadata = try SharedLibraryStore(fileURL: root.appendingPathComponent("shared.json"))
        let originalBytes = try Data(contentsOf: original.rootURL.appendingPathComponent("project.json"))
        let restoredBytes = try Data(contentsOf: restored.rootURL.appendingPathComponent("project.json"))
        let key = rows[0].item.key
        try metadata.editOrganizationTags(expected: .init(keys: [key], metadata: metadata.metadata), createNames: ["shared across instances"], confirmIntegration: [key])
        let tag = try #require(metadata.metadata.tags.values.first?.id)
        let filtered = try SharedLibraryBrowserLogic.visibleEntries(rows, store: metadata, query: .init(allTagIDs: [tag]), scope: .all)
        #expect(filtered.count == 2 && Set(filtered.map(\.item.key)).count == 1)
        try metadata.editOrganizationTags(expected: .init(keys: [key], metadata: metadata.metadata), remove: [tag])
        let reopened = try SharedLibraryStore(fileURL: root.appendingPathComponent("shared.json"))
        #expect(try SharedLibraryBrowserLogic.visibleEntries(rows, store: reopened, query: .init(allTagIDs: [tag]), scope: .all).isEmpty)
        #expect(try Data(contentsOf: original.rootURL.appendingPathComponent("project.json")) == originalBytes)
        #expect(try Data(contentsOf: restored.rootURL.appendingPathComponent("project.json")) == restoredBytes)
        try await restored.close(); try await original.close()
    }
    @Test func selectingOneRestoredRowDoesNotIntegrateUnselectedLegacySource() throws {
        let project = UUID(), asset = UUID(), a = UUID(), b = UUID()
        let key = "asset:\(project):\(asset)"
        let first = SharedLibraryBrowserEntry(item: .init(key: key, title: "same", kind: .asset),
            selection: .assetInstance(projectID: project, instanceID: a, assetID: asset), activityID: "first", legacyTags: ["first only"])
        let second = SharedLibraryBrowserEntry(item: first.item,
            selection: .assetInstance(projectID: project, instanceID: b, assetID: asset), activityID: "second", legacyTags: ["not selected"])
        let selected = SharedLibraryBrowserLogic.tagEditEntries(["first"], in: [first, second])
        #expect(selected.map(\.id) == ["first"])
        #expect(selected.flatMap(\.legacyTags) == ["first only"])
        #expect(SharedLibraryBrowserLogic.tagEditEntries(["first", "second"], in: [first, second]).count == 2)
    }
    @Test func externalVideoModelsKeepExactQuickAndCanvasOperationBindings() throws {
        let profiles = ExternalVideoExecutionProfile.allCases
        let choices = profiles.map { WorkflowModelChoice(id: "video:" + $0.modelIdentity, kind: .video, displayName: "registered copy") }
        for choices in [[], choices] {
            let entries = SharedLibraryProjection.entries(models: choices, readiness: [:], tools: [], projects: [], language: nil)
            for profile in profiles {
                let entry = try #require(entries.first { $0.id == "video.model." + profile.rawValue })
                guard case .operation(let operation, let modelID) = entry.selection else { Issue.record("Missing model operation"); continue }
                #expect(operation == WorkflowVideoRecipe(profile: profile).operationID)
                #expect(operation != "d.video.generate")
                #expect(modelID == "video:" + profile.modelIdentity)
                #expect(entry.item.readiness != .available)
            }
        }
    }
    @Test func fixedTextIdentitySnapshotDoesNotCacheLiveModelReadiness() throws {
        let identities = [try #require(TextModelProfiles.registered().first?.id),
                          try #require(TextModelProfiles.registeredVLM().first?.id)]
        for identity in identities {
            let descriptor = try #require(ModelNodeCatalog.entries.first { $0.modelIdentity == identity })
            let initial = try #require(SharedLibraryProjection.entries(models: [], readiness: [:], tools: [],
                projects: [], language: nil).first { $0.id == descriptor.id })
            guard case .operation(let operation, let modelID) = initial.selection else {
                Issue.record("Bundled text model lost its operation"); continue
            }
            let choice = WorkflowModelChoice(id: try #require(modelID), kind: .text, displayName: "installed model")
            #expect(initial.item.readiness == .unprepared)
            for readiness in [SharedLibraryReadiness.available, .unavailable] {
                let current = try #require(SharedLibraryProjection.entries(models: [choice],
                    readiness: [choice.id: readiness], tools: [], projects: [], language: nil)
                    .first { $0.id == descriptor.id })
                #expect(current.item.readiness == readiness)
                #expect(current.selection == .operation(id: operation, modelID: modelID))
            }
            let removed = try #require(SharedLibraryProjection.entries(models: [], readiness: [:], tools: [],
                projects: [], language: nil).first { $0.id == descriptor.id })
            #expect(removed.item.readiness == .unprepared)
            #expect(removed.selection == initial.selection)
        }
    }
    @Test func applicationDeclaresTheActualCanvasTransferType() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("D/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == UTType.workflowCanvasItem.identifier })
        let parents = try #require(declaration["UTTypeConformsTo"] as? [String])
        #expect(parents.contains(UTType.data.identifier))
        #expect(UTType.workflowCanvasItem.conforms(to: .data))
    }
    private func entry(
        _ key: String, title: String, kind: SharedLibraryItemKind = .program,
        inputs: Set<WorkflowDataKind> = [], outputs: Set<WorkflowDataKind> = [],
        readiness: SharedLibraryReadiness = .available,
        compatible: Bool? = true,
        selection: SharedLibraryBrowserSelection? = nil
    ) -> SharedLibraryBrowserEntry {
        SharedLibraryBrowserEntry(
            item: SharedLibraryItem(
                key: key, title: title, kind: kind, inputs: inputs, outputs: outputs,
                readiness: readiness, compatible: compatible
            ),
            selection: selection ?? .operation(id: key, modelID: nil)
        )
    }

    @Test func nativeDragProviderPreservesCanvasPayloadAndLibraryKey() async throws {
        let current = entry("operation:d.text.input", title: "文字输入",
                            selection: .operation(id: "d.text.input", modelID: nil))
        let provider = SharedLibraryBrowserLogic.dragProvider(for: current)
        print("NATIVE_PROVIDER_TYPES=\(provider.registeredTypeIdentifiers)")
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "org.d-workbench.canvas-item") { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
        }
        let expected = WorkflowCanvasTransfer.operation(id: "d.text.input", modelID: nil)
        #expect(try WorkflowCanvasTransfer.decode(data) == expected)
        let actual: WorkflowCanvasTransfer = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: WorkflowCanvasTransfer.self) { continuation.resume(with: $0) }
        }
        #expect(actual == expected)
        let key: String = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: String.self) { continuation.resume(with: $0) }
        }
        #expect(key == current.id)
    }

    @Test
    func realStoreScopesAndIndependentInputOutputFilters() throws {
        let store = try SharedLibraryStore()
        let text = entry("operation:text", title: "文字草稿", inputs: [.text], outputs: [.text])
        let image = entry("operation:image", title: "图像草稿", inputs: [.image], outputs: [.image])
        let both = entry("operation:both", title: "组合", inputs: [.text, .image], outputs: [.image])
        let entries = [text, image, both]
        let tagID = try #require(store.createTags(["常用"]).first)
        try store.addTags([tagID], to: [text.id, both.id])
        let folderID = try store.createFolder(name: "收藏")
        try store.addMembers([image.id, both.id], to: folderID)
        let savedID = try store.createSavedQuery(
            name: "图像输入", query: SharedLibraryQuery(inputs: [.image])
        )

        let query = SharedLibraryQuery(inputs: [.text], outputs: [.image])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: query, scope: .all
        ).map(\.id) == [both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .tag(tagID)
        ).map(\.id) == [text.id, both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .folder(folderID)
        ).map(\.id) == [image.id, both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .kind(.program)
        ).count == 3)
        let savedQuery = try #require(store.metadata.savedQueries[savedID]?.query)
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: savedQuery, scope: .saved(savedID)
        ).map(\.id) == [image.id, both.id])
        #expect(throws: SharedLibraryError.missingFolder) {
            try SharedLibraryBrowserLogic.visibleEntries(
                entries, store: store, query: .init(), scope: .folder(UUID())
            )
        }
    }

    @Test func assetScopesDoNotInheritHiddenCollectedFilterAndSortOnlyPresentation() throws {
        let store = try SharedLibraryStore()
        var z = entry("asset:z", title: "Zebra", kind: .asset), a = entry("asset:a", title: "Alpha", kind: .asset)
        z.collected = true; a.collected = false
        let values = [z, a]
        let folder = try store.createFolder(name: "Both")
        try store.addMembers(Set(values.map(\.id)), to: folder)
        let saved = try store.createSavedQuery(name: "Assets", query: .init(kinds: [.asset]))
        #expect(try SharedLibraryBrowserLogic.visibleEntries(values, store: store, query: .init(), scope: .all, collectedOnly: true).map(\.id) == [z.id])
        for scope: SharedLibraryBrowserScope in [.folder(folder), .saved(saved)] {
            #expect(try SharedLibraryBrowserLogic.visibleEntries(values, store: store, query: .init(), scope: scope, collectedOnly: true).map(\.id) == [z.id, a.id])
            #expect(try SharedLibraryBrowserLogic.visibleEntries(values, store: store, query: .init(text: "Alpha"), scope: scope, collectedOnly: true).map(\.id) == [a.id])
        }
        #expect(try SharedLibraryBrowserLogic.visibleEntries(values, store: store, query: .init(), scope: .all, sort: .nameAscending).map(\.id) == [a.id, z.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(values, store: store, query: .init(), scope: .all, sort: .nameDescending).map(\.id) == [z.id, a.id])
        #expect(values == [z, a] && store.metadata.folders[folder]?.memberKeys == Set(values.map(\.id)))
    }

    @Test
    func savingScopePreservesIntersectionAndRejectsUnrepresentableCases() throws {
        let store = try SharedLibraryStore()
        let firstTag = try #require(store.createTags(["第一"]).first)
        let secondTag = try #require(store.createTags(["第二"]).first)
        let both = entry("model:both", title: "两种标签", kind: .model)
        let firstOnly = entry("model:first", title: "第一标签", kind: .model)
        let secondOnly = entry("model:second", title: "第二标签", kind: .model)
        let asset = entry("asset:other", title: "素材", kind: .asset)
        let entries = [both, firstOnly, secondOnly, asset]
        try store.addTags([firstTag, secondTag], to: [both.id])
        try store.addTags([firstTag], to: [firstOnly.id])
        try store.addTags([secondTag], to: [secondOnly.id])

        let models = try SharedLibraryBrowserLogic.queryForSaving(
            .init(), scope: .kind(.model), store: store
        )
        #expect(models.kinds == [.model])
        let modelQueryID = try store.createSavedQuery(name: "仅模型", query: models)
        let reopenedModels = try #require(store.metadata.savedQueries[modelQueryID]?.query)
        #expect(store.filter(entries.map(\.item), query: reopenedModels).map(\.key)
            == [both.id, firstOnly.id, secondOnly.id])

        let tagQuery = try SharedLibraryBrowserLogic.queryForSaving(
            .init(anyTagIDs: [secondTag]), scope: .tag(firstTag), store: store
        )
        #expect(tagQuery.allTagIDs == [firstTag])
        #expect(tagQuery.anyTagIDs == [secondTag])
        #expect(store.filter(entries.map(\.item), query: tagQuery).map(\.key) == [both.id])
        #expect(throws: SharedLibraryBrowserIssue.conflictingKindScope) {
            try SharedLibraryBrowserLogic.queryForSaving(
                .init(kinds: [.asset]), scope: .kind(.model), store: store
            )
        }
        let folderID = try store.createFolder(name: "手工分类")
        #expect(throws: SharedLibraryBrowserIssue.folderCannotBeSaved) {
            try SharedLibraryBrowserLogic.queryForSaving(
                .init(), scope: .folder(folderID), store: store
            )
        }
    }

    @Test
    func renameDraftsSurviveSelectionReturnAndDeletedScopesRepairWithoutReset() throws {
        let tagID = UUID(), folderID = UUID(), queryID = UUID()
        var drafts = SharedLibraryBrowserRenameDrafts()
        drafts.set("标签草稿", for: .tag(tagID))
        drafts.set("分类草稿", for: .folder(folderID))
        drafts.set("筛选草稿", for: .saved(queryID))
        #expect(drafts.text(for: .tag(tagID), canonical: "旧标签") == "标签草稿")
        #expect(drafts.text(for: .folder(folderID), canonical: "旧分类") == "分类草稿")
        #expect(drafts.text(for: .saved(queryID), canonical: "旧筛选") == "筛选草稿")
        #expect(drafts.text(for: .tag(tagID), canonical: "旧标签") == "标签草稿")
        drafts.clear(.folder(folderID))
        #expect(drafts.text(for: .folder(folderID), canonical: "已改名") == "已改名")

        let store = try SharedLibraryStore()
        let realTagID = try #require(store.createTags(["可删"]).first)
        let parentID = try store.createFolder(name: "父")
        let childID = try store.createFolder(name: "子", parentID: parentID)
        let savedID = try store.createSavedQuery(name: "可删筛选", query: .init())
        let state = SharedLibraryBrowserState(
            query: .init(text: "保留搜索", anyTagIDs: [realTagID]), scope: .tag(realTagID),
            selectedKeys: ["entry:one"], focusedKey: "entry:one"
        )
        try SharedLibraryBrowserLogic.deleteTag(realTagID, store: store, state: state)
        #expect(state.scope == .tag(realTagID))
        #expect(state.query.anyTagIDs == [realTagID])
        state.scope = .folder(childID)
        try SharedLibraryBrowserLogic.deleteFolder(parentID, store: store, state: state)
        #expect(state.scope == .folder(childID))
        state.scope = .saved(savedID)
        try SharedLibraryBrowserLogic.deleteSavedQuery(savedID, store: store, state: state)
        #expect(state.scope == .saved(savedID))
        let protectedTagID = try #require(store.createTags(["受保护"]).first)
        _ = try store.createSavedQuery(
            name: "引用标签", query: .init(allTagIDs: [protectedTagID])
        )
        state.scope = .tag(protectedTagID)
        #expect(throws: SharedLibraryError.tagInSavedQuery) {
            try SharedLibraryBrowserLogic.deleteTag(protectedTagID, store: store, state: state)
        }
        #expect(state.scope == .tag(protectedTagID))
        #expect(state.query.text == "保留搜索")
        #expect(state.selectedKeys == ["entry:one"])
        #expect(state.focusedKey == "entry:one")
    }

    @Test
    func savedScopeFollowsStoreAfterUpdateUndoAndOtherSurfaceChange() throws {
        let store = try SharedLibraryStore()
        let models = SharedLibraryQuery(kinds: [.model])
        let assets = SharedLibraryQuery(kinds: [.asset])
        let savedID = try store.createSavedQuery(name: "类型", query: models)
        let active = SharedLibraryBrowserState(
            query: .init(text: "原自由查询"), selectedKeys: ["keep"], focusedKey: "keep"
        )
        let other = SharedLibraryBrowserState()
        try active.selectScope(.saved(savedID), using: store)
        try other.selectScope(.saved(savedID), using: store)
        #expect(active.query == models)
        #expect(other.effectiveQuery(using: store) == models)

        active.setDraftQuery(assets)
        #expect(active.scope == .all)
        #expect(active.query == assets)
        try store.updateSavedQuery(savedID, name: "类型", query: assets)
        active.reconcile(using: store)
        other.reconcile(using: store)
        #expect(active.query == assets)
        #expect(active.scope == .all)
        #expect(other.scope == .saved(savedID))
        #expect(other.query == assets)

        try active.selectScope(.saved(savedID), using: store)
        try store.undo()
        #expect(active.effectiveQuery(using: store) == models)
        active.reconcile(using: store)
        other.reconcile(using: store)
        #expect(active.scope == .saved(savedID))
        #expect(active.query == models)
        #expect(other.query == models)

        active.setDraftQuery(.init(text: "未保存草稿", kinds: [.asset]))
        let draft = active.query
        try store.updateSavedQuery(savedID, name: "类型", query: assets)
        active.reconcile(using: store)
        other.reconcile(using: store)
        #expect(active.scope == .all)
        #expect(active.query == draft)
        #expect(other.query == assets)
        _ = try store.createTags(["无关标签"])
        active.reconcile(using: store)
        other.reconcile(using: store)
        #expect(active.query == draft)
        #expect(active.selectedKeys == ["keep"])
        #expect(active.focusedKey == "keep")
        #expect(other.query == assets)
    }

    @Test
    func undoAndExternalDeletionRepairOnlyInvalidScope() throws {
        let store = try SharedLibraryStore()
        let state = SharedLibraryBrowserState(
            query: .init(text: "自由搜索"), selectedKeys: ["keep"], focusedKey: "keep"
        )
        let folderID = try store.createFolder(name: "稍后撤销")
        try state.selectScope(.folder(folderID), using: store)
        try store.undo()
        state.reconcile(using: store)
        #expect(state.scope == .folder(folderID))
        #expect(state.query.text == "自由搜索")
        #expect(state.selectedKeys == ["keep"])
        try store.redo()
        state.reconcile(using: store)
        #expect(state.scope == .folder(folderID))

        let tagID = try #require(store.createTags(["跨视图标签"]).first)
        try state.selectScope(.tag(tagID), using: store)
        try store.deleteTags([tagID])
        state.reconcile(using: store)
        #expect(state.scope == .tag(tagID))
        #expect(state.query.text == "自由搜索")

        let savedID = try store.createSavedQuery(name: "跨视图筛选", query: .init(kinds: [.model]))
        try state.selectScope(.saved(savedID), using: store)
        try store.deleteSavedQuery(savedID)
        state.reconcile(using: store)
        #expect(state.scope == .saved(savedID))
        #expect(state.query.text == "")
        #expect(state.selectedKeys == ["keep"])
        #expect(state.focusedKey == "keep")
    }

    @Test
    func dropRequiresCurrentEntryKeysAndCanvasPayloadKeepsProjectScope() throws {
        let projectID = UUID(), assetID = UUID()
        let asset = entry(
            "asset:\(projectID):\(assetID)", title: "素材", kind: .asset,
            selection: .asset(projectID: projectID, assetID: assetID)
        )
        let program = entry("operation:known", title: "程序")
        let entries = [asset, program]
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, program.id], entries: entries
        ) == Set([asset.id, program.id]))
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            ["file:///untrusted"], entries: entries
        ) == nil)
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, "missing"], entries: entries
        ) == nil)
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, asset.id], entries: entries
        ) == nil)
        let payload = try #require(SharedLibraryBrowserLogic.canvasTransfer(for: asset))
        #expect(try WorkflowCanvasTransfer.decode(payload.encoded())
            == .asset(projectID: projectID, assetID: assetID))
        #expect(SharedLibraryBrowserLogic.canvasTransfer(
            for: entry("unknown", title: "未知", readiness: .unknown)
        ) == nil)
    }

    @Test func externalTagDeletionAndUndoKeepMissingConditionsExplicit() throws {
        let store = try SharedLibraryStore()
        let keep = try #require(store.createTags(["保留"]).first)
        let removed = try #require(store.createTags(["撤销创建"]).first)
        let state = SharedLibraryBrowserState(query: .init(text: "未保存草稿", inputs: [.image],
            allTagIDs: [removed], anyTagIDs: [keep, removed]), selectedKeys: ["unchanged"])
        try store.undo(); state.reconcile(using: store)
        #expect(state.query.anyTagIDs == [keep, removed] && state.query.allTagIDs == [removed])
        #expect(state.query.text == "未保存草稿" && state.query.inputs == [.image])
        #expect(state.selectedKeys == ["unchanged"])
        try store.deleteTags([keep]); state.reconcile(using: store)
        #expect(state.query.anyTagIDs == [keep, removed])
        #expect(state.query.text == "未保存草稿")
    }

    @Test func exactToolTransferAndLegacyModelFactsRemainDistinctFromReadiness() throws {
        let reference = WorkflowToolReference(id: UUID(), version: 2, digest: String(repeating: "a", count: 64))
        let tool = entry("tool:test", title: "我的工具", kind: .tool, selection: .tool(reference))
        let payload = try #require(SharedLibraryBrowserLogic.canvasTransfer(for: tool))
        #expect(try WorkflowCanvasTransfer.decode(payload.encoded()) == .tool(reference))
        #expect(throws: (any Error).self) { try WorkflowCanvasTransfer.tool(.init(id: reference.id, version: 2, digest: "wrong")).encoded() }
        let projected = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
        let audio = try #require(projected.first { $0.id == "sm-music" })
        #expect(audio.item.outputs == [.audio])
        #expect(audio.item.inputs.contains(.audio))
        #expect(audio.item.readiness == .unsupported)
        #expect(!SharedLibraryBrowserLogic.allows(.use, entry: audio))
        let language = try #require(WorkflowRegistry.standard.operation("d.model.language")?.definition)
        #expect(!SharedLibraryProjection.outputs(language).contains(.video))
        #expect(SharedLibraryProjection.outputs(language).contains(.record))
    }

    @Test
    func actionPolicyHandlesEveryReadinessWithoutExecuting() {
        let modelSelection: SharedLibraryBrowserSelection = .operation(
            id: "d.image.generate", modelID: "model:exact"
        )
        for readiness in [SharedLibraryReadiness.available, .unprepared, .unknown] {
            let model = entry(
                "model:exact", title: "模型", kind: .model,
                readiness: readiness, selection: modelSelection
            )
            #expect(SharedLibraryBrowserLogic.allows(.use, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.add, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: model)
                == (readiness != .available))
            #expect(SharedLibraryBrowserLogic.canvasTransfer(for: model)
                == .operation(id: "d.image.generate", modelID: "model:exact"))
        }
        for readiness in [SharedLibraryReadiness.unavailable, .unsupported] {
            let model = entry(
                "model:exact", title: "模型", kind: .model,
                readiness: readiness, selection: modelSelection
            )
            #expect(!SharedLibraryBrowserLogic.allows(.use, entry: model))
            #expect(!SharedLibraryBrowserLogic.allows(.add, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: model))
            #expect(SharedLibraryBrowserLogic.canvasTransfer(for: model) == nil)
        }
        let genericUnknown = entry(
            "model:generic", title: "泛用入口", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: nil)
        )
        #expect(!SharedLibraryBrowserLogic.quickUseAllowed(genericUnknown))
        let incompatible = entry(
            "model:incompatible", title: "不兼容", kind: .model, readiness: .available,
            compatible: false, selection: modelSelection
        )
        #expect(!SharedLibraryBrowserLogic.allows(.use, entry: incompatible))
        #expect(!SharedLibraryBrowserLogic.allows(.add, entry: incompatible))
        #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: incompatible))
        #expect(SharedLibraryBrowserLogic.canvasTransfer(for: incompatible) == nil)

        let projectID = UUID(), assetID = UUID()
        for readiness in SharedLibraryReadiness.allCases {
            let asset = entry(
                "asset:test", title: "素材", kind: .asset, readiness: readiness,
                selection: .asset(projectID: projectID, assetID: assetID)
            )
            let expected = readiness == .available || readiness == .unknown
            #expect(SharedLibraryBrowserLogic.allows(.preview, entry: asset) == expected)
            #expect(SharedLibraryBrowserLogic.allows(.location, entry: asset))
            #expect(SharedLibraryBrowserLogic.currentEntry(key: asset.id, entries: [asset], action: .location) == asset)
            #expect(SharedLibraryBrowserLogic.allows(.add, entry: asset) == expected)
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: asset)
                == (readiness != .available))
            #expect((SharedLibraryBrowserLogic.canvasTransfer(for: asset) != nil) == expected)
        }
        let instanceAsset = entry("asset:instance", title: "恢复实例素材", kind: .asset,
            readiness: .unavailable,
            selection: .assetInstance(projectID: projectID, instanceID: UUID(), assetID: assetID))
        #expect(SharedLibraryBrowserLogic.allows(.location, entry: instanceAsset))
        #expect(!SharedLibraryBrowserLogic.allows(.preview, entry: instanceAsset))
        #expect(SharedLibraryBrowserLogic.currentEntry(key: instanceAsset.id, entries: [], action: .location) == nil)
    }

    @Test
    func compactDetailAndCallbacksResolveCurrentEntryByKey() {
        let old = entry("model:same", title: "旧名称", kind: .model)
        let current = entry(
            "model:same", title: "现名称", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: "model:same")
        )
        #expect(SharedLibraryBrowserLogic.detailEntry(key: old.id, entries: [current]) == current)
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [current], action: .use
        ) == current)
        let unsupported = entry(
            "model:same", title: "不支持", kind: .model, readiness: .unsupported,
            selection: current.selection
        )
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [unsupported], action: .use
        ) == nil)
        #expect(SharedLibraryBrowserLogic.detailEntry(key: old.id, entries: []) == nil)
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [], action: .add
        ) == nil)
    }

    @Test
    func fullAndCompactHostingRetainCallerStateAndInvokeNoActions() throws {
        let store = try SharedLibraryStore()
        let item = entry("operation:one", title: "一个程序")
        let second = entry("operation:two", title: "另一个程序")
        let query = SharedLibraryQuery(text: "一个")
        let fullState = SharedLibraryBrowserState(
            query: query, scope: .all, selectedKeys: [item.id], focusedKey: item.id
        )
        let compactState = SharedLibraryBrowserState(
            query: query, scope: .all, selectedKeys: [item.id], focusedKey: item.id
        )
        var useCount = 0, addCount = 0, previewCount = 0, prepareCount = 0
        var importCount = 0, closeCount = 0
        for compact in [false, true] {
            let state = compact ? compactState : fullState
            let browser = SharedLibraryBrowser(
                entries: [item, second], store: store, compact: compact, state: state,
                onUse: { _ in useCount += 1 },
                onAdd: { _ in addCount += 1 },
                onPreview: { _ in previewCount += 1 },
                onPrepare: { _ in prepareCount += 1 },
                onImport: { importCount += 1 },
                onClose: { closeCount += 1 }
            )
            let host = NSHostingView(rootView: browser)
            host.frame = CGRect(x: 0, y: 0, width: compact ? 240 : 850, height: 550)
            host.layoutSubtreeIfNeeded()
            #expect(state.query == query)
            #expect(state.selectedKeys == [item.id])
            #expect(state.focusedKey == item.id)
            #expect(state.scope == .all)
            state.selectedKeys = [second.id]
            state.focusedKey = second.id
            let reopened = SharedLibraryBrowser(
                entries: [item, second], store: store, compact: compact, state: state,
                onUse: { _ in useCount += 1 },
                onAdd: { _ in addCount += 1 },
                onPreview: { _ in previewCount += 1 },
                onPrepare: { _ in prepareCount += 1 },
                onImport: { importCount += 1 },
                onClose: { closeCount += 1 }
            )
            host.rootView = reopened
            host.layoutSubtreeIfNeeded()
            #expect(state.query == query)
            #expect(state.selectedKeys == [second.id])
            #expect(state.focusedKey == second.id)
        }
        #expect(useCount == 0 && addCount == 0 && previewCount == 0)
        #expect(prepareCount == 0 && importCount == 0 && closeCount == 0)
    }
}

// Drives the real DisclosureGroupStyle with the production tree's exact labels
// and IDs. This hidden layout fixture does not claim visible AX button delivery.
@MainActor @Observable private final class OperationDisclosureFixtureState {
    var expanded = Set<String>()
}
private struct OperationDisclosureFixture: View {
    let nodes: [WorkflowOperationTree]
    let state: OperationDisclosureFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(nodes) { node in
                if node.entry != nil {
                    Text(node.title).frame(maxWidth: .infinity, alignment: .leading)
                        .background(OperationDisclosureProbe(id: node.id))
                } else {
                    DisclosureGroup(isExpanded: Binding(get: { state.expanded.contains(node.id) }, set: {
                        if $0 { state.expanded.insert(node.id) } else { state.expanded.remove(node.id) }
                    })) {
                        OperationDisclosureFixture(nodes: node.children ?? [], state: state)
                    } label: {
                        Text(node.title).background(OperationDisclosureProbe(id: node.id))
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct OperationDisclosureProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = .init(id); return view }
    func updateNSView(_ view: NSView, context: Context) {}
}

extension SharedLibraryBrowserTests {
    @Test func containerNamesUseExactAnnotationAndProducerUsesFrozenBinding() throws {
        let registry = WorkflowRegistry.standard
        var producer = try #require(registry.operation("d.value.input")).definition.makeNode()
        producer.title = "Actual producer"; producer.dataConfiguration = .init(value: .text("unchanged"))
        let gate = try #require(registry.operation(WorkflowAssetContainer.filterID)).definition.makeNode()
        let graph = WorkflowGraph(nodes: [producer, gate], connections: [.init(sourceNode: producer.id, targetNode: gate.id)])
        let plan = try WorkflowPlanCompiler().compile(graph, target: gate.id)
        let owner = WorkflowAssetLibraryOwner(projectID: UUID(), instanceID: UUID()), runID = UUID()
        let value = WorkflowValue.data(.text("unchanged"))
        var produced = WorkflowStepRun(node: producer, signature: "producer", inputs: [:], status: .completed); produced.outputs = ["output": value]
        let step = WorkflowStepRun(node: gate, signature: "gate", inputs: ["input": value], status: .waiting)
        let record = WorkflowPlanCallRecord(address: .init(runID: runID, path: [.node(gate.id)]), step: step)
        var run = WorkflowRun(id: runID, graph: graph, targetNodeID: gate.id, steps: [produced, step], status: .waiting)
        run.planCheckpoint = .init(runID: runID, plan: plan, records: [.init(address: .init(runID: runID, path: [.node(producer.id)]), step: produced), record], state: .waiting)
        let source = try WorkflowRuntimeAssetSource.capture(record, port: "preview")
        var item = ContainerItem(id: "one", itemID: "value", value: value, record: record, source: .runtime(source), failure: nil, ordinal: 1)
        item.captureAnnotationKey(owner: owner)
        let key = try #require(item.runtimeAnnotationKey)
        var metadata = SharedLibraryMetadata(); metadata.runtimeAnnotations[key] = .init(name: "My exact name")
        #expect(item.displayName(assets: [], metadata: metadata, fallback: "fallback") == "My exact name")
        #expect(item.exactProducer(in: [run]) == producer)
        metadata.runtimeAnnotations[key] = .init(name: "Changed name")
        #expect(item.displayName(assets: [], metadata: metadata, fallback: "fallback") == "Changed name")
        var other = item; other.captureAnnotationKey(owner: .init(projectID: owner.projectID, instanceID: UUID()))
        #expect(other.displayName(assets: [], metadata: metadata, fallback: "fallback") == "fallback")
        run.planCheckpoint?.records[0].step.outputs["output"] = .data(.text("different"))
        #expect(item.exactProducer(in: [run]) == nil)
        #expect(item.value == value && record.step == step)
    }
}


extension SharedLibraryBrowserTests {
    @Test func runtimeClassificationUsesExactAnnotationKeyAndValidatesBeforeMutation() throws {
        let value = WorkflowLibraryValue(projectID: UUID(), instanceID: UUID(),
            call: .init(address: .init(runID: UUID()), stepID: UUID()), port: "text",
            value: .data(.text("frozen content")), createdAt: Date())
        let identity = try #require(value.annotationIdentity)
        var entry = SharedLibraryBrowserEntry(item: .init(key: identity.storageKey, title: "output", kind: .asset), selection: .unavailable("runtime"))
        entry.runtimeValue = value
        let selected = SharedLibraryBrowserLogic.tagEditEntries([entry.id], in: [entry])
        let library = try SharedLibraryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json"))
        let folder = try library.createFolder(name: "Selected outputs", parentID: nil)
        var current = true
        let validations: [() throws -> Void] = [{ if !current { throw SharedLibraryError.staleAnnotation } }]
        let keys = try SharedLibraryBrowserLogic.validatedOrganizationKeys(selected, validations: validations)
        #expect(keys == [identity.storageKey])
        try library.addMembers(keys, to: folder)
        #expect(library.metadata.folders[folder]?.memberKeys == keys)
        try library.removeMembers(try SharedLibraryBrowserLogic.validatedOrganizationKeys(selected, validations: validations), from: folder)
        #expect(library.metadata.folders[folder]?.memberKeys.isEmpty == true)
        try library.undo(); #expect(library.metadata.folders[folder]?.memberKeys == keys)
        current = false
        #expect(throws: SharedLibraryError.staleAnnotation) {
            try library.removeMembers(try SharedLibraryBrowserLogic.validatedOrganizationKeys(selected, validations: validations), from: folder)
        }
        #expect(library.metadata.folders[folder]?.memberKeys == keys && entry.runtimeValue == value)
        var forged = SharedLibraryBrowserEntry(item: .init(key: "wrong output", title: "output", kind: .asset), selection: .unavailable("runtime"))
        forged.runtimeValue = value
        #expect(throws: SharedLibraryError.staleAnnotation) {
            try SharedLibraryBrowserLogic.validatedOrganizationKeys([forged], validations: [{}])
        }
    }
}

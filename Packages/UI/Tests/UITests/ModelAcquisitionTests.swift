import Foundation
import Testing
import DWorkbench
@testable import UI

@Suite @MainActor struct ModelAcquisitionTests {
    @Test func allFrozenDisclosuresHaveSeparatedFactsAndLocalizedSources() throws {
        let entries = try ModelCatalog.entries()
        let zh = UILanguageStore(preferredLanguages: ["zh-Hans"]), en = UILanguageStore(preferredLanguages: ["en"])
        for entry in entries {
            let memoryKey = "modelManagement.catalog." + entry.id + ".memory"
            #expect(en.text(memoryKey, fallback: "MISSING") != "MISSING")
            #expect(zh.text(memoryKey, fallback: "MISSING") != "MISSING")
            let disclosure = try #require(entry.acquisitionDisclosure)
            #expect(disclosure.version == 1 && disclosure.checkedAt == "2026-10-26")
            #expect(!disclosure.components.isEmpty)
            for key in [disclosure.summaryKey] + disclosure.components.map(\.summaryKey) {
                #expect(zh.text(key, fallback: "MISSING") != "MISSING")
                #expect(en.text(key, fallback: "MISSING") != "MISSING")
            }
            for source in disclosure.components.flatMap(\.sources) {
                #expect(source.url.scheme == "https")
                #expect(source.sha256 == nil || source.sha256?.count == 64)
            }
        }
        let q8 = try #require(entries.first { $0.id == ModelCatalog.flux2ID }?.acquisitionDisclosure)
        #expect(q8.commercialUse == .unverified && q8.access == .publicRepository)
        let pitch = try #require(entries.first { $0.id == ModelCatalog.pitchID }?.acquisitionDisclosure)
        #expect(pitch.commercialUse == .unverified && pitch.access == .publicRepository)
        let gated = try #require(entries.first { $0.id == "flux2-dev-bf16" }?.acquisitionDisclosure)
        #expect(gated.access == .sourceWebsiteApproval && gated.commercialUse == .separateCommercialLicense)
    }

    @Test func acquisitionAndCardPurposeUsesCanonicalOperationTranslation() throws {
        let entry = try #require(ModelCatalog.entries().first { $0.id == "qwen35-9b-q4" })
        let source = try #require(ModelAcquisitionInformation.descriptor(entry))
        let en = UILanguageStore(preferredLanguages: ["en"])
        let zh = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let localized = ModelNodeUILocalization.display(source, language: en)
        #expect(localized.summary == en.text("workflow.operation.d.model.qwen35-9b.detail", fallback: "MISSING"))
        #expect(localized.summary != source.summary)
        #expect(ModelNodeUILocalization.display(source, language: zh).summary == source.summary)
        #expect(localized.id == source.id && localized.modelIdentity == source.modelIdentity && localized.revision == source.revision)
        #expect(ModelAcquisitionInformation.descriptor(entry) == source)
    }

    @Test func exactModelFunctionsDoNotCrossFamiliesOrDuplicateMetadata() throws {
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
        let legacy = try #require(entries.first { SharedModelLibraryCard.functions($0).contains { $0.id == "d.text.rewrite" } })
        let modern = try #require(entries.first { if case .operation(WorkflowModelRoutes.qwen35, _) = $0.selection { true } else { false } })
        #expect(SharedModelLibraryCard.functions(legacy).count == 2)
        #expect(!SharedModelLibraryCard.functions(modern).contains { $0.id == "d.text.rewrite" })
        let rewrite = try #require(SharedModelLibraryCard.resolve(legacy, function: "d.text.rewrite", current: entries))
        #expect(rewrite.id == legacy.id && rewrite.item.key == legacy.item.key && rewrite.item == legacy.item)
        #expect(SharedLibraryBrowserLogic.canvasTransfer(for: rewrite) != SharedLibraryBrowserLogic.canvasTransfer(for: legacy))
        #expect(SharedModelLibraryCard.resolve(modern, function: "d.text.rewrite", current: entries) == nil)
        #expect(SharedModelLibraryCard.resolve(legacy, function: "d.text.rewrite", current: [modern]) == nil)
        let store = try SharedLibraryStore(), enriched = SharedModelLibraryCard.searchEntry(legacy, language: nil)
        let title = try #require(SharedModelLibraryCard.functions(legacy).first { $0.id == "d.text.rewrite" })
        var query = SharedLibraryQuery(); query.text = WorkflowCanvasPresentation.operationTitle(title, language: nil)
        let found = try SharedLibraryBrowserLogic.visibleEntries([enriched], store: store, query: query, scope: .all)
        #expect(found.map(\.id) == [legacy.id])
        let unavailable = entries.filter { if case .unavailable = $0.selection { true } else { false } }
        #expect(unavailable.allSatisfy { SharedModelLibraryCard.functions($0).isEmpty })
    }
    @Test func modelNavigationAndGroupingHaveBoundedOwnership() throws {
        let state = SharedLibraryBrowserState()
        state.operationPath = ["models/mode:text", "models/mode:text/family:Qwen2.5"]
        state.migrateModelPath()
        #expect(state.modelModality == .text && state.navigationScrolls[state.modelScrollKey] != nil)
        let key = state.modelScrollKey
        state.modelModality = .image
        #expect(state.modelScrollKey != key)
        state.migrateModelPath(); #expect(state.modelModality == .image)
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil).filter { $0.item.kind == .model }
        let cache = state.modelGroupsCache, first = cache.tree(entries, language: nil)
        #expect(first.contains { $0.id.hasSuffix("/mode:text") } && first.contains { $0.id.hasSuffix("/mode:image") })
        _ = cache.tree(entries, language: nil); #expect(cache.builds == 1)
        _ = cache.tree(Array(entries.dropFirst()), language: nil); #expect(cache.builds == 2)
    }

}

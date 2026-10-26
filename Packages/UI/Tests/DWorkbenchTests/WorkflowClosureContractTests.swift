import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite struct WorkflowClosureContractTests {
    @Test func seedDomainsAndDynamicAddressesRetainFullUInt64() throws {
        let registry = WorkflowRegistry.standard
        for definition in registry.definitions where definition.modelKind != nil && definition.fields.contains(where: { $0.id == "seed" }) {
            let node = definition.makeNode()
            let maximum = try #require(WorkflowBatchSeedSchedule.maximumSeed(for: node, registry: registry))
            if ["d.video.generate", "d.music.generate", WorkflowModelRoutes.ace].contains(node.operationID) || node.operationID.contains("ltx-") { #expect(maximum == UInt64(UInt32.max)) }
            else { #expect(maximum == UInt64.max) }
            let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [.init(node: node, inputs: [])])
            let schedules = try WorkflowBatchSeedSchedule.allocate(plan: plan, strategy: .automatic, count: 2, registry: registry, nextSeed: { UInt64.max })
            #expect(schedules.allSatisfy { UInt64($0!.assignments[0].value)! <= maximum })
            #expect(schedules[0]!.assignments[0].value != schedules[1]!.assignments[0].value)
        }
        var node = try #require(registry.operation("d.image.generate")).definition.makeNode()
        node.parameters["seed"] = .text("007")
        let outer = UUID(), loop = UUID(), run = UUID()
        let old: [WorkflowAddressComponent] = [.node(outer), .item("first"), .node(loop), .iteration(0), .node(node.id)]
        let fresh: [WorkflowAddressComponent] = [.node(outer), .item("second"), .node(loop), .iteration(1), .node(node.id)]
        let schedule = WorkflowBatchSeedSchedule(strategy: .automatic,
            assignments: [.init(path: [.node(outer), .node(loop), .node(node.id)], value: String(UInt64.max))],
            inherited: [.init(path: old, value: "007")])
        let lookup = WorkflowBatchSeedLookup(schedule)
        #expect(lookup.applying(to: node, at: .init(runID: run, path: old)).parameters["seed"] == .text("007"))
        #expect(lookup.applying(to: node, at: .init(runID: run, path: fresh)).parameters["seed"] == .text(String(UInt64.max)))
        #expect(node.parameters["seed"] == .text("007"))
    }
    @Test func emptyFixedSeedIsAssignedOnceAndSaved() throws {
        let node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)).definition.makeNode()
        let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [.init(node: node, inputs: [])])
        var randomCalls = 0
        let schedules = try WorkflowBatchSeedSchedule.allocate(plan: plan, strategy: .fixed, count: 2, registry: .standard, nextSeed: { randomCalls += 1; return UInt64.max })
        #expect(randomCalls == 1)
        #expect(schedules.allSatisfy { $0?.assignments.first?.value == String(UInt64.max) })
        let cp = WorkflowPlanCheckpoint(runID: UUID(), plan: plan)
        var assigned = cp; assigned.batchSeeds = schedules[0]
        try assigned.batchSeeds?.validate(in: assigned, registry: .standard)
        #expect(try JSONDecoder().decode(WorkflowPlanCheckpoint.self, from: JSONEncoder().encode(assigned)) == assigned)
    }
    @Test func actualReceiverValidatesMusicWrappersAndTypedConversion() throws {
        let registry = WorkflowRegistry.standard
        let node = try #require(registry.operation("d.music.render")).definition.makeNode()
        let contract = try WorkflowInputContract(step: .init(node: node, inputs: []), portID: "input")
        let notes = WorkflowNoteSequence(clock: .seconds, notes: [], duration: 1, sources: [])
        #expect(contract.compatibility(with: .data(try notes.datum())).status == .direct)
        #expect(contract.compatibility(with: .data(.record(schema: [], fields: [:]))).status == .incompatible)
        let ref = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), version: UUID(), kind: .notes, sha256: String(repeating: "a", count: 64))
        #expect(contract.compatibility(with: .asset(ref)).status == .unverified)
        #expect(contract.compatibility(with: .data(.asset(ref))).status == .unverified)
        try contract.validate(.data(.asset(ref)))
        #expect(contract.compatibility(with: .asset(ref), decodedAsset: try notes.datum()).status == .direct)
        var typedAsset = try #require(registry.operation("d.value.return")).definition.makeNode()
        typedAsset.dataConfiguration = .init(fields: [.init("input", .asset(.notes))])
        let receiver = try WorkflowInputContract(step: .init(node: typedAsset, inputs: []), portID: "input")
        #expect(receiver.compatibility(with: .asset(ref), decodedAsset: try notes.datum()).status == .direct)
        var target = try #require(registry.operation("d.value.return")).definition.makeNode()
        let schema = WorkflowDataSchema.record([.init("count", .number(unit: nil))])
        target.dataConfiguration = .init(fields: [.init("input", schema)])
        let typed = try WorkflowInputContract(step: .init(node: target, inputs: []), portID: "input")
        #expect(typed.compatibility(with: .data(.text("{\"count\":2}"))).status == .conversion)
        #expect(typed.compatibility(with: .data(.text("{\"other\":2}"))).status == .incompatible)
    }
    @Test func specializedValidatorsFollowOperationAndPortIDsNotDisplayNames() throws {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4)
        let chords = WorkflowChordTrack(chords: [], duration: 1, tempo: tempo, sources: [])
        let notes = WorkflowNoteSequence(clock: .seconds, notes: [], duration: 1, sources: [])
        let cases: [(String, String, WorkflowDatum)] = [
            ("d.music.render", "input", try notes.datum()),
            ("d.music.chords", "input", try chords.datum()),
            ("d.music.align", "tempo", try tempo.datum())]
        for (operation, port, valid) in cases {
            var node = try #require(WorkflowRegistry.standard.operation(operation)).definition.makeNode()
            node.title = "Custom name / 用户自定义同名文字"
            let contract = try WorkflowInputContract(step: .init(node: node, inputs: []), portID: port)
            #expect(contract.compatibility(with: .data(valid)).status == .direct)
            #expect(contract.compatibility(with: .data(.record(schema: [], fields: [:]))).status == .incompatible)
            node.operationID = "custom.unknown"; node.title = "音符序列"
            #expect(throws: WorkflowIssue.self) { try WorkflowInputContract(step: .init(node: node, inputs: []), portID: port) }
        }
    }
    @Test @MainActor func contentFiltersDoNotConfuseAssetsWithOperationOutputs() throws {
        let store = try SharedLibraryStore()
        let asset = SharedLibraryItem(key: "asset:test", title: "图像素材", kind: .asset, contentKind: .image,
            facts: .init(producers: ["producer.actual"], formats: ["image/png"]))
        let operation = SharedLibraryItem(key: "operation:test", title: "生成图像", kind: .program, outputs: [.image])
        #expect(store.matches(asset, query: .init(contentKinds: [.image])) == true)
        #expect(store.matches(asset, query: .init(outputs: [.image])) == false)
        #expect(store.matches(operation, query: .init(outputs: [.image])) == true)
        #expect(store.matches(operation, query: .init(contentKinds: [.image])) == false)
        #expect(store.matches(asset, query: .init(facts: .init(formats: ["image/png"]))) == true)
        let unknown = SharedLibraryQuery(facts: .init(producers: ["unknown"]))
        #expect(unknown.facts?.producers == ["unknown"])
        #expect(unknown.facts?.matches(asset.facts) == false)
        let unknownMatches = store.matches(asset, query: unknown)
        #expect(unknownMatches == false)
        let query = SharedLibraryQuery(outputs: [.image], facts: .init(formats: ["image/png"]))
        #expect(try JSONDecoder().decode(SharedLibraryQuery.self, from: JSONEncoder().encode(query)) == query)
        #expect(store.matches(asset, query: query) == false) // Never drop an old incompatible condition.
    }
    @Test @MainActor func factConditionsShareMetadataRelationBudget() throws {
        let store = try SharedLibraryStore()
        let values = Set((0..<256).map { "format-\($0)" })
        for index in 0..<38 { _ = try store.createSavedQuery(name: "query-\(index)", query: .init(facts: .init(formats: values))) }
        let before = store.metadata
        #expect(throws: SharedLibraryError.self) { _ = try store.createSavedQuery(name: "over-budget", query: .init(facts: .init(formats: values))) }
        #expect(store.metadata == before)
    }

}

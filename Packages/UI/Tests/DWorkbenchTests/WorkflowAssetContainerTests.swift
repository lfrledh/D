import Foundation
import Testing
@testable import DWorkbench

struct WorkflowAssetContainerTests {
    @Test @MainActor func previewPassesCompleteValuesWithoutReviewOrPublication() async throws {
        let operation = try #require(WorkflowRegistry.standard.operation(WorkflowAssetContainer.previewID))
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image, sha256: String(repeating: "b", count: 64))
        let candidate = WorkflowCandidate(asset: reference, seed: "18446744073709551615")
        let failed = WorkflowCandidate(error: "controlled failure", seed: "7")
        let values: [WorkflowValue] = [
            .data(.text(String(repeating: "完整内容 👩🏽‍🎨\n", count: 4_096))),
            .data(.list(element: .text, items: [.init(id: "z", value: .text("second")), .init(id: "a", value: .text("first"))])),
            .collection([candidate, failed])
        ]
        #expect(operation.definition.interaction == .none)
        for value in values {
            var node = operation.definition.makeNode()
            node.parameters["kind"] = .text(value.kind.rawValue)
            let services = PreviewOnlyServices()
            let result = try await operation.execute(.init(node: node, stepID: UUID(), inputs: ["input": value]), services)
            // No renderer, Viewer or selection exists in this execution path.
            // Full equality includes member order, failed candidates and seeds.
            #expect(result == .outputs(["output": value]))
            #expect(services.verified == (value.kind == .images ? [reference] : []))
            #expect(services.unexpectedCalls == 0)
        }
    }
    @Test func listSubsetKeepsTypeOrderAndMemberIDs() throws {
        let input = WorkflowValue.data(.list(element: .text, items: [.init(id: "b", value: .text("second")), .init(id: "a", value: .text("first"))]))
        let selected = try WorkflowAssetContainer.selecting(["a"], from: input)
        #expect(selected == .data(.list(element: .text, items: [.init(id: "a", value: .text("first"))])))
        #expect(try WorkflowAssetContainer.selecting(["a", "b"], from: input) == input)
        #expect(throws: (any Error).self) { try WorkflowAssetContainer.selecting([], from: input) }
        #expect(throws: (any Error).self) { try WorkflowAssetContainer.selecting(["unknown"], from: input) }
    }
    @Test func imageSubsetRetainsCandidateAttemptSeedAndFailuresInInput() throws {
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        let good = WorkflowCandidate(asset: reference, seed: "18446744073709551615")
        let failed = WorkflowCandidate(error: "controlled failure", seed: "2")
        let input = WorkflowValue.collection([good, failed])
        #expect(try WorkflowAssetContainer.selecting([good.id.uuidString], from: input) == .collection([good]))
        #expect(input.candidates == [good, failed])
        #expect(throws: (any Error).self) { try WorkflowAssetContainer.selecting([failed.id.uuidString], from: input) }
    }
    @Test func selectionCannotSubstituteContentOrReorderItsDecision() throws {
        let node = try #require(WorkflowRegistry.standard.operation(WorkflowAssetContainer.filterID)).definition.makeNode()
        let value = WorkflowValue.data(.list(element: .text, items: [.init(id: "one", value: .text("one")), .init(id: "two", value: .text("two"))]))
        let step = WorkflowStepRun(node: node, signature: "test", inputs: ["input": value], status: .waiting)
        let wrongOrder = WorkflowDecision(waitingStepID: step.id, accepted: true, selectedItemIDs: ["two", "one"], typedOutput: value)
        #expect(throws: (any Error).self) { try WorkflowAssetContainer.validateDecision(wrongOrder, step: step) }
        let fabricated = WorkflowDecision(waitingStepID: step.id, accepted: true, selectedItemIDs: ["one"], typedOutput: .data(.text("one")))
        #expect(throws: (any Error).self) { try WorkflowAssetContainer.validateDecision(fabricated, step: step) }
    }
    @Test func legacyDecisionsDecodeWithoutContainerFields() throws {
        let old = WorkflowDecision(waitingStepID: UUID(), accepted: false)
        let bytes = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(WorkflowDecision.self, from: bytes)
        #expect(decoded == old && decoded.typedOutput == nil && decoded.selectedItemIDs == nil)
        let registry = WorkflowRegistry.standard
        #expect(registry.operation("d.asset.choose")?.definition.outputs.first?.kinds == [.image])
        #expect(registry.operation("d.text.confirm")?.definition.interaction == .textReview)
        #expect(registry.operation("d.control.human") != nil && registry.operation("d.control.map") != nil)
    }
    @Test func mixedSourceHasNoInventedOutputAndTypedFilterDoesNotDowncast() throws {
        let registry = WorkflowRegistry.standard
        var group = try #require(registry.operation(WorkflowAssetContainer.sourceID)).definition.makeNode()
        group.dataConfiguration = .init(items: [.init(id: "a", value: .text("text")), .init(id: "b", value: .boolean(true))])
        #expect(registry.definition(for: group)?.outputs.isEmpty == true)
        var filter = try #require(registry.operation(WorkflowAssetContainer.filterID)).definition.makeNode()
        filter.parameters["kind"] = .text("images")
        #expect(registry.definition(for: filter)?.inputs.first?.kinds == [.images])
        #expect(registry.definition(for: filter)?.outputs.first?.kinds == [.images])
    }
}

@MainActor private final class PreviewOnlyServices: WorkflowOperationServices {
    var verified: [WorkflowAssetReference] = []
    var unexpectedCalls = 0
    private func unexpected<T>() throws -> T {
        unexpectedCalls += 1
        throw WorkflowIssue("Preview must not publish, infer or export.")
    }
    func verifyAsset(_ reference: WorkflowAssetReference) async throws { verified.append(reference) }
    func readText(_ reference: WorkflowAssetReference) async throws -> String { try unexpected() }
    func publishText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { try unexpected() }
    func rewriteText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { try unexpected() }
    func generateImages(prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext) async throws -> [WorkflowCandidate] { try unexpected() }
    func transformImage(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { try unexpected() }
    func export(_ value: WorkflowValue, context: WorkflowExecutionContext) async throws -> WorkflowExportReceipt { try unexpected() }
}

extension WorkflowAssetContainerTests {
    @Test func listMembersKeepDistinctAnnotationIdentityAndRejectForgedWholeFlag() throws {
        var node = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        let list = WorkflowValue.data(.list(element: .text, items: [.init(id: "a", value: .text("same")), .init(id: "b", value: .text("same"))]))
        node.dataConfiguration = .init(value: list.datum)
        let graph = WorkflowGraph(nodes: [node]), runID = UUID()
        var step = WorkflowStepRun(node: node, signature: "test", inputs: [:], status: .completed)
        step.outputs = ["output": list]
        let record = WorkflowPlanCallRecord(address: .init(runID: runID, path: [.node(node.id)]), step: step)
        let plan = try WorkflowPlanCompiler().compile(graph, target: node.id)
        var run = WorkflowRun(id: runID, graph: graph, targetNodeID: node.id, steps: [step], status: .completed)
        run.planCheckpoint = .init(runID: runID, plan: plan, records: [record], state: .completed)
        let a = try WorkflowRuntimeAssetSource.capture(record, port: "output", itemID: "a")
        let b = try WorkflowRuntimeAssetSource.capture(record, port: "output", itemID: "b")
        let owner = WorkflowAssetLibraryOwner(projectID: UUID(), instanceID: UUID())
        #expect(try a.resolve(in: [run]) == b.resolve(in: [run]))
        #expect(try a.annotationIdentity(owner: owner, value: a.resolve(in: [run])).storageKey != b.annotationIdentity(owner: owner, value: b.resolve(in: [run])).storageKey)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        object["wholeValue"] = true
        let forged = try JSONDecoder().decode(WorkflowRuntimeAssetSource.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try forged.resolve(in: [run]) }
        let scalar = WorkflowValue.data(.text("same"))
        let ordinary = try WorkflowRuntimeAssetSource(call: a.call, port: "output", value: scalar)
        #expect(try WorkflowRuntimeAssetSource(call: a.call, port: "output", value: scalar, itemID: "value") == ordinary)
        #expect(try ordinary.annotationIdentity(owner: owner, value: scalar).storageKey == WorkflowValueIdentity(projectID: owner.projectID, instanceID: owner.instanceID, call: a.call, port: "output", value: scalar).storageKey)
        #expect(try WorkflowRuntimeAssetSource.projectedItems(call: a.call, port: "output", value: list).map(\.source) == [a, b])
    }
}

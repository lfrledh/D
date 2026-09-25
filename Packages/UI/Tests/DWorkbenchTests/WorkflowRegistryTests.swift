import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow registry r1") @MainActor
struct WorkflowRegistryTests {
    @Test func dagBranchMergePlansDeterministicallyAndDraftMayOmitRequiredInput() throws {
        let source = operation(id: "fixture.source", inputs: [], outputs: [port("output")])
        let merge = operation(
            id: "fixture.merge",
            inputs: [port("left"), port("right")],
            outputs: [port("output")]
        )
        let sink = operation(id: "fixture.sink", inputs: [port("input")], outputs: [port("output")])
        let registry = try WorkflowRegistry(operations: [source, merge, sink])
        let first = source.definition.makeNode(), second = source.definition.makeNode()
        let joined = merge.definition.makeNode(), target = sink.definition.makeNode()
        let unrelated = sink.definition.makeNode()
        let graph = WorkflowGraph(nodes: [target, second, unrelated, joined, first], connections: [
            .init(sourceNode: first.id, targetNode: joined.id, targetPort: "left"),
            .init(sourceNode: second.id, targetNode: joined.id, targetPort: "right"),
            .init(sourceNode: joined.id, targetNode: target.id),
        ])

        try registry.validate(graph)
        let plan = try registry.plan(graph, target: target.id, only: false)
        #expect(plan == (try registry.plan(graph, target: target.id, only: false)))
        #expect(plan.count == 4)
        #expect(Set(plan.prefix(2)) == Set([first.id, second.id]))
        #expect(Array(plan.suffix(2)) == [joined.id, target.id])
        #expect(try registry.plan(graph, target: target.id, only: true) == [target.id])

        let incompleteDraft = WorkflowGraph(nodes: [unrelated])
        try registry.validate(incompleteDraft)
    }

    @Test func cyclesAndMultipleSourcesAreRejected() throws {
        let pass = operation(
            id: "fixture.pass", inputs: [port("input", required: false)], outputs: [port("output")]
        )
        let registry = try WorkflowRegistry(operations: [pass])
        let a = pass.definition.makeNode(), b = pass.definition.makeNode(), c = pass.definition.makeNode()
        let cycle = WorkflowGraph(nodes: [a, b], connections: [
            .init(sourceNode: a.id, targetNode: b.id),
            .init(sourceNode: b.id, targetNode: a.id),
        ])
        #expect(throws: WorkflowIssue.self) { try registry.validate(cycle) }

        let doubleSource = WorkflowGraph(nodes: [a, b, c], connections: [
            .init(sourceNode: a.id, targetNode: c.id),
            .init(sourceNode: b.id, targetNode: c.id),
        ])
        #expect(throws: WorkflowIssue.self) { try registry.validate(doubleSource) }
    }

    @Test func connectedOptionalInputCannotFallBackWhenNotReady() throws {
        let registry = WorkflowRegistry.standard
        let rewrite = try node("d.text.rewrite", in: registry)
        #expect(throws: WorkflowIssue.self) {
            try registry.validateInputs([:], node: rewrite, connectedPorts: ["input"])
        }
        try registry.validateInputs([:], node: rewrite, connectedPorts: [])
    }

    @Test func collectionsNeverCoerceToSingleValuesAndDynamicAssetKindIsChecked() throws {
        let registry = WorkflowRegistry.standard
        let confirm = try node("d.text.confirm", in: registry)
        #expect(throws: WorkflowIssue.self) {
            try registry.validateInputs(
                ["input": .collection([.init(seed: "1")])], node: confirm, connectedPorts: ["input"]
            )
        }

        let reference = try node("d.asset.reference", in: registry)
        let resize = try node("d.image.resize", in: registry)
        let textAsset = asset(kind: .text)
        var boundReference = reference
        boundReference.assetReference = textAsset
        let graph = WorkflowGraph(nodes: [boundReference, resize], connections: [
            .init(sourceNode: boundReference.id, targetNode: resize.id),
        ])
        try registry.validate(graph)
        #expect(throws: WorkflowIssue.self) {
            try registry.validateInputs(
                ["input": .asset(textAsset)], node: resize, connectedPorts: ["input"]
            )
        }
    }

    @Test func missingTemplateVariablesAndScriptSyntaxDoNotPublish() async throws {
        let registry = WorkflowRegistry.standard
        let operation = try #require(registry.operation("d.text.template"))
        let services = RegistryServices()

        var missing = operation.definition.makeNode()
        missing.parameters["template"] = .text("Hello {{input}}")
        let missingContext = WorkflowExecutionContext(node: missing, stepID: UUID(), inputs: [:])
        await #expect(throws: WorkflowIssue.self) {
            try await operation.execute(missingContext, services)
        }

        var script = operation.definition.makeNode()
        script.parameters["template"] = .text("{{system('touch forbidden')}}")
        let scriptContext = WorkflowExecutionContext(node: script, stepID: UUID(), inputs: [:])
        await #expect(throws: WorkflowIssue.self) {
            try await operation.execute(scriptContext, services)
        }
        #expect(services.publishCount == 0)
    }

    @Test func signatureIgnoresPresentationButIncludesUpstreamConfiguration() throws {
        let registry = WorkflowRegistry.standard
        let original = WorkflowExamples.text()
        let target = try #require(original.nodes.last?.id)
        let baseline = try registry.signature(target, in: original)

        var presentation = original
        presentation.name = "Renamed graph"
        presentation.revision = UUID()
        presentation.nodes[0].title = "Renamed node"
        presentation.layout = presentation.layout.map {
            .init(nodeID: $0.nodeID, x: $0.x + 1_000, y: $0.y - 500, collapsed: !$0.collapsed)
        }
        #expect(try registry.signature(target, in: presentation) == baseline)

        var changed = original
        changed.nodes[0].parameters["text"] = .text("Changed upstream text")
        #expect(try registry.signature(target, in: changed) != baseline)
    }

    @Test func unknownOperationAndVersionFailWithoutFallback() throws {
        let registry = WorkflowRegistry.standard
        let unknown = WorkflowNode(operationID: "d.unknown", title: "Unknown")
        #expect(registry.operation(unknown.operationID) == nil)
        #expect(throws: WorkflowIssue.self) { try registry.validate(unknown) }

        var wrongVersion = try node("d.text.input", in: registry)
        wrongVersion.definitionVersion += 1
        #expect(throws: WorkflowIssue.self) { try registry.validate(wrongVersion) }
    }

    @Test func imageGenerationPreservesCountAndFullUInt64SeedAsACollection() async throws {
        let registry = WorkflowRegistry.standard
        let operation = try #require(registry.operation("d.image.generate"))
        var generation = operation.definition.makeNode()
        let maximumSeed = String(UInt64.max)
        generation.parameters["promptText"] = .text("fixture prompt")
        generation.parameters["seed"] = .text(maximumSeed)
        generation.parameters["count"] = .integer(8)
        generation.parameters["modelID"] = .text("registered-content-id")
        try registry.validate(generation)

        let services = RegistryServices()
        let context = WorkflowExecutionContext(node: generation, stepID: UUID(), inputs: [:])
        let result = try await operation.execute(context, services)
        guard case .outputs(let outputs) = result,
              case .collection(let candidates)? = outputs["output"] else {
            Issue.record("N05 must return the complete candidate collection")
            return
        }
        #expect(candidates.count == 8)
        #expect(candidates.allSatisfy { $0.seed == maximumSeed })
        #expect(services.generatedNode?.parameters["seed"] == .text(maximumSeed))
        #expect(services.generatedNode?.parameters["count"] == .integer(8))
    }

    @Test func duplicateRegistrationFailsAndExactImplementationIsSelected() async throws {
        let first = WorkflowOperation(
            definition: .init(id: "fixture.first", title: "First", detail: "", inputs: [], outputs: []),
            execute: { _, _ in .outputs([:]) }
        )
        let second = WorkflowOperation(
            definition: .init(id: "fixture.second", title: "Second", detail: "", inputs: [], outputs: []),
            execute: { _, _ in .choose([]) }
        )
        #expect(throws: WorkflowIssue.self) { try WorkflowRegistry(operations: [first, first]) }

        let registry = try WorkflowRegistry(operations: [first, second])
        let selected = try #require(registry.operation("fixture.second"))
        let context = WorkflowExecutionContext(node: selected.definition.makeNode(), stepID: UUID(), inputs: [:])
        let result = try await selected.execute(context, RegistryServices())
        guard case .choose = result else {
            Issue.record("Registry selected a different implementation")
            return
        }
        #expect(registry.operation("fixture.missing") == nil)
    }

    @Test func examplesUseOrdinaryDefinitionsAndExpectedShapes() throws {
        let registry = WorkflowRegistry.standard
        let text = WorkflowExamples.text(), image = WorkflowExamples.image()
        let file = WorkflowExamples.file(), template = WorkflowExamples.template()
        try registry.validate(text)
        try registry.validate(image)
        try registry.validate(file)
        try registry.validate(template)
        #expect(text.nodes.count == 3)
        #expect(image.nodes.count == 8)
        #expect(file.nodes.map(\.operationID) == [
            "d.asset.reference", "d.image.resize", "d.image.convert", "d.asset.export",
        ])
        #expect(template.connections.contains { $0.targetPort == "input" })
        #expect(template.connections.contains { $0.targetPort == "other" })
        #expect(registry.definitions.count == 10)
        #expect(!registry.definitions.contains { $0.id == "d.empty-lines" })
    }

    private func operation(
        id: String,
        inputs: [WorkflowPortDefinition],
        outputs: [WorkflowPortDefinition]
    ) -> WorkflowOperation {
        WorkflowOperation(
            definition: .init(id: id, title: id, detail: "fixture", inputs: inputs, outputs: outputs),
            execute: { _, _ in .outputs([:]) }
        )
    }

    private func port(_ id: String, required: Bool = true) -> WorkflowPortDefinition {
        .init(id, id, kinds: [.text], required: required)
    }

    private func node(_ id: String, in registry: WorkflowRegistry) throws -> WorkflowNode {
        try #require(registry.operation(id)?.definition.makeNode())
    }

    private func asset(kind: WorkflowDataKind) -> WorkflowAssetReference {
        .init(projectID: UUID(), assetID: UUID(), kind: kind, sha256: String(repeating: "a", count: 64))
    }
}

@MainActor private final class RegistryServices: WorkflowOperationServices {
    private(set) var publishCount = 0
    private(set) var generatedNode: WorkflowNode?

    func readText(_ reference: WorkflowAssetReference) async throws -> String { "fixture text" }
    func verifyAsset(_ reference: WorkflowAssetReference) async throws {}

    func publishText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        publishCount += 1
        return reference(kind: .text)
    }

    func rewriteText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { reference(kind: .text) }

    func generateImages(
        prompt: String,
        reference: WorkflowAssetReference?,
        context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] {
        generatedNode = context.node
        guard case .integer(let count)? = context.node.parameters["count"],
              case .text(let seed)? = context.node.parameters["seed"] else {
            throw WorkflowIssue("invalid generation fixture")
        }
        return (0 ..< count).map { _ in WorkflowCandidate(asset: self.reference(kind: .image), seed: seed) }
    }

    func transformImage(
        _ reference: WorkflowAssetReference,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { self.reference(kind: .image) }

    func export(_ value: WorkflowValue, context: WorkflowExecutionContext) async throws -> WorkflowExportReceipt {
        .init(id: UUID(), names: ["fixture"], hashes: [String(repeating: "b", count: 64)])
    }

    private func reference(kind: WorkflowDataKind) -> WorkflowAssetReference {
        .init(projectID: UUID(), assetID: UUID(), kind: kind, sha256: String(repeating: "a", count: 64))
    }
}

import Foundation
import Testing
@testable import DWorkbench

@Suite("Bounded JSON repair graph r1") @MainActor
struct WorkflowJSONRepairToolTests {
    private let fields: [WorkflowRecordField] = [.init("title", .text)]

    @Test func graphCompilesAndKeepsEveryLanguageCallBoundedAndEditable() throws {
        let tool = try makeTool()
        _ = try WorkflowPlanCompiler().compile(tool.graph)

        #expect(tool.graph.interface?.inputs == [.init("content", .text)])
        #expect(tool.graph.interface?.outputs.map(\.name) == ["output"])
        #expect(tool.graph.interface?.outputs.first?.schema == .record(fields))

        let nodes = nestedNodes(in: tool.graph)
        let languageNodes = nodes.filter { $0.operationID == "d.model.language" }
        #expect(languageNodes.count == 2)
        #expect(languageNodes.allSatisfy { $0.parameters["modelID"] == .text("") })
        #expect(languageNodes.allSatisfy { $0.parameters["temperature"] == .decimal(0) })
        #expect(languageNodes.allSatisfy { $0.parameters["maximumOutputTokens"] == .integer(768) })
        #expect(nodes.contains { $0.operationID == "d.control.loop" })
        #expect(nodes.contains { $0.operationID == "d.value.template" })
        #expect(nodes.filter { $0.operationID == "d.value.validate" }.allSatisfy {
            $0.dataConfiguration?.validationInputFormat == .jsonText
        })
    }

    @Test func makeRejectsUnsupportedSchemaBadExamplesAndRepairCounts() throws {
        do {
            _ = try WorkflowJSONRepairTool.make(
                schema: .asset(.image), task: "Describe", exampleJSON: #""asset""#
            )
            Issue.record("Expected unsupported schema rejection")
        } catch {}

        for badExample in [
            #"{"title":"one","title":"two"}"#,
            #"{"title":"one","extra":true}"#,
            #"{"title":42}"#,
        ] {
            do {
                _ = try WorkflowJSONRepairTool.make(
                    schema: .record(fields), task: "Describe", exampleJSON: badExample
                )
                Issue.record("Expected invalid example rejection: \(badExample)")
            } catch {}
        }

        for count in [0, 3] {
            do {
                _ = try makeTool(maximumRepairs: count)
                Issue.record("Expected repair-count rejection: \(count)")
            } catch {}
        }
    }

    @Test func initiallyValidJSONUsesExactlyOneModelCall() async throws {
        let services = JSONRepairTestServices(responses: [#"{"title":"first"}"#])
        let completed = try await execute(tool: makeTool(), content: "source one", services: services)

        #expect(completed.state == .completed)
        #expect(services.languageCalls.count == 1)
        #expect(services.languageCalls[0].content == "source one")
        #expect(outputTitle(completed) == "first")
        #expect(loopRecord(in: completed)?.loopExit == .conditionMet)
    }

    @Test func fencedJSONIsPreservedThenOneRepairSucceeds() async throws {
        let fenced = "```json\n{\"title\":\"wrong wrapper\"}\n```"
        let services = JSONRepairTestServices(responses: [fenced, #"{"title":"repaired"}"#])
        let completed = try await execute(tool: makeTool(), content: "original source", services: services)

        #expect(completed.state == .completed)
        #expect(services.languageCalls.count == 2)
        #expect(services.languageCalls.allSatisfy { $0.content == "original source" })
        #expect(services.languageCalls[1].task.contains(fenced))
        #expect(services.languageCalls[1].task.contains("Complete target schema"))
        #expect(services.languageCalls[1].task.contains(#"{"title":"shape"}"#))
        #expect(services.languageCalls[1].task.contains("First validation issue"))
        #expect(outputTitle(completed) == "repaired")
        #expect(languageTexts(in: completed) == [fenced, #"{"title":"repaired"}"#])
        #expect(loopRecord(in: completed)?.loopExit == .conditionMet)
    }

    @Test func persistentInvalidJSONStopsAfterThreeCallsWithoutSuccessOutput() async throws {
        let responses = ["not json one", "not json two", "not json three"]
        let services = JSONRepairTestServices(responses: responses)
        let tool = try makeTool()
        let executor = try makeExecutor(tool: tool, services: services)

        do {
            _ = try await executor.execute(try checkpoint(for: tool, content: "source"))
            Issue.record("Expected final strict validation failure")
        } catch {}

        let failed = try #require(executor.checkpoint)
        #expect(failed.state == .failed)
        #expect(services.languageCalls.count == 3)
        #expect(languageTexts(in: failed) == responses)
        #expect(loopRecord(in: failed)?.loopExit == .iterationLimit)
        #expect(failed.outputs.isEmpty)
        #expect(!failed.records.contains {
            $0.step.node.operationID == "d.value.return" &&
                $0.step.node.title == "Return validated structured data" &&
                $0.step.status == .completed
        })
    }

    @Test func structuredCounterexamplesExhaustRepairsAndPreserveEveryRawResponse() async throws {
        let counterexamples = [
            #"{"title":"one","title":"two"}"#,
            #"{"title":"one","extra":true}"#,
            #"{"title":42}"#,
        ]

        for invalid in counterexamples {
            let services = JSONRepairTestServices(responses: [invalid, invalid, invalid])
            let tool = try makeTool()
            let executor = try makeExecutor(tool: tool, services: services)
            var executionFailed = false

            do {
                _ = try await executor.execute(try checkpoint(for: tool, content: "counterexample source"))
            } catch {
                executionFailed = true
            }

            let failed = try #require(executor.checkpoint)
            let modelRecords = failed.records.filter {
                $0.step.node.operationID == "d.model.language" && $0.step.status == .completed
            }
            let rawReferences = modelRecords.compactMap { $0.step.outputs["raw"]?.asset }
            var preservedRaw: [String] = []
            for reference in rawReferences {
                preservedRaw.append(try await services.readText(reference))
            }

            #expect(executionFailed)
            #expect(failed.state == .failed)
            #expect(services.languageCalls.count == 3)
            #expect(modelRecords.count == 3)
            #expect(languageTexts(in: failed) == [invalid, invalid, invalid])
            #expect(rawReferences.count == 3)
            #expect(Set(rawReferences.map(\.assetID)).count == 3)
            #expect(preservedRaw == [invalid, invalid, invalid])
            #expect(loopRecord(in: failed)?.loopExit == .iterationLimit)
            #expect(loopRecord(in: failed)?.step.status == .completed)
            #expect(failed.records.contains {
                $0.step.node.operationID == "d.value.validate" &&
                    $0.step.node.title == "Strictly validate final JSON" &&
                    $0.step.status == .failed
            })
            #expect(failed.outputs.isEmpty)
            #expect(!failed.records.contains {
                $0.step.node.operationID == "d.value.return" &&
                    $0.step.node.title == "Return validated structured data" &&
                    $0.step.status == .completed
            })
        }
    }

    @Test func saveFailureRetainsInvalidTextAndResumeDoesNotRepeatCompletedCall() async throws {
        let invalid = "```json\n{\"title\":\"fenced\"}\n```"
        let services = JSONRepairTestServices(responses: [invalid, #"{"title":"fixed"}"#])
        let tool = try makeTool()
        var failedSave = false
        let executor = try makeExecutor(tool: tool, services: services, save: { checkpoint in
            if !failedSave, checkpoint.records.contains(where: {
                $0.step.node.operationID == "d.model.language" && $0.step.status == .completed
            }) {
                failedSave = true
                throw JSONRepairTestError.save
            }
        })

        do {
            _ = try await executor.execute(try checkpoint(for: tool, content: "resume source"))
            Issue.record("Expected controlled save failure")
        } catch JSONRepairTestError.save {}

        let saving = try #require(executor.checkpoint)
        #expect(saving.state == .saving)
        #expect(services.languageCalls.count == 1)
        #expect(languageTexts(in: saving) == [invalid])

        let completed = try await executor.execute(saving)
        #expect(completed.state == .completed)
        #expect(services.languageCalls.count == 2)
        #expect(languageTexts(in: completed) == [invalid, #"{"title":"fixed"}"#])
        #expect(outputTitle(completed) == "fixed")
    }

    @Test func cancellationKeepsGeneratedTextAndDoesNotStartParseRepair() async throws {
        let invalid = "cancelled invalid JSON"
        let services = JSONRepairTestServices(responses: [invalid])
        let tool = try makeTool()
        let registry = WorkflowRegistry.standard
        let plan = try WorkflowPlanCompiler(registry: registry).compile(tool.graph)
        var executor: WorkflowPlanExecutor!
        executor = WorkflowPlanExecutor(registry: registry, executeCall: { context in
            guard let operation = registry.operation(context.node.operationID) else {
                throw WorkflowIssue("Missing operation in JSON repair test.")
            }
            let result = try await operation.execute(context, services)
            if context.node.operationID == "d.model.language" { executor.requestStop() }
            return result
        }, save: { _ in })

        let stopped = try await executor.execute(.init(
            plan: plan,
            arguments: ["content": .text("cancel source")]
        ))
        #expect(stopped.state == .cancelled)
        #expect(services.languageCalls.count == 1)
        #expect(languageTexts(in: stopped) == [invalid])
        #expect(!stopped.records.contains { $0.step.node.operationID == "d.value.validate" })
        #expect(stopped.outputs.isEmpty)
    }

    @Test func differentInputsReachTheActualModelContextAndDoNotUseTheExampleAsAnswer() async throws {
        let services = JSONRepairTestServices { _, _, content in
            #"{"title":"\#(content ?? "missing")"}"#
        }
        let tool = try makeTool()
        let first = try await execute(tool: tool, content: "alpha", services: services)
        let second = try await execute(tool: tool, content: "beta", services: services)

        #expect(outputTitle(first) == "alpha")
        #expect(outputTitle(second) == "beta")
        #expect(services.languageCalls.map(\.content) == ["alpha", "beta"])
        #expect(services.languageCalls.allSatisfy { $0.task.contains(#"{"title":"shape"}"#) })
        #expect(!services.languageCalls.contains { $0.content == "shape" })
    }

    private func makeTool(maximumRepairs: Int = 2) throws -> WorkflowToolDefinition {
        try WorkflowJSONRepairTool.make(
            schema: .record(fields),
            task: "Extract a title from the supplied content.",
            exampleJSON: #"{"title":"shape"}"#,
            maximumRepairs: maximumRepairs
        )
    }

    private func execute(
        tool: WorkflowToolDefinition,
        content: String,
        services: JSONRepairTestServices
    ) async throws -> WorkflowPlanCheckpoint {
        let executor = try makeExecutor(tool: tool, services: services)
        return try await executor.execute(try checkpoint(for: tool, content: content))
    }

    private func makeExecutor(
        tool: WorkflowToolDefinition,
        services: JSONRepairTestServices,
        save: @escaping @MainActor (WorkflowPlanCheckpoint) async throws -> Void = { _ in }
    ) throws -> WorkflowPlanExecutor {
        let registry = WorkflowRegistry.standard
        _ = try WorkflowPlanCompiler(registry: registry).compile(tool.graph)
        return WorkflowPlanExecutor(registry: registry, executeCall: { context in
            guard let operation = registry.operation(context.node.operationID) else {
                throw WorkflowIssue("Missing operation in JSON repair test.")
            }
            return try await operation.execute(context, services)
        }, save: save)
    }

    private func checkpoint(
        for tool: WorkflowToolDefinition,
        content: String
    ) throws -> WorkflowPlanCheckpoint {
        let plan = try WorkflowPlanCompiler().compile(tool.graph)
        return .init(plan: plan, arguments: ["content": .text(content)])
    }

    private func outputTitle(_ checkpoint: WorkflowPlanCheckpoint) -> String? {
        guard case .data(.record(_, let values))? = checkpoint.outputs["output"],
              case .text(let title)? = values["title"] else { return nil }
        return title
    }

    private func languageTexts(in checkpoint: WorkflowPlanCheckpoint) -> [String] {
        checkpoint.records.compactMap { record in
            guard record.step.node.operationID == "d.model.language",
                  record.step.status == .completed,
                  case .data(.text(let text))? = record.step.outputs["output"] else { return nil }
            return text
        }
    }

    private func loopRecord(in checkpoint: WorkflowPlanCheckpoint) -> WorkflowPlanCallRecord? {
        checkpoint.records.first { $0.step.node.operationID == "d.control.loop" }
    }

    private func nestedNodes(in graph: WorkflowGraph) -> [WorkflowNode] {
        graph.nodes.flatMap { node -> [WorkflowNode] in
            var result = [node]
            switch node.control {
            case .branch(_, let yes, let no):
                result += nestedNodes(in: yes) + nestedNodes(in: no)
            case .map(let body, _), .loop(let body, _, _, _):
                result += nestedNodes(in: body)
            case .invoke, nil:
                break
            }
            return result
        }
    }
}

private enum JSONRepairTestError: Error { case save, unexpectedService }

@MainActor private final class JSONRepairTestServices: WorkflowOperationServices {
    struct LanguageCall {
        var task: String
        var content: String?
        var nodeID: UUID
    }

    private let response: (Int, String, String?) throws -> String
    private var textByAsset: [UUID: String] = [:]
    private(set) var languageCalls: [LanguageCall] = []

    init(responses: [String]) {
        response = { index, _, _ in
            guard responses.indices.contains(index) else { throw JSONRepairTestError.unexpectedService }
            return responses[index]
        }
    }

    init(response: @escaping (Int, String, String?) throws -> String) {
        self.response = response
    }

    func generateLanguage(
        task: String,
        content: String?,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        let index = languageCalls.count
        languageCalls.append(.init(task: task, content: content, nodeID: context.node.id))
        let text = try response(index, task, content)
        let reference = WorkflowAssetReference(
            projectID: UUID(),
            assetID: UUID(),
            kind: .text,
            sha256: String(repeating: "a", count: 64)
        )
        textByAsset[reference.assetID] = text
        return reference
    }

    func readText(_ reference: WorkflowAssetReference) async throws -> String {
        guard let text = textByAsset[reference.assetID] else { throw JSONRepairTestError.unexpectedService }
        return text
    }

    func verifyAsset(_ reference: WorkflowAssetReference) async throws {
        throw JSONRepairTestError.unexpectedService
    }

    func publishText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw JSONRepairTestError.unexpectedService
    }

    func rewriteText(
        _ text: String,
        parents: [WorkflowAssetReference],
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw JSONRepairTestError.unexpectedService
    }

    func generateImages(
        prompt: String,
        reference: WorkflowAssetReference?,
        context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] {
        throw JSONRepairTestError.unexpectedService
    }

    func transformImage(
        _ reference: WorkflowAssetReference,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference {
        throw JSONRepairTestError.unexpectedService
    }

    func export(
        _ value: WorkflowValue,
        context: WorkflowExecutionContext
    ) async throws -> WorkflowExportReceipt {
        throw JSONRepairTestError.unexpectedService
    }
}

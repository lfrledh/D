import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow data operations r1") @MainActor
struct WorkflowDataOperationsTests {
    @Test func definitionsAreVersionedAndInputExposesOnlyThePublicNameParameter() throws {
        #expect(WorkflowDataOperations.operations.map(\.definition.id) == [
            "d.value.input", "d.value.template", "d.value.record", "d.value.field", "d.value.list",
            "d.value.filter", "d.value.select", "d.value.pair", "d.value.validate", "d.value.return",
        ])
        #expect(WorkflowDataOperations.operations.allSatisfy { $0.definition.version == 1 })
        let input = try operation("d.value.input")
        #expect(input.definition.fields.map(\.id) == ["publicName"])
        #expect(input.definition.makeNode().parameters["publicName"] == .text(""))
    }

    @Test func inputAndReturnPreserveFrozenDataWithoutServices() async throws {
        let services = RejectingDataServices()
        let frozen = WorkflowDatum.text("固定 👩🏽‍🎨")
        let inputOutputs = try await execute(
            "d.value.input", configuration: .init(value: frozen), services: services
        )
        #expect(try datum("output", in: inputOutputs) == frozen)

        let returned = try await execute(
            "d.value.return", inputs: ["input": .data(frozen)], services: services
        )
        #expect(try datum("output", in: returned) == frozen)
        #expect(services.callCount == 0)

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute("d.value.input", services: services)
        }
    }

    @Test func templateHandlesUnicodeAndNeverReinterpretsInsertedMarkers() async throws {
        let services = RejectingDataServices()
        let schema: [WorkflowRecordField] = [
            .init("名字", .text), .init("count", .number(unit: nil)), .init("ready", .boolean),
            .init("kind", .enumeration(["草图", "完成"])), .init("payload", .text),
        ]
        let fields = WorkflowDatum.record(schema: schema, fields: [
            "名字": .text("小林"), "count": .number(2, unit: nil), "ready": .boolean(true),
            "kind": .enumeration("草图", choices: ["草图", "完成"]), "payload": .text("保留 {{名字}}"),
        ])
        let outputs = try await execute(
            "d.value.template",
            configuration: .init(value: fields),
            parameters: ["template": .text("你好 {{名字}} / {{count}} / {{ready}} / {{kind}} / {{payload}}")],
            services: services
        )
        #expect(try datum("output", in: outputs) == .text("你好 小林 / 2.0 / true / 草图 / 保留 {{名字}}"))
        #expect(services.callCount == 0)

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.template", configuration: .init(value: fields),
                parameters: ["template": .text("{{missing}}")], services: services
            )
        }
    }

    @Test func templateRejectsExpansionBeforeAllocatingBeyondTheTextBudget() async throws {
        let services = RejectingDataServices()
        let value = String(repeating: "x", count: 600 * 1_024)
        let schema: [WorkflowRecordField] = [.init("x", .text)]
        let fields = WorkflowDatum.record(schema: schema, fields: ["x": .text(value)])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.template",
                configuration: .init(value: fields),
                parameters: ["template": .text("{{x}}{{x}}{{x}}")],
                services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func recordUsesConnectedValuesBeforeFallbackAndFieldPreservesExplicitNone() async throws {
        let services = RejectingDataServices()
        let recordSchema: [WorkflowRecordField] = [
            .init("title", .text), .init("note", .optional(.text), required: false),
        ]
        let fallback = WorkflowDatum.record(schema: recordSchema, fields: ["title": .text("fallback")])
        let outputs = try await execute(
            "d.value.record",
            configuration: .init(value: fallback, fields: recordSchema),
            inputs: ["title": .data(.text("connected"))], services: services
        )
        let built = try datum("output", in: outputs)
        #expect(built.fields?["title"] == .text("connected"))
        #expect(built.fields?["note"] == nil)

        let empty = try await execute("d.value.record", services: services)
        #expect(try datum("output", in: empty) == .record(schema: [], fields: [:]))

        let optionalSchema: [WorkflowRecordField] = [.init("note", .optional(.text))]
        let explicitNone = WorkflowDatum.record(
            schema: optionalSchema, fields: ["note": .none(.text)]
        )
        let selected = try await execute(
            "d.value.field", configuration: .init(schema: .optional(.text), path: ["note"]),
            inputs: ["input": .data(explicitNone)], services: services
        )
        #expect(try datum("output", in: selected) == .none(.text))

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.field", configuration: .init(schema: .text, path: ["missing"]),
                inputs: ["input": .data(explicitNone)], services: services
            )
        }
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.record", configuration: .init(fields: [.init("n", .number(unit: "s"))]),
                inputs: ["n": .data(.number(1, unit: "frames"))], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func listItemsDoNotFlattenNestedListsAndConcatPreservesMemberIDs() async throws {
        let services = RejectingDataServices()
        let nestedElement: WorkflowDataSchema = .list(.text)
        let fixedNested = WorkflowDatum.list(element: .text, items: [])
        let connectedNested = WorkflowDatum.list(
            element: .text, items: [.init(id: "inner", value: .text("value"))]
        )
        let nestedOutputs = try await execute(
            "d.value.list",
            configuration: .init(
                schema: nestedElement,
                fields: [.init("connected", nestedElement)],
                items: [.init(id: "fixed", value: fixedNested)]
            ),
            inputs: ["connected": .data(connectedNested)], services: services
        )
        let nested = try datum("output", in: nestedOutputs)
        #expect(nested.items?.map(\.id) == ["fixed", "connected"])
        #expect(nested.items?.allSatisfy { $0.value.kind == .list } == true)

        let left = WorkflowDatum.list(element: .text, items: [.init(id: "left-1", value: .text("L"))])
        let right = WorkflowDatum.list(element: .text, items: [.init(id: "right-1", value: .text("R"))])
        let concat = try await execute(
            "d.value.list",
            configuration: .init(
                schema: .text,
                fields: [.init("left", .list(.text)), .init("right", .list(.text))]
            ),
            parameters: ["mode": .text("concat")],
            inputs: ["left": .data(left), "right": .data(right)], services: services
        )
        #expect(try datum("output", in: concat).items?.map(\.id) == ["left-1", "right-1"])

        let duplicate = WorkflowDatum.list(element: .text, items: [.init(id: "left-1", value: .text("R"))])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.list",
                configuration: .init(
                    schema: .text,
                    fields: [.init("left", .list(.text)), .init("right", .list(.text))]
                ),
                parameters: ["mode": .text("concat")],
                inputs: ["left": .data(left), "right": .data(duplicate)], services: services
            )
        }

        let empty = try await execute(
            "d.value.list", configuration: .init(schema: .text), services: services
        )
        #expect(try datum("output", in: empty) == .list(element: .text, items: []))

        let heterogeneous = WorkflowDatum.list(
            element: .text, items: [.init(id: "wrong", value: .number(1, unit: nil))]
        )
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.list",
                configuration: .init(schema: .text, fields: [.init("source", .list(.text))]),
                parameters: ["mode": .text("concat")],
                inputs: ["source": .data(heterogeneous)], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func filterIsStableChecksUnitsAndAllowsZeroLimit() async throws {
        let services = RejectingDataServices()
        let element: WorkflowDataSchema = .record([
            .init("score", .number(unit: "seconds")), .init("label", .text),
        ])
        func row(_ score: Double, _ label: String) -> WorkflowDatum {
            guard case .record(let fields) = element else { return .text("unreachable") }
            return .record(schema: fields, fields: [
                "score": .number(score, unit: "seconds"), "label": .text(label),
            ])
        }
        let input = WorkflowDatum.list(element: element, items: [
            .init(id: "a", value: row(2, "first")),
            .init(id: "b", value: row(2, "second")),
            .init(id: "c", value: row(1, "third")),
        ])
        let outputs = try await execute(
            "d.value.filter",
            configuration: .init(
                path: ["score"],
                rules: [.init(path: ["score"], comparison: .greaterOrEqual, value: .number(1, unit: "seconds"))]
            ),
            inputs: ["input": .data(input)], services: services
        )
        #expect(try datum("output", in: outputs).items?.map(\.id) == ["c", "a", "b"])

        let zero = try await execute(
            "d.value.filter", parameters: ["limit": .integer(0)],
            inputs: ["input": .data(input)], services: services
        )
        #expect(try datum("output", in: zero).items?.isEmpty == true)

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.filter",
                configuration: .init(rules: [
                    .init(path: ["score"], comparison: .equals, value: .number(2, unit: "frames")),
                ]),
                inputs: ["input": .data(input)], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func filterValidatesEveryRuleBeforeEmptyOrShortCircuitedEvaluation() async throws {
        let services = RejectingDataServices()
        let empty = WorkflowDatum.list(element: .number(unit: "seconds"), items: [])
        let invalidUnitRule = WorkflowDataRule(
            comparison: .greater, value: .number(0, unit: "frames")
        )
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.filter", configuration: .init(rules: [invalidUnitRule]),
                inputs: ["input": .data(empty)], services: services
            )
        }

        let oneSecond = WorkflowDatum.list(
            element: .number(unit: "seconds"),
            items: [.init(id: "one", value: .number(1, unit: "seconds"))]
        )
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.filter",
                configuration: .init(rules: [
                    .init(comparison: .greater, value: .number(2, unit: "seconds")),
                    invalidUnitRule,
                ]),
                inputs: ["input": .data(oneSecond)], services: services
            )
        }

        let optionalRecord: WorkflowDataSchema = .record([
            .init("optional", .optional(.text), required: false),
        ])
        guard case .record(let optionalFields) = optionalRecord else { return }
        let missingOptional = WorkflowDatum.record(schema: optionalFields, fields: [:])
        let existence = try await execute(
            "d.value.filter",
            configuration: .init(rules: [
                .init(path: ["optional"], comparison: .exists),
                .init(path: ["notInSchema"], comparison: .exists),
            ]),
            inputs: [
                "input": .data(.list(
                    element: optionalRecord, items: [.init(id: "missing", value: missingOptional)]
                )),
            ],
            services: services
        )
        #expect(try datum("output", in: existence).items?.isEmpty == true)
        #expect(services.callCount == 0)
    }

    @Test func filterEvaluatesMissingFieldPredicatesAfterAnEarlierFalse() async throws {
        let services = RejectingDataServices()
        let fields: [WorkflowRecordField] = [
            .init("gate", .boolean), .init("x", .text, required: false),
        ]
        let element: WorkflowDataSchema = .record(fields)
        let missingX = WorkflowDatum.record(schema: fields, fields: ["gate": .boolean(false)])
        let missingInput = WorkflowDatum.list(
            element: element, items: [.init(id: "missing-x", value: missingX)]
        )
        let gateThenX: [WorkflowDataRule] = [
            .init(path: ["gate"], comparison: .equals, value: .boolean(true)),
            .init(path: ["x"], comparison: .equals, value: .text("a")),
        ]
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.filter", configuration: .init(rules: gateThenX),
                inputs: ["input": .data(missingInput)], services: services
            )
        }

        let existsAfterFalse = try await execute(
            "d.value.filter",
            configuration: .init(rules: [
                .init(path: ["gate"], comparison: .equals, value: .boolean(true)),
                .init(path: ["x"], comparison: .exists),
            ]),
            inputs: ["input": .data(missingInput)], services: services
        )
        #expect(try datum("output", in: existsAfterFalse).items?.isEmpty == true)

        func row(gate: Bool, x: String) -> WorkflowDatum {
            .record(schema: fields, fields: ["gate": .boolean(gate), "x": .text(x)])
        }
        let legitimateInput = WorkflowDatum.list(element: element, items: [
            .init(id: "keep-1", value: row(gate: true, x: "a")),
            .init(id: "skip", value: row(gate: false, x: "a")),
            .init(id: "keep-2", value: row(gate: true, x: "a")),
        ])
        let legitimate = try await execute(
            "d.value.filter", configuration: .init(rules: gateThenX),
            inputs: ["input": .data(legitimateInput)], services: services
        )
        #expect(try datum("output", in: legitimate).items?.map(\.id) == ["keep-1", "keep-2"])
        #expect(services.callCount == 0)
    }

    @Test func selectRequiresAnExplicitIDOrValidOneBasedIndex() async throws {
        let services = RejectingDataServices()
        let input = WorkflowDatum.list(element: .text, items: [
            .init(id: "a", value: .text("A")), .init(id: "b", value: .text("B")),
        ])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute("d.value.select", inputs: ["input": .data(input)], services: services)
        }
        let byID = try await execute(
            "d.value.select", parameters: ["itemID": .text("b")],
            inputs: ["input": .data(input)], services: services
        )
        #expect(try datum("output", in: byID) == .text("B"))

        let byIndex = try await execute(
            "d.value.select", parameters: ["method": .text("index"), "index": .integer(1)],
            inputs: ["input": .data(input)], services: services
        )
        #expect(try datum("output", in: byIndex) == .text("A"))
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.select", parameters: ["method": .text("index"), "index": .integer(3)],
                inputs: ["input": .data(input)], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func pairIsOneToOneLeftOrderedAndKeepsBothUnmatchedLists() async throws {
        let services = RejectingDataServices()
        let recordSchema: [WorkflowRecordField] = [.init("key", .text), .init("value", .text)]
        let element: WorkflowDataSchema = .record(recordSchema)
        func row(_ key: String, _ value: String) -> WorkflowDatum {
            .record(schema: recordSchema, fields: ["key": .text(key), "value": .text(value)])
        }
        let left = WorkflowDatum.list(element: element, items: [
            .init(id: "l-b", value: row("b", "LB")),
            .init(id: "l-a", value: row("a", "LA")),
            .init(id: "l-x", value: row("x", "LX")),
        ])
        let right = WorkflowDatum.list(element: element, items: [
            .init(id: "r-a", value: row("a", "RA")),
            .init(id: "r-b", value: row("b", "RB")),
            .init(id: "r-z", value: row("z", "RZ")),
        ])
        let outputs = try await execute(
            "d.value.pair", configuration: .init(path: ["key"]),
            inputs: ["left": .data(left), "right": .data(right)], services: services
        )
        #expect(try datum("output", in: outputs).items?.map(\.id) == ["l-b", "l-a"])
        #expect(try datum("leftUnmatched", in: outputs).items?.map(\.id) == ["l-x"])
        #expect(try datum("rightUnmatched", in: outputs).items?.map(\.id) == ["r-z"])

        let duplicateLeft = WorkflowDatum.list(element: element, items: [
            .init(id: "one", value: row("same", "1")), .init(id: "two", value: row("same", "2")),
        ])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.pair", configuration: .init(path: ["key"]),
                inputs: ["left": .data(duplicateLeft), "right": .data(right)], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func validateSeparatesReportFailureFromStrictFailure() async throws {
        let services = RejectingDataServices()
        let invalid = WorkflowDatum.number(25, unit: "frames")
        let outputs = try await execute(
            "d.value.validate", configuration: .init(schema: .number(unit: "seconds")),
            inputs: ["input": .data(invalid)], services: services
        )
        let report = try datum("output", in: outputs)
        #expect(report.fields?["valid"] == .boolean(false))
        #expect(report.fields?["data"] == .none(.number(unit: "seconds")))
        #expect(report.fields?["issues"]?.items?.count == 1)
        #expect(report.fields?["data"] != invalid)

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.validate", configuration: .init(schema: .number(unit: "seconds")),
                parameters: ["strict": .flag(true)], inputs: ["input": .data(invalid)], services: services
            )
        }

        let valid = try await execute(
            "d.value.validate", configuration: .init(schema: .text),
            inputs: ["input": .data(.text("ok"))], services: services
        )
        let validReport = try datum("output", in: valid)
        #expect(validReport.fields?["valid"] == .boolean(true))
        #expect(validReport.fields?["data"] == .text("ok"))
        #expect(validReport.fields?["issues"]?.items?.isEmpty == true)
        #expect(services.callCount == 0)
    }

    @Test func validateReportsNestedOptionalNoneAndRejectsMismatchedNone() async throws {
        let services = RejectingDataServices()
        let expected: WorkflowDataSchema = .optional(.text)

        let reportOutputs = try await execute(
            "d.value.validate", configuration: .init(schema: expected),
            inputs: ["input": .data(.none(.text))], services: services
        )
        let report = try datum("output", in: reportOutputs)
        #expect(report.fields?["valid"] == .boolean(true))
        #expect(report.fields?["data"] == .none(.text))
        #expect(report.fields?["issues"]?.items?.isEmpty == true)

        let strictOutputs = try await execute(
            "d.value.validate", configuration: .init(schema: expected),
            parameters: ["strict": .flag(true)],
            inputs: ["input": .data(.none(.text))], services: services
        )
        #expect(try datum("output", in: strictOutputs).fields?["valid"] == .boolean(true))

        let mismatch = try await execute(
            "d.value.validate", configuration: .init(schema: expected),
            inputs: ["input": .data(.none(.boolean))], services: services
        )
        let mismatchReport = try datum("output", in: mismatch)
        #expect(mismatchReport.fields?["valid"] == .boolean(false))
        #expect(mismatchReport.fields?["data"] == .none(expected))
        #expect(mismatchReport.fields?["issues"]?.items?.count == 1)

        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.validate", configuration: .init(schema: expected),
                parameters: ["strict": .flag(true)],
                inputs: ["input": .data(.none(.boolean))], services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func assetDatumPassesAsDataAndUnexpectedInputsAreRejected() async throws {
        let services = RejectingDataServices()
        let reference = WorkflowAssetReference(
            projectID: UUID(), assetID: UUID(), kind: .audio, sha256: String(repeating: "a", count: 64)
        )
        let outputs = try await execute(
            "d.value.return", inputs: ["input": .asset(reference)], services: services
        )
        #expect(try datum("output", in: outputs) == .asset(reference))
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute(
                "d.value.return", inputs: ["input": .asset(reference), "extra": .data(.text("bad"))],
                services: services
            )
        }
        #expect(services.callCount == 0)
    }

    @Test func jsonValidationReportsStrictErrorsWithoutRepairingText() async throws {
        let services = RejectingDataServices()
        let schema = WorkflowDataSchema.record([.init("title", .text)])
        let config = WorkflowDataConfiguration(schema: schema, validationInputFormat: .jsonText)
        for text in ["```json\n{\"title\":\"ok\"}\n```", "{\"title\":true}", "{\"title\":\"a\",\"title\":\"b\"}", "{\"title\":\"a\",\"extra\":0}"] {
            let result = try await execute("d.value.validate", configuration: config, inputs: ["input": .data(.text(text))], services: services)
            let report = try datum("output", in: result)
            #expect(report.fields?["valid"] == .boolean(false))
            #expect(report.fields?["data"] == .none(schema))
            #expect(report.fields?["issues"]?.items?.isEmpty == false)
            await #expect(throws: (any Error).self) {
                _ = try await execute("d.value.validate", configuration: config, parameters: ["strict": .flag(true)], inputs: ["input": .data(.text(text))], services: services)
            }
        }
        let success = try await execute("d.value.validate", configuration: config, inputs: ["input": .data(.text("{\"title\":\"中文 👩🏽‍🎨\"}"))], services: services)
        let report = try datum("output", in: success)
        #expect(report.fields?["valid"] == .boolean(true))
        #expect(report.fields?["data"]?.fields?["title"] == .text("中文 👩🏽‍🎨"))
        await #expect(throws: WorkflowIssue.self) {
            _ = try await execute("d.value.validate", configuration: config, inputs: ["input": .data(.boolean(true))], services: services)
        }
    }

    @Test func jsonValidationPreflightAndLegacyEncodingRemainExplicit() throws {
        let old = WorkflowDataConfiguration(schema: .text)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("validationInputFormat"))
        #expect(try JSONDecoder().decode(WorkflowDataConfiguration.self, from: encoded) == old)
        var node = try operation("d.value.validate").definition.makeNode()
        node.dataConfiguration = .init(schema: .record([.init("title", .text)]), validationInputFormat: .jsonText)
        try WorkflowRegistry.standard.validate(node)
        #expect(WorkflowRegistry.standard.definition(for: node)?.inputs.first?.kinds == [.text])
        for unsupported in [WorkflowDataSchema.asset(.image), .result(.text)] {
            node.dataConfiguration?.schema = unsupported
            #expect(throws: (any Error).self) { try WorkflowRegistry.standard.validate(node) }
        }
    }

    private func operation(_ id: String) throws -> WorkflowOperation {
        try #require(WorkflowDataOperations.operations.first { $0.definition.id == id })
    }

    private func execute(
        _ id: String,
        configuration: WorkflowDataConfiguration? = nil,
        parameters: [String: WorkflowScalar] = [:],
        inputs: [String: WorkflowValue] = [:],
        services: RejectingDataServices
    ) async throws -> [String: WorkflowValue] {
        let operation = try operation(id)
        var node = operation.definition.makeNode()
        node.dataConfiguration = configuration
        for (name, value) in parameters { node.parameters[name] = value }
        try operation.validate(node)
        let result = try await operation.execute(
            .init(node: node, stepID: UUID(), inputs: inputs), services
        )
        guard case .outputs(let outputs) = result else {
            throw WorkflowIssue("Expected data outputs from \(id).")
        }
        return outputs
    }

    private func datum(_ port: String, in outputs: [String: WorkflowValue]) throws -> WorkflowDatum {
        guard case .data(let value)? = outputs[port] else {
            throw WorkflowIssue("Expected data output at \(port).")
        }
        return value
    }
}

@MainActor private final class RejectingDataServices: WorkflowOperationServices {
    private(set) var callCount = 0

    private func unexpected<T>(_ name: String) throws -> T {
        callCount += 1
        throw WorkflowIssue("Data operation unexpectedly called \(name).")
    }

    func readText(_ reference: WorkflowAssetReference) async throws -> String { try unexpected("readText") }
    func verifyAsset(_ reference: WorkflowAssetReference) async throws { try unexpected("verifyAsset") as Void }
    func publishText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("publishText") }
    func rewriteText(
        _ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("rewriteText") }
    func generateImages(
        prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext
    ) async throws -> [WorkflowCandidate] { try unexpected("generateImages") }
    func transformImage(
        _ reference: WorkflowAssetReference, context: WorkflowExecutionContext
    ) async throws -> WorkflowAssetReference { try unexpected("transformImage") }
    func export(
        _ value: WorkflowValue, context: WorkflowExecutionContext
    ) async throws -> WorkflowExportReceipt { try unexpected("export") }
}

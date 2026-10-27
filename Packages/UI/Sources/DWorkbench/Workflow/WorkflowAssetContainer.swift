import CryptoKit
import Foundation

/// The container selects within one frozen call. A batch is an ordered set of
/// these calls, never a synthetic list formed by concatenating their outputs.
public enum WorkflowAssetContainer {
    public static func containsFilter(_ plan: WorkflowPlan) -> Bool {
        plan.steps.contains { step in
            if step.node.operationID == filterID { return true }
            switch step.kind {
            case .call: return false
            case .branch(_, let yes, let no): return containsFilter(yes) || containsFilter(no)
            case .map(let body, _), .loop(let body, _, _, _), .invoke(_, let body): return containsFilter(body)
            }
        }
    }
    public static let previewID = "d.asset.preview"
    public static let filterID = "d.asset.filter"
    public static let sourceID = "d.asset.group"
    public static func isContainer(_ id: String) -> Bool {
        [previewID, filterID, sourceID, "d.asset.reference"].contains(id)
    }

    public static func sourceValues(_ sources: [WorkflowLibrarySource], runs: [WorkflowRun]) throws -> [WorkflowValue] {
        try sources.map { source in
            switch source {
            case .asset(let ref): return .asset(ref)
            case .runtime(let ref): try ref.validateForCollection(in: runs); return try ref.resolve(in: runs)
            }
        }
    }
    public static func sourceOutput(_ sources: [WorkflowLibrarySource], values: [WorkflowValue]) -> WorkflowValue? {
        guard sources.count == values.count else { return nil }
        if values.count == 1 { return values[0] }
        let data = values.compactMap(\.datum)
        guard data.count == values.count, let schema = data.first?.schema, data.allSatisfy({ $0.schema == schema }) else { return nil }
        return .data(.list(element: schema, items: zip(sources, data).map { .init(id: $0.key, value: $1) }))
    }
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let value: WorkflowValue?
        public let failure: String?
        public var selectable: Bool { value != nil && failure == nil }
    }

    public static func items(in value: WorkflowValue) throws -> [Item] {
        switch value {
        case .collection(let candidates):
            guard candidates.count <= 8, Set(candidates.map(\.id)).count == candidates.count else {
                throw WorkflowIssue("Container candidate identities are invalid.", code: "container.issue.invalidSources")
            }
            return candidates.map { candidate in
                Item(id: candidate.id.uuidString, value: candidate.asset.map(WorkflowValue.asset),
                     failure: candidate.error ?? (candidate.asset == nil ? "Missing candidate asset" : nil))
            }
        case .data(.list(_, let items)):
            try value.datum?.validate()
            return items.map { Item(id: $0.id, value: .data($0.value), failure: nil) }
        default:
            try value.datum?.validate()
            return [Item(id: "value", value: value, failure: nil)]
        }
    }

    /// Preserve shape, member identities and original order, even for one item.
    /// Empty selection is rejection, never a fabricated empty value.
    public static func selecting(_ selected: [String], from input: WorkflowValue) throws -> WorkflowValue {
        let items = try items(in: input), ids = Set(selected)
        guard !ids.isEmpty, ids.count == selected.count,
              ids.isSubset(of: Set(items.filter(\.selectable).map(\.id))) else {
            throw WorkflowIssue("Select available items from this exact container call.", code: "container.issue.selectionUnavailable")
        }
        switch input {
        case .collection(let values): return .collection(values.filter { ids.contains($0.id.uuidString) })
        case .data(.list(let element, let values)):
            return .data(.list(element: element, items: values.filter { ids.contains($0.id) }))
        default: return input
        }
    }

    public static func validateDecision(_ decision: WorkflowDecision, step: WorkflowStepRun) throws {
        guard step.node.operationID == filterID, decision.waitingStepID == step.id,
              decision.output == nil, decision.selectedCandidateID == nil,
              let ids = decision.selectedItemIDs, let input = step.inputs["input"] else {
            throw WorkflowIssue("Container decision is not bound to this call.", code: "container.issue.selectionUnavailable")
        }
        if decision.accepted {
            let expected = try selecting(ids, from: input)
            let ordered = try items(in: input).filter { Set(ids).contains($0.id) }.map(\.id)
            guard expected == decision.typedOutput, ids == ordered else { throw WorkflowIssue("Container selection changed its frozen value or order.", code: "container.issue.selectionUnavailable") }
        } else {
            guard ids.isEmpty, decision.typedOutput == nil else { throw WorkflowIssue("Rejected container has an output.", code: "container.issue.selectionUnavailable") }
        }
    }

    public static func references(in value: WorkflowValue) -> [WorkflowAssetReference] {
        switch value {
        case .asset(let reference): return [reference]
        case .collection(let candidates): return candidates.compactMap(\.asset)
        case .data(let datum): return datum.assetReferences
        case .receipt: return []
        }
    }
}

public struct WorkflowContainerScope: Codable, Sendable, Equatable {
    public let stageID: UUID?
    public let runID: UUID?
    public let path: [WorkflowAddressComponent]
    public init(stageID: UUID? = nil, runID: UUID? = nil, path: [WorkflowAddressComponent]) {
        self.stageID = stageID; self.runID = runID; self.path = path
    }
    public var key: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkflowContainerChoice: Codable, Sendable, Equatable {
    public let call: WorkflowCallReference
    public let selectedIDs: [String]
    public init(call: WorkflowCallReference, selectedIDs: [String]) { self.call = call; self.selectedIDs = selectedIDs }
}

/// One durable intent alongside the original runs and batch ledger. Dispatch
/// remains owned by WorkflowBatchStage; this is not a second queue.
public struct WorkflowContainerSubmission: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let scope: WorkflowContainerScope
    public let choices: [WorkflowContainerChoice]
    public let repetitions: Int
    public let seedStrategy: WorkflowBatchSeedStrategy
    public var nextStageID: UUID?
    public let createdAt: Date
}

public struct WorkflowContainerSnapshot: Sendable, Equatable {
    public let projectID: UUID
    public let instanceID: UUID
    public let scope: WorkflowContainerScope
    public let stage: WorkflowBatchStage?
    public let runs: [WorkflowRun]
    public var calls: [WorkflowPlanCallRecord] {
        runs.flatMap { $0.planCheckpoint?.records.filter { $0.address.path == scope.path } ?? [] }
    }
    public var collectionComplete: Bool {
        guard let stage else { return runs.allSatisfy { ![.running, .queued, .saving, .cancelling].contains($0.status) } }
        return stage.attempts.allSatisfy { [.waiting, .completed, .failed, .cancelled].contains($0.state) }
    }
}

enum WorkflowContainerOperations {
    static let kinds = WorkflowDataKind.allCases.filter { $0 != .receipt }
    static let operations: [WorkflowOperation] = [make(review: true), make(review: false), source]
    private static func make(review: Bool) -> WorkflowOperation {
        .init(definition: .init(id: review ? WorkflowAssetContainer.filterID : WorkflowAssetContainer.previewID,
            title: review ? "资产容器" : "预览容器", detail: review ? "查看并明确选择，再继续下游。" : "只读预览，原值继续传递。",
            inputs: [.init("input", "资产", kinds: kinds)], outputs: [.init("output", "资产", kinds: kinds)],
            fields: [.init("kind", "数据类型", .choice(kinds.map(\.rawValue)), .text("text"))],
            interaction: review ? .containerReview : .none),
            execute: { context, services in
                guard let input = context.inputs["input"], input.kind.rawValue == context.node.parameters["kind"]?.string else {
                    throw WorkflowIssue("Container input does not match its declared type.", code: "container.issue.inputType")
                }
                try input.datum?.validate(as: context.node.dataConfiguration?.schema)
                for reference in WorkflowAssetContainer.references(in: input) { try await services.verifyAsset(reference) }
                return review ? .reviewValue(input) : .outputs(["output": input])
            })
    }
    private static let source = WorkflowOperation(definition: .init(id: WorkflowAssetContainer.sourceID,
        title: "资产预览组", detail: "引用已有值，保持顺序；混合资产只预览。", inputs: [],
        outputs: [.init("output", "资产列表", kinds: kinds)],
        fields: [.init("kind", "数据类型", .choice(["mixed"] + kinds.map(\.rawValue)), .text("mixed"))]), validate: { node in
            if let sources = node.librarySources {
                guard !sources.isEmpty, sources.count <= 64, Set(sources.map(\.key)).count == sources.count else { throw WorkflowIssue("Invalid exact container sources.", code: "container.issue.invalidSources") }
                return
            }
            guard let configuration = node.dataConfiguration else { throw WorkflowIssue("Missing container source.", code: "container.issue.invalidSources") }
            if let value = configuration.value { try value.validate() }
            guard configuration.items.count <= 4096, Set(configuration.items.map(\.id)).count == configuration.items.count else {
                throw WorkflowIssue("Invalid source group identities.", code: "container.issue.invalidSources")
            }
            for item in configuration.items { try item.value.validate() }
        }, execute: { context, services in
            if let sources = context.node.librarySources {
                let values = try await services.resolveLibrarySources(sources)
                for value in values { for ref in WorkflowAssetContainer.references(in: value) { try await services.verifyAsset(ref) } }
                guard let output = WorkflowAssetContainer.sourceOutput(sources, values: values) else {
                    guard context.node.parameters["kind"]?.string == "mixed" else { throw WorkflowIssue("Source group type changed.", code: "container.issue.inputType") }
                    return .outputs([:])
                }
                guard output.kind.rawValue == context.node.parameters["kind"]?.string else { throw WorkflowIssue("Source type differs from its declared port.", code: "container.issue.inputType") }
                return .outputs(["output": output])
            }
            guard let configuration = context.node.dataConfiguration else { throw WorkflowIssue("Missing container source.", code: "container.issue.invalidSources") }
            let values = configuration.value.map { [$0] } ?? configuration.items.map(\.value)
            for value in values { for reference in value.assetReferences { try await services.verifyAsset(reference) } }
            if let value = configuration.value { return .outputs(["output": .data(value)]) }
            guard let schema = configuration.items.first?.value.schema,
                  configuration.items.allSatisfy({ $0.value.schema == schema }) else { return .outputs([:]) }
            return .outputs(["output": .data(.list(element: schema, items: configuration.items))])
        })
}

import Foundation
import DInference

public enum WorkflowBatchSeedStrategy: String, Codable, Sendable, CaseIterable {
    case fixed, automatic
}

/// Static paths omit Map item / Loop iteration selectors. Inherited calls retain
/// their full paths, so a later iteration can vary without changing its prefix.
public struct WorkflowBatchSeedAssignment: Codable, Sendable, Equatable {
    public var path: [WorkflowAddressComponent]
    public var value: String
}

public struct WorkflowBatchSeedSchedule: Codable, Sendable, Equatable {
    public var strategy: WorkflowBatchSeedStrategy
    public var assignments: [WorkflowBatchSeedAssignment]
    public var inherited: [WorkflowBatchSeedAssignment]

    public static func supportedNodeCount(in plan: WorkflowPlan, registry: WorkflowRegistry = .standard) -> Int {
        targets(in: plan, registry: registry).count
    }

    static func maximumSeed(for node: WorkflowNode, registry: WorkflowRegistry) -> UInt64? {
        guard let definition = registry.operation(node.operationID)?.definition,
              definition.modelKind != nil,
              definition.fields.contains(where: { $0.id == "seed" }) else { return nil }
        if node.operationID == "d.video.generate" { return VideoExecutionCapability.wan21.maximumSeed }
        if let profile = ExternalVideoExecutionProfile.allCases.first(where: { WorkflowVideoRecipe(profile: $0).operationID == node.operationID }) {
            return profile.maximumSeed
        }
        if node.operationID == "d.music.generate" { return AudioRequest.mrt2MaximumSeed }
        if node.operationID == WorkflowModelRoutes.ace { return AudioRequest.aceMaximumSeed }
        return UInt64.max
    }

    private struct Target {
        var path: [WorkflowAddressComponent]
        var maximum: UInt64
        var unspecified: Bool
    }
    private static func targets(in plan: WorkflowPlan, prefix: [WorkflowAddressComponent] = [],
                                registry: WorkflowRegistry) -> [Target] {
        plan.steps.flatMap { step -> [Target] in
            let path = prefix + [.node(step.id)]
            switch step.kind {
            case .call:
                return maximumSeed(for: step.node, registry: registry).map { [Target(path: path, maximum: $0, unspecified: step.node.parameters["seed"]?.string?.isEmpty != false)] } ?? []
            case .branch(_, let yes, let no):
                return targets(in: yes, prefix: path + [.branch(true)], registry: registry) +
                    targets(in: no, prefix: path + [.branch(false)], registry: registry)
            case .map(let body, _), .loop(let body, _, _, _):
                return targets(in: body, prefix: path, registry: registry)
            case .invoke(let reference, let body):
                return targets(in: body, prefix: path + [.tool(reference)], registry: registry)
            }
        }
    }

    static func staticPath(_ path: [WorkflowAddressComponent]) -> [WorkflowAddressComponent] {
        path.filter { component in
            switch component { case .item, .iteration: false; default: true }
        }
    }

    static func inheritedAssignments(from checkpoint: WorkflowPlanCheckpoint?, registry: WorkflowRegistry) -> [WorkflowBatchSeedAssignment] {
        (checkpoint?.records ?? []).compactMap { record in
            guard maximumSeed(for: record.step.node, registry: registry) != nil,
                  let seed = record.step.node.parameters["seed"]?.string else { return nil }
            return .init(path: record.address.path, value: seed)
        }
    }

    /// Allocate the entire stage before any dispatch. Adjacent attempts vary even
    /// at the UInt64 boundary; fixed inputs never pass through this arithmetic.
    static func allocate(plan: WorkflowPlan, parent: WorkflowPlanCheckpoint? = nil,
                         strategy: WorkflowBatchSeedStrategy, count: Int,
                         registry: WorkflowRegistry, nextSeed: () -> UInt64) throws -> [Self?] {
        guard (1...64).contains(count) else { throw WorkflowIssue("种子分配次数超限。") }
        let targets = targets(in: plan, registry: registry)
        guard strategy != .automatic || !targets.isEmpty else {
            throw WorkflowIssue("当前范围没有提供种子参数的生成操作；请使用固定配方。")
        }
        let inherited = inheritedAssignments(from: parent, registry: registry)
        let allocatedTargets = strategy == .automatic ? targets : targets.filter(\.unspecified)
        guard !allocatedTargets.isEmpty || !inherited.isEmpty else { return Array(repeating: nil, count: count) }
        let bases: [UInt64] = allocatedTargets.map { target in
            let random = nextSeed()
            return target.maximum == UInt64.max ? random : random % (target.maximum + 1)
        }
        return (0..<count).map { offset -> Self? in
            let assignments: [WorkflowBatchSeedAssignment] = zip(allocatedTargets, bases).map { target, base in
                let value: UInt64
                let increment = strategy == .automatic ? UInt64(offset) : 0
                if target.maximum == UInt64.max { value = base &+ increment }
                else { value = (base + increment) % (target.maximum + 1) }
                return WorkflowBatchSeedAssignment(path: target.path, value: String(value))
            }
            return Self(strategy: strategy, assignments: assignments, inherited: inherited)
        }
    }

    func validate(in checkpoint: WorkflowPlanCheckpoint, registry: WorkflowRegistry) throws {
        let targets = Self.targets(in: checkpoint.plan, registry: registry)
        let maxima = Dictionary(targets.map { ($0.path, $0.maximum) }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(checkpoint.records.map { ($0.address.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard assignments.count <= 4_096, inherited.count <= 65_536,
              Set(assignments.map(\.path)).count == assignments.count,
              Set(inherited.map(\.path)).count == inherited.count,
              (strategy == .automatic ? !targets.isEmpty && Set(assignments.map(\.path)) == Set(targets.map(\.path)) : Set(assignments.map(\.path)) == Set(targets.filter(\.unspecified).map(\.path))) else {
            throw WorkflowIssue("批次种子计划与真实生成操作不匹配。")
        }
        for item in assignments {
            guard let maximum = maxima[item.path],
                  let seed = UInt64(item.value), String(seed) == item.value, seed <= maximum else {
                throw WorkflowIssue("批次种子超出对应适配器的完整范围。")
            }
        }
        for item in inherited {
            guard let record = records[item.path],
                  Self.maximumSeed(for: record.step.node, registry: registry) != nil,
                  record.step.node.parameters["seed"]?.string == item.value else {
                throw WorkflowIssue("继承种子与固定前缀调用不一致。")
            }
        }
    }
}

/// Owned by one executor / validation pass; never retained across checkpoint replacement.
struct WorkflowBatchSeedLookup {
    private let inherited: [[WorkflowAddressComponent]: String]
    private let assignments: [[WorkflowAddressComponent]: String]
    init(_ schedule: WorkflowBatchSeedSchedule?) {
        inherited = Dictionary((schedule?.inherited ?? []).prefix(65_536).map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        assignments = Dictionary((schedule?.assignments ?? []).prefix(4_096).map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    func applying(to node: WorkflowNode, at address: WorkflowExecutionAddress) -> WorkflowNode {
        guard let value = inherited[address.path] ?? assignments[WorkflowBatchSeedSchedule.staticPath(address.path)] else { return node }
        var result = node
        result.parameters["seed"] = .text(value)
        return result
    }
}

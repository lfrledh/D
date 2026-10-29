import CryptoKit
import Foundation

/// A durable authorization, not a live task or a second project owner.
public struct WorkflowBatchStage: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, running, paused, finished, cancelled, savingBlocked }
    /// Optional for old archives. Never infer this provenance from a user's title.
    public enum SystemTitle: String, Codable, Sendable { case continuation, retry }
    public var id: UUID
    public var createdAt: Date
    public var name: String
    public var systemTitle: SystemTitle?
    public var repetitions: Int
    public var parentRunIDs: [UUID]
    public var attempts: [WorkflowBatchAttempt]
    public var state: State
    public var seedStrategy: WorkflowBatchSeedStrategy?
    public init(name: String, repetitions: Int, parentRunIDs: [UUID] = [], attempts: [WorkflowBatchAttempt],
                seedStrategy: WorkflowBatchSeedStrategy = .fixed, systemTitle: SystemTitle? = nil) {
        id = UUID(); createdAt = Date(); self.name = name; self.repetitions = repetitions
        self.systemTitle = systemTitle
        self.parentRunIDs = parentRunIDs; self.attempts = attempts; state = .queued; self.seedStrategy = seedStrategy
    }
}

public struct WorkflowBatchAttempt: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, dispatched, waiting, completed, failed, cancelled, interrupted, savingBlocked }
    /// This is the durable dispatch key. It is allocated before any computation.
    public var id: UUID
    public var ordinal: Int
    public var runID: UUID
    public var state: State
    public var startedAt: Date?
    /// Only a measured invocation interval, never wall time spent waiting for a human.
    public var activeSeconds: Double?
    public init(ordinal: Int, runID: UUID) {
        id = UUID(); self.ordinal = ordinal; self.runID = runID; state = .queued
    }
}

/// Exact frozen prefix proof. The source run remains retained and immutable.
public struct WorkflowBatchParent: Codable, Sendable, Equatable {
    public var runID: UUID
    public var checkpointDigest: String
    public var stepIDs: [UUID: UUID]
}

enum WorkflowBatchValidation {
    static func digest(_ checkpoint: WorkflowPlanCheckpoint) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = checkpoint; body.externalInputs = [:]
        // UUID-keyed dictionaries encode as unordered alternating arrays. Canonicalize
        // the one such field explicitly so cold decoding cannot change the proof.
        let inputs = Dictionary(uniqueKeysWithValues: checkpoint.externalInputs.map { ($0.key.uuidString, $0.value) })
        var bytes = try encoder.encode(body); bytes.append(0); bytes.append(try encoder.encode(inputs))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func acceptedPrefix(_ parent: WorkflowRun) throws -> WorkflowPlanCheckpoint {
        guard let original = parent.planCheckpoint, original.state == .waiting || original.state == .paused,
              !original.records.isEmpty,
              original.records.contains(where: { $0.step.humanTask?.decision != nil || $0.step.decision?.accepted == true }) else {
            throw WorkflowIssue("请先保存本次尝试的全部人工决定；未采用、拒绝或失败的分支不能作为下一阶段输入。", code: "workflow.batch.issue.saveDecisions")
        }
        for record in original.records where ![.completed, .partial].contains(record.step.status) {
            if isWithinSettledControl(record, in: original) { continue }
            guard [.running, .queued].contains(record.step.status), record.step.node.control != nil else {
                throw WorkflowIssue("本次尝试仍有未采用或未成功的关卡；不能继续其下游。", code: "workflow.batch.issue.unsettled")
            }
        }
        return original
    }

    private static func isWithinSettledControl(_ record: WorkflowPlanCallRecord, in checkpoint: WorkflowPlanCheckpoint) -> Bool {
        checkpoint.records.contains {
            $0.step.node.control != nil && [.completed, .partial].contains($0.step.status) &&
            $0.address.path.count < record.address.path.count && record.address.path.starts(with: $0.address.path)
        }
    }

    static func continuation(of parent: WorkflowRun) throws -> WorkflowRun {
        let original = try acceptedPrefix(parent)
        var child = parent
        child.id = UUID(); child.createdAt = Date(); child.status = .queued
        let mapping = Dictionary(uniqueKeysWithValues: original.records.map { ($0.id, UUID()) })
        child.batchParent = .init(runID: parent.id, checkpointDigest: try digest(original), stepIDs: mapping)
        var checkpoint = try remap(original, runID: child.id, stepIDs: mapping)
        checkpoint.state = .ready; checkpoint.error = nil; checkpoint.outputs = [:]
        child.planCheckpoint = checkpoint
        child.steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
        return child
    }

    private static func remap(_ source: WorkflowPlanCheckpoint, runID: UUID, stepIDs: [UUID: UUID]) throws -> WorkflowPlanCheckpoint {
        var result = source; result.runID = runID
        for i in result.records.indices {
            let old = result.records[i].id
            guard let replacement = stepIDs[old] else { throw WorkflowIssue("派生调用身份缺失。") }
            result.records[i].address.runID = runID
            result.records[i].step.id = replacement
            if var human = result.records[i].step.humanTask { human.id = replacement; result.records[i].step.humanTask = human }
            if let decision = result.records[i].step.decision {
                // The new immutable decision identity is deterministic within the child's dispatch.
                result.records[i].step.decision = .init(id: replacement, waitingStepID: replacement,
                    accepted: decision.accepted, selectedCandidateID: decision.selectedCandidateID, output: decision.output,
                    selectedItemIDs: decision.selectedItemIDs, typedOutput: decision.typedOutput)
            }
        }
        return result
    }

    static func validateParents(_ runs: [WorkflowRun], registry: WorkflowRegistry = .standard) throws {
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        for run in runs {
            guard let parent = run.batchParent else { continue }
            guard let source = byID[parent.runID], source.id != run.id, let sourceCP = source.planCheckpoint,
                  let cp = run.planCheckpoint, try digest(sourceCP) == parent.checkpointDigest,
                  run.graph == source.graph, run.scope == source.scope, run.targetNodeID == source.targetNodeID,
                  cp.plan == sourceCP.plan, cp.arguments == sourceCP.arguments,
                  cp.modelDefaults == sourceCP.modelDefaults, cp.externalInputs == sourceCP.externalInputs,
                  Set(parent.stepIDs.keys) == Set(sourceCP.records.map(\.id)),
                  Set(parent.stepIDs.values).count == parent.stepIDs.count,
                  Set(parent.stepIDs.values).isDisjoint(with: Set(sourceCP.records.map(\.id))) else {
                throw WorkflowIssue("批次的固定父输入、计划或派生身份不匹配。")
            }
            _ = try acceptedPrefix(source)
            let expectedSeeds = WorkflowBatchSeedSchedule.inheritedAssignments(from: sourceCP, registry: registry)
            guard (cp.batchSeeds?.inherited ?? []) == expectedSeeds || (cp.batchSeeds == nil && sourceCP.batchSeeds == nil) else {
                throw WorkflowIssue("下一阶段丢失或改写了前缀的精确种子。")
            }
            let inherited = try remap(sourceCP, runID: run.id, stepIDs: parent.stepIDs)
            for old in inherited.records {
                guard let record = cp.records.first(where: { $0.address == old.address }), record.id == old.id else {
                    throw WorkflowIssue("批次丢失已采用的前缀调用。")
                }
                if [.completed, .partial].contains(old.step.status) || isWithinSettledControl(old, in: inherited) {
                    guard record == old else { throw WorkflowIssue("批次改写了冻结前缀，不能重新计算已采用输入。") }
                } else {
                    // An enclosing Map/Loop/tool may finish while its bound input stays fixed.
                    guard old.step.node.control != nil, record.step.node == old.step.node, record.step.inputs == old.step.inputs,
                          record.step.inputsBound == old.step.inputsBound, record.step.signature == old.step.signature else {
                        throw WorkflowIssue("批次改写了外层控制调用的固定输入。")
                    }
                }
            }
            var ancestor: UUID? = parent.runID, visited: Set<UUID> = [run.id]
            while let id = ancestor {
                guard visited.insert(id).inserted, visited.count <= 256 else { throw WorkflowIssue("批次来源循环或超过预算。") }
                ancestor = byID[id]?.batchParent?.runID
            }
        }
    }

    static func validate(_ stages: [WorkflowBatchStage], runs: [WorkflowRun], registry: WorkflowRegistry = .standard) throws {
        guard stages.count <= 256, Set(stages.map(\.id)).count == stages.count else { throw WorkflowIssue("批次数量或身份无效。") }
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var dispatched = Set<UUID>(), owned = Set<UUID>()
        for stage in stages {
            let parents = max(1, stage.parentRunIDs.count)
            guard (1...64).contains(stage.repetitions), !stage.attempts.isEmpty, stage.attempts.count <= 256,
                  parents * stage.repetitions == stage.attempts.count,
                  Set(stage.parentRunIDs).count == stage.parentRunIDs.count,
                  stage.parentRunIDs.allSatisfy({ byID[$0] != nil }) else { throw WorkflowIssue("批次展开数量无效。") }
            for parent in stage.parentRunIDs {
                guard stage.attempts.filter({ byID[$0.runID]?.batchParent?.runID == parent }).count == stage.repetitions else {
                    throw WorkflowIssue("每个已选输入必须恰好对应明确授权的次数。")
                }
            }
            if stage.parentRunIDs.isEmpty, let first = stage.attempts.first.flatMap({ byID[$0.runID] }), let cp = first.planCheckpoint {
                for attempt in stage.attempts {
                    guard let run = byID[attempt.runID], let other = run.planCheckpoint,
                          run.graph == first.graph, run.scope == first.scope, run.targetNodeID == first.targetNodeID,
                          other.plan == cp.plan, other.arguments == cp.arguments,
                          other.externalInputs == cp.externalInputs, other.modelDefaults == cp.modelDefaults else {
                        throw WorkflowIssue("同一批次的固定配方、范围或输入不一致。")
                    }
                }
            }
            for (index, attempt) in stage.attempts.enumerated() {
                guard attempt.ordinal == index + 1, dispatched.insert(attempt.id).inserted,
                      owned.insert(attempt.runID).inserted, let run = byID[attempt.runID],
                      run.planCheckpoint != nil, (run.scope?.recomputeSelected == true || run.batchParent != nil),
                      attempt.activeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      (stage.parentRunIDs.isEmpty ? run.batchParent == nil : stage.parentRunIDs.contains(run.batchParent?.runID ?? UUID())) else {
                    throw WorkflowIssue("批次派发身份、运行来源或耗时无效。")
                }
                let seeds = run.planCheckpoint?.batchSeeds
                guard (seeds?.strategy ?? .fixed) == (stage.seedStrategy ?? .fixed),
                      !stage.parentRunIDs.isEmpty || seeds?.inherited.isEmpty != false else {
                    throw WorkflowIssue("批次种子策略或继承来源与阶段不一致。")
                }
            }
        }
        guard runs.filter({ $0.batchParent != nil }).allSatisfy({ owned.contains($0.id) }) else { throw WorkflowIssue("派生尝试缺少唯一阶段所有者。") }
        guard runs.filter({ $0.planCheckpoint?.batchSeeds != nil }).allSatisfy({ owned.contains($0.id) }) else {
            throw WorkflowIssue("种子调度必须属于明确授权的批次。")
        }
        try validateParents(runs, registry: registry)
    }
}

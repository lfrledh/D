import Foundation
import Observation

/// Quick creation is a single existing operation, not a hidden workflow graph.
public struct QuickDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var node: WorkflowNode
    public var inputs: [String: WorkflowValue]
    public var fieldText: [String: String] = [:]
    public var attempts = 1
    public init(id: String, node: WorkflowNode, inputs: [String: WorkflowValue] = [:]) {
        self.id = id; self.node = node; self.inputs = inputs
    }
}
public struct QuickRunRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, completed, partial, cancelled, failed, interrupted }
    public let id: UUID
    public let draft: QuickDraft
    public let createdAt: Date
    public var batchID: UUID? = nil
    public var attemptIndex: Int? = nil
    public var retryOf: UUID? = nil
    public var status: Status
    public var outputs: [String: WorkflowValue]
    public var candidates: [WorkflowCandidate]
    public var issue: String?
}
public struct QuickCreationState: Codable, Sendable, Equatable {
    public var version = 1
    public var revision: UInt64 = 0
    public var selectedDraftID: String?
    public var drafts: [QuickDraft] = []
    public var runs: [QuickRunRecord] = []
    public init() {}
    public func validate() throws {
        guard version == 1, drafts.count <= 512, runs.count <= 10_000,
              Set(drafts.map(\.id)).count == drafts.count, Set(runs.map(\.id)).count == runs.count,
              selectedDraftID == nil || drafts.contains(where: { $0.id == selectedDraftID }) else {
            throw WorkflowIssue("快速记录的版本或内容无效，已保留原件。")
        }
        for draft in drafts + runs.map(\.draft) {
            guard !draft.id.isEmpty, draft.id.utf8.count <= 2048,
                  (1...8).contains(draft.attempts),
                  WorkflowRegistry.standard.operation(draft.node.operationID)?.definition.modelKind != nil else {
                throw WorkflowIssue("快速记录包含未知模型操作，不能覆盖。")
            }
        }
    }
}

@MainActor @Observable public final class QuickGenerationController {
    public private(set) var state = QuickCreationState()
    public private(set) var error: String?
    public private(set) var isLoaded = false
    public private(set) var isRunning = false
    public private(set) var phase = ""
    public private(set) var saveIssue: String?
    public private(set) var pendingSaveRunID: UUID?
    @ObservationIgnored private var cancelRequested = false
    public private(set) var activeRunID: UUID?
    public let store: ProjectStore
    @ObservationIgnored private let makeServices: @MainActor () throws -> WorkflowServices
    @ObservationIgnored private var services: WorkflowServices?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writeTail: Task<Void, Error>?
    @ObservationIgnored private var diskRevision: UInt64 = 0

    public init(store: ProjectStore, makeServices: @escaping @MainActor () throws -> WorkflowServices) {
        self.store = store; self.makeServices = makeServices
    }
    public var draft: QuickDraft? { state.drafts.first { $0.id == state.selectedDraftID } }
    public var definition: WorkflowOperationDefinition? {
        draft.flatMap { WorkflowRegistry.standard.definition(for: $0.node) }
    }
    public var visibleRuns: [QuickRunRecord] {
        state.runs.filter { $0.draft.id == state.selectedDraftID }.reversed()
    }
    public var inputIssue: String? {
        guard let draft, let definition = WorkflowRegistry.standard.definition(for: draft.node) else { return nil }
        guard (1...8).contains(draft.attempts) else { return "快速生成一次支持 1–8 次独立尝试。" }
        for field in definition.fields {
            guard let raw = draft.fieldText[field.id] else { continue }
            switch field.kind {
            case .integer: if Int(raw) == nil { return field.title + "需要整数" }
            case .decimal: if Double(raw)?.isFinite != true { return field.title + "需要有效数值" }
            default: break
            }
        }
        return nil
    }
    public var canStart: Bool {
        isLoaded && !isRunning && pendingSaveRunID == nil && saveIssue == nil && inputIssue == nil &&
        draft?.node.parameters["modelID"]?.string?.isEmpty == false
    }
    public func setFieldText(_ key: String, text: String, draftID: String) {
        guard let index = state.drafts.firstIndex(where: { $0.id == draftID }),
              let field = WorkflowRegistry.standard.definition(for: state.drafts[index].node)?.fields.first(where: { $0.id == key }) else { return }
        state.drafts[index].fieldText[key] = text
        switch field.kind {
        case .integer: if let value = Int(text) { state.drafts[index].node.parameters[key] = .integer(value) }
        case .decimal: if let value = Double(text), value.isFinite { state.drafts[index].node.parameters[key] = .decimal(value) }
        default: return
        }
        scheduleSave()
    }
    public func load() async {
        guard !isLoaded else { return }
        do {
            state = try await store.quickCreationState(); diskRevision = state.revision
            let original = state
            for index in state.runs.indices where [.running, .failed, .cancelled, .interrupted].contains(state.runs[index].status) {
                let ids = [state.runs[index].id] + state.runs[index].candidates.map(\.attemptID)
                for stepID in ids {
                    for ref in try await store.workflowAssets(forStepID: stepID) {
                        state.runs[index].outputs["preserved-" + ref.assetID.uuidString] = .asset(ref)
                    }
                }
                if state.runs[index].status == .running {
                    state.runs[index].status = .interrupted
                    state.runs[index].issue = "上次运行中断；已保存的结果仍保留，不会自动重跑。"
                }
            }
            isLoaded = true
            if state != original { try await flush() }
        } catch { self.error = error.localizedDescription }
    }
    public func select(operationID: String, modelID: String) {
        guard isLoaded, let operation = WorkflowRegistry.standard.operation(operationID),
              operation.definition.modelKind != nil else { return }
        let key = operationID + "|" + modelID
        if !state.drafts.contains(where: { $0.id == key }) {
            var node = operation.definition.makeNode()
            node.parameters["modelID"] = .text(modelID)
            // The text field remains editable; no output from a previous model is reused.
            if operationID == "d.model.language" { node.parameters["outputMode"] = .text("text") }
            if operationID == "d.image.generate" { node.parameters["count"] = .integer(1) }
            state.drafts.append(.init(id: key, node: node))
        }
        state.selectedDraftID = key; scheduleSave()
    }
    public func setParameter(_ key: String, value: WorkflowScalar, draftID: String) {
        guard isLoaded, let index = state.drafts.firstIndex(where: { $0.id == draftID }), key != "modelID" else { return }
        state.drafts[index].node.parameters[key] = value; scheduleSave()
    }
    public func setAttempts(_ count: Int, draftID: String) {
        guard (1...8).contains(count), let index = state.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        state.drafts[index].attempts = count; scheduleSave()
    }
    public func setDataConfiguration(_ value: WorkflowDataConfiguration?, draftID: String) {
        guard let index = state.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        state.drafts[index].node.dataConfiguration = value; scheduleSave()
    }
    public func setInput(_ port: String, value: WorkflowValue?, draftID: String) {
        guard isLoaded, let index = state.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        state.drafts[index].inputs[port] = value; scheduleSave()
    }
    /// The panel and Store can suspend while a different draft or input is selected.
    /// Commit the whole imported batch only against the state captured before opening it.
    public func commitImportedAssets(_ assets: [WorkflowAssetReference], port: WorkflowPortDefinition,
                                     draftID: String, expectedNode: WorkflowNode,
                                     expectedInputs: [String: WorkflowValue]) throws {
        guard isLoaded, state.selectedDraftID == draftID,
              let index = state.drafts.firstIndex(where: { $0.id == draftID }),
              state.drafts[index].node == expectedNode,
              state.drafts[index].inputs == expectedInputs,
              WorkflowRegistry.standard.definition(for: expectedNode)?.inputs.contains(port) == true else {
            throw WorkflowIssue("输入已改变；导入的素材已保留在资料库，当前草稿未覆盖。")
        }
        guard !assets.isEmpty else { return }
        if let kind = port.assetListKind {
            guard assets.allSatisfy({ $0.kind == kind }) else {
                throw WorkflowIssue("文件已保留为素材，但不符合此输入端口。", port: port.id)
            }
            var items = try Self.assetItems(from: expectedInputs[port.id], port: port)
            items += assets.map { WorkflowDataItem(value: .asset($0)) }
            let value: WorkflowValue = .data(.list(element: .asset(kind), items: items))
            _ = try port.resolveAssets(value)
            state.drafts[index].inputs[port.id] = value
        } else {
            guard assets.count == 1, let asset = assets.first, port.kinds.contains(asset.kind) else {
                throw WorkflowIssue("文件已保留为素材，但不符合此输入端口。", port: port.id)
            }
            state.drafts[index].inputs[port.id] = .asset(asset)
        }
        scheduleSave()
    }
    public func inputAssetItems(port: WorkflowPortDefinition, draftID: String) -> [WorkflowDataItem] {
        guard let draft = state.drafts.first(where: { $0.id == draftID }),
              let actual = WorkflowRegistry.standard.definition(for: draft.node)?.inputs.first(where: { $0.id == port.id }),
              actual == port else { return [] }
        return (try? Self.assetItems(from: draft.inputs[port.id], port: port)) ?? []
    }
    public func moveInputAsset(_ itemID: String, by offset: Int, port: WorkflowPortDefinition, draftID: String) throws {
        let index = try editableAssetListIndex(port: port, draftID: draftID)
        guard let kind = port.assetListKind, [-1, 1].contains(offset) else { return }
        var items = try Self.assetItems(from: state.drafts[index].inputs[port.id], port: port)
        guard let source = items.firstIndex(where: { $0.id == itemID }),
              items.indices.contains(source + offset) else { return }
        items.swapAt(source, source + offset)
        state.drafts[index].inputs[port.id] = .data(.list(element: .asset(kind), items: items))
        scheduleSave()
    }
    public func removeInputAsset(_ itemID: String, port: WorkflowPortDefinition, draftID: String) throws {
        let index = try editableAssetListIndex(port: port, draftID: draftID)
        guard let kind = port.assetListKind else { return }
        var items = try Self.assetItems(from: state.drafts[index].inputs[port.id], port: port)
        guard let source = items.firstIndex(where: { $0.id == itemID }) else { return }
        items.remove(at: source)
        state.drafts[index].inputs[port.id] = items.isEmpty ? nil :
            .data(.list(element: .asset(kind), items: items))
        scheduleSave()
    }
    private func editableAssetListIndex(port: WorkflowPortDefinition, draftID: String) throws -> Int {
        guard isLoaded, state.selectedDraftID == draftID, port.assetListKind != nil,
              let index = state.drafts.firstIndex(where: { $0.id == draftID }),
              WorkflowRegistry.standard.definition(for: state.drafts[index].node)?.inputs.contains(port) == true else {
            throw WorkflowIssue("当前草稿或输入端口已改变。")
        }
        return index
    }
    private static func assetItems(from value: WorkflowValue?, port: WorkflowPortDefinition) throws -> [WorkflowDataItem] {
        guard let value else { return [] }
        _ = try port.resolveAssets(value)
        if case .data(.list(_, let items)) = value { return items }
        guard let asset = value.asset else { throw WorkflowIssue("输入不是资产列表。", port: port.id) }
        return [WorkflowDataItem(id: asset.version.uuidString, value: .asset(asset))]
    }
    public func useSettings(_ node: WorkflowNode, inputs: [String: WorkflowValue] = [:]) {
        guard isLoaded, WorkflowRegistry.standard.operation(node.operationID)?.definition.modelKind != nil,
              let model = node.parameters["modelID"]?.string else { return }
        if node.operationID == "d.image.generate", !(1...8).contains(node.parameters["count"]?.integer ?? 1) {
            error = "此图像节点的候选次数不在 1–8 范围，原快速草稿未改变。"; return
        }
        select(operationID: node.operationID, modelID: model)
        guard let index = state.drafts.firstIndex(where: { $0.id == state.selectedDraftID }) else { return }
        state.drafts[index].node = node; state.drafts[index].inputs = inputs
        if node.operationID == "d.image.generate" {
            state.drafts[index].attempts = node.parameters["count"]?.integer ?? 1
            state.drafts[index].node.parameters["count"] = .integer(1)
        }
        state.drafts[index].fieldText = [:]; scheduleSave()
    }
    private func scheduleSave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)); try await self?.flush() }
            catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }
    public func flush() async throws {
        guard isLoaded else { throw WorkflowIssue(error ?? "快速记录尚未读取。") }
        let preceding = writeTail
        let task = Task { @MainActor [self] in
            _ = try? await preceding?.value
            var value = state
            guard diskRevision < UInt64.max else { throw WorkflowIssue("快速记录版本已达上限。") }
            value.revision = diskRevision + 1
            let savedRevision = try await store.saveQuickCreationState(value, expectedRevision: diskRevision)
            diskRevision = savedRevision; state.revision = savedRevision; saveIssue = nil
        }
        writeTail = task
        do { try await task.value } catch { saveIssue = error.localizedDescription; throw error }
    }
    public func start() {
        guard canStart, let source = draft, (1...8).contains(source.attempts) else { return }
        var attempts: [QuickDraft] = []
        // Separate requests, never multiply the image operation's internal batch count.
        for offset in 0..<source.attempts {
            var captured = source
            if captured.node.operationID == "d.image.generate" { captured.node.parameters["count"] = .integer(1) }
            if offset > 0, let raw = captured.node.parameters["seed"]?.string, let seed = UInt64(raw) {
                let (next, overflow) = seed.addingReportingOverflow(UInt64(offset))
                guard !overflow else { error = "独立尝试的种子超出范围，请减少次数或调整种子。"; return }
                captured.node.parameters["seed"] = .text(String(next))
            }
            attempts.append(captured)
        }
        launch(attempts)
    }
    /// Explicitly rerun one failed attempt's frozen inputs, without replacing its prior evidence.
    public func retryAttempt(_ id: UUID) {
        guard isLoaded, !isRunning, saveIssue == nil, pendingSaveRunID == nil,
              let previous = state.runs.first(where: { $0.id == id }),
              [.failed, .cancelled, .interrupted, .partial].contains(previous.status) else { return }
        var captured = previous.draft; captured.attempts = 1
        launch([captured], retryOf: id)
    }
    private func launch(_ attempts: [QuickDraft], retryOf: UUID? = nil) {
        isRunning = true; cancelRequested = false; error = nil; phase = "正在保存输入…"
        let batch = UUID()
        runTask = Task { [self] in
            defer { isRunning = false; activeRunID = nil; if pendingSaveRunID == nil { services = nil }; runTask = nil }
            for (offset, captured) in attempts.enumerated() {
                // Preserve an explicit cancelled first attempt even if cancelled before admission.
                if offset > 0 && cancelRequested { break }
                let id = UUID(); activeRunID = id
                state.runs.append(.init(id: id, draft: captured, createdAt: Date(), batchID: batch,
                    attemptIndex: offset + 1, retryOf: retryOf, status: .running, outputs: [:], candidates: [], issue: nil))
            do {
                try await flush()
                if cancelRequested { throw CancellationError() }
                let service = try makeServices(); services = service
                service.progress = { [weak self] in self?.phase = $0 }
                service.candidatesChanged = { [weak self] _, candidates in
                    guard let self, let index = self.state.runs.firstIndex(where: { $0.id == id }) else { return }
                    self.state.runs[index].candidates = candidates; try await self.flush()
                }
                try service.beginPlan()
                let result = try await service.executeCall(.init(node: captured.node, stepID: id, inputs: captured.inputs))
                guard let index = state.runs.firstIndex(where: { $0.id == id }) else { throw WorkflowIssue("运行记录丢失。") }
                switch result {
                case .outputs(let values): state.runs[index].outputs = values
                default: throw WorkflowIssue("此模型操作需要工作流中的人工任务，请在画布运行。")
                }
                updateOutcome(at: index); phase = "运行已结束"
                do { try await flush() } catch { self.error = "结果已产生，记录待保存：" + error.localizedDescription }
            } catch {
                if services?.hasPendingSaves == true { pendingSaveRunID = id }
                if let index = state.runs.firstIndex(where: { $0.id == id }) {
                    if let candidates = services?.retainedCandidates(stepID: id) { state.runs[index].candidates = candidates }
                    let published = (try? await store.workflowAssets(forStepID: id)) ?? []
                    for reference in published where !state.runs[index].outputs.values.contains(where: { $0.asset == reference }) {
                        state.runs[index].outputs["preserved-" + reference.assetID.uuidString] = .asset(reference)
                    }
                    state.runs[index].status = (error is CancellationError) ? .cancelled : .failed
                    state.runs[index].issue = error.localizedDescription
                }
                self.error = error.localizedDescription; phase = "运行已结束"
                do { try await flush() } catch { self.error = "结果或状态尚未保存：" + error.localizedDescription }
            }
                if pendingSaveRunID != nil || saveIssue != nil { break }
                services = nil
            }
        }
    }
    public func cancel() async {
        cancelRequested = true
        phase = "正在取消并释放资源…"
        await services?.cancel()
        // No view owns this task; wait for the actual runtime outcome before declaring idle.
        await runTask?.value
    }
    private func updateOutcome(at index: Int) {
        let candidates = state.runs[index].outputs.values.flatMap(\.candidates)
        state.runs[index].candidates = candidates
        let failures = candidates.compactMap(\.error)
        state.runs[index].status = failures.isEmpty ? .completed : (candidates.contains { $0.asset != nil } ? .partial : .failed)
        state.runs[index].issue = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    public func retrySave() async {
        guard !isRunning else { return }
        do {
            if let id = pendingSaveRunID, let services, let index = state.runs.firstIndex(where: { $0.id == id }) {
                isRunning = true
                defer { isRunning = false }
                let draft = state.runs[index].draft
                let values = try await services.retryQuickPublications(.init(node: draft.node, stepID: id, inputs: draft.inputs))
                state.runs[index].outputs = values; updateOutcome(at: index)
                pendingSaveRunID = nil; self.services = nil
            }
            try await flush(); error = nil
        } catch {
            if let id = pendingSaveRunID, let index = state.runs.firstIndex(where: { $0.id == id }), services?.hasPendingSaves == false {
                for ref in (try? await store.workflowAssets(forStepID: id)) ?? [] { state.runs[index].outputs["preserved-" + ref.assetID.uuidString] = .asset(ref) }
                state.runs[index].status = .failed; state.runs[index].issue = error.localizedDescription
                pendingSaveRunID = nil; services = nil
                do { try await flush() } catch { saveIssue = error.localizedDescription }
            }
            self.error = error.localizedDescription
        }
    }
    public func waitForCompletion() async { await runTask?.value }
    public func prepareForTermination() async throws {
        // A rejected sidecar is read-only: no edits were admitted and its bytes must remain intact.
        guard isLoaded else { return }
        guard !isRunning, pendingSaveRunID == nil else { throw WorkflowIssue("快速生成仍有运行或待保存结果。") }
        try await flush()
    }
}

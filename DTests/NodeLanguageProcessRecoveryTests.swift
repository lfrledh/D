import DInference
import DWorkbench
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import D

private enum ProcessRecoveryCase: String, Codable, Equatable {
    case map
    case loop
    case human
}

private enum ProcessRecoveryPhase: String, Codable, Equatable {
    case produce
    case reopen
}

private struct ProcessRecoveryLedgerEntry: Codable, Equatable {
    let ordinal: Int
    let requestID: UUID
    let phase: ProcessRecoveryPhase
    let recoveryCase: ProcessRecoveryCase
    let input: String
    let processID: Int32
}

private struct ProcessRecoveryRecordSummary: Codable, Equatable {
    let stepID: UUID
    let operationID: String
    let status: String
    let address: String
    let outputText: String?
    let rawAssetID: UUID?
    let humanDraft: String?
    let humanDecision: String?
}

private struct ProcessRecoveryCheckpointSummary: Codable, Equatable {
    let state: String
    let records: [ProcessRecoveryRecordSummary]
}

private struct ProcessRecoveryReady: Codable {
    let schemaVersion: Int
    let nonce: UUID
    let recoveryCase: ProcessRecoveryCase
    let phase: ProcessRecoveryPhase
    let processID: Int32
    let executable: String
    let project: String
    let ledger: String
    let projectID: UUID
    let runID: UUID
    let sourceRevision: String
    let testedIdentity: String
    let checkpoint: ProcessRecoveryCheckpointSummary
}

private struct ProcessRecoveryResult: Codable {
    let schemaVersion: Int
    let nonce: UUID
    let recoveryCase: ProcessRecoveryCase
    let produceProcessID: Int32
    let reopenProcessID: Int32
    let executable: String
    let projectID: UUID
    let runID: UUID
    let sourceRevision: String
    let testedIdentity: String
    let beforeLedger: [ProcessRecoveryLedgerEntry]
    let afterLedger: [ProcessRecoveryLedgerEntry]
    let finalCheckpoint: ProcessRecoveryCheckpointSummary
}

private struct ProcessRecoveryIssue: Error, LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

private actor ProcessRecoveryEngine: InferenceEngine {
    private let ledgerURL: URL
    private let phase: ProcessRecoveryPhase
    private let recoveryCase: ProcessRecoveryCase
    private var entries: [ProcessRecoveryLedgerEntry]
    private var submissionsThisPhase = 0

    init(
        ledgerURL: URL,
        phase: ProcessRecoveryPhase,
        recoveryCase: ProcessRecoveryCase,
        existingEntries: [ProcessRecoveryLedgerEntry]
    ) {
        self.ledgerURL = ledgerURL
        self.phase = phase
        self.recoveryCase = recoveryCase
        self.entries = existingEntries
    }

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        guard backendID == NodeLanguageProcessRecoveryTests.backendID else {
            throw ProcessRecoveryIssue("Unexpected deterministic backend: \(backendID)")
        }
        guard case .text(let text) = request.input else {
            throw ProcessRecoveryIssue("The recovery fixture accepts text requests only.")
        }
        submissionsThisPhase += 1
        let expectedPrompt = try expectedPrompt(for: submissionsThisPhase)
        guard text.prompt == expectedPrompt else {
            throw ProcessRecoveryIssue(
                "Unexpected prompt for \(recoveryCase.rawValue)/\(phase.rawValue) call \(submissionsThisPhase): \(text.prompt)"
            )
        }
        let entry = ProcessRecoveryLedgerEntry(
            ordinal: entries.count + 1,
            requestID: request.id,
            phase: phase,
            recoveryCase: recoveryCase,
            input: text.prompt,
            processID: getpid()
        )
        try append(entry)
        entries.append(entry)

        if phase == .produce, recoveryCase != .human, submissionsThisPhase == 2 {
            while true { try await Task.sleep(for: .seconds(30)) }
        }

        let value: String
        switch (recoveryCase, phase, submissionsThisPhase) {
        case (.map, .produce, 1): value = "map-first"
        case (.map, .reopen, 1): value = "map-second"
        case (.loop, .produce, 1): value = "1"
        case (.loop, .reopen, 1): value = "2"
        case (.human, .produce, 1): value = "human-source"
        case (.human, .reopen, 1): value = "human-downstream"
        default:
            throw ProcessRecoveryIssue(
                "Unexpected fixture submission \(submissionsThisPhase) for \(recoveryCase.rawValue)/\(phase.rawValue)."
            )
        }
        let result = InferenceResult(metadata: ["fixture": NodeLanguageProcessRecoveryTests.testedIdentity])
        return InferenceRun(
            id: request.id,
            events: AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(value))
                continuation.finish()
            },
            cancel: {},
            outcome: { .completed(result) }
        )
    }

    func snapshot() -> [ProcessRecoveryLedgerEntry] { entries }

    private func expectedPrompt(for submission: Int) throws -> String {
        switch (recoveryCase, phase, submission) {
        case (.map, .produce, 1):
            return "Return the supplied item.\n\nContent:\nfirst input"
        case (.map, .produce, 2), (.map, .reopen, 1):
            return "Return the supplied item.\n\nContent:\nsecond input"
        case (.loop, .produce, 1):
            return "Return the next integer.\n\nContent:\n0"
        case (.loop, .produce, 2), (.loop, .reopen, 1):
            return "Return the next integer.\n\nContent:\n1"
        case (.human, .produce, 1):
            return "Create deterministic source text."
        case (.human, .reopen, 1):
            return "Use the approved text.\n\nContent:\nedited after source"
        default:
            throw ProcessRecoveryIssue(
                "Unexpected prompt slot \(submission) for \(recoveryCase.rawValue)/\(phase.rawValue)."
            )
        }
    }

    private func append(_ entry: ProcessRecoveryLedgerEntry) throws {
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        guard Darwin.fsync(handle.fileDescriptor) == 0 else {
            throw ProcessRecoveryIssue("Could not make the recovery ledger durable: errno \(errno).")
        }
    }
}

/// The produce phase intentionally remains alive after writing ready.json. The Lead-owned
/// external driver validates nonce/PID/executable before killing only that test host.
@Suite(.serialized) @MainActor
struct NodeLanguageProcessRecoveryTests {
    nonisolated fileprivate static let sourceRevision = "a65216fd270ebac3ee31adf5f752a3a60457ed02"
    nonisolated fileprivate static let testedIdentity = "PROCESS-RECOVERY-CHECKS-r1"
    nonisolated fileprivate static let backendID = "fixture.process-recovery.text"
    nonisolated private static let modelIdentity = "text:process-recovery-fixture-v1"

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "process-recovery"),
        .timeLimit(.minutes(6))
    )
    func persistedCheckpointRecoversAcrossKilledTestHosts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let recoveryCase = try Self.requiredEnum(
            ProcessRecoveryCase.self, key: "D_NODE_RECOVERY_CASE", environment: environment
        )
        let phase = try Self.requiredEnum(
            ProcessRecoveryPhase.self, key: "D_NODE_RECOVERY_PHASE", environment: environment
        )
        let nonceText = try Self.required("D_NODE_RECOVERY_NONCE", environment: environment)
        guard let nonce = UUID(uuidString: nonceText) else {
            throw ProcessRecoveryIssue("D_NODE_RECOVERY_NONCE must be a UUID.")
        }

        let paths = try Self.paths(nonce: nonce)
        switch phase {
        case .produce:
            try await produce(recoveryCase, nonce: nonce, paths: paths)
        case .reopen:
            try await reopen(recoveryCase, nonce: nonce, paths: paths)
        }
    }

    private func produce(
        _ recoveryCase: ProcessRecoveryCase,
        nonce: UUID,
        paths: RecoveryPaths
    ) async throws {
        guard !FileManager.default.fileExists(atPath: paths.root.path) else {
            throw ProcessRecoveryIssue("Produce refuses existing recovery data: \(paths.root.path)")
        }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data().write(to: paths.ledger, options: .withoutOverwriting)

        let engine = ProcessRecoveryEngine(
            ledgerURL: paths.ledger, phase: .produce, recoveryCase: recoveryCase, existingEntries: []
        )
        var store: ProjectStore?
        var controller: WorkflowController?
        var runTask: Task<Void, Never>?
        var runtime: WorkbenchSession?
        do {
            let created = try await ProjectStore.create(at: paths.project, name: "Process recovery \(recoveryCase.rawValue)")
            store = created
            let session = Self.session(store: created, root: paths.root, engine: engine)
            runtime = session
            let services = Self.services(store: created, session: session, root: paths.root)
            let graph = try Self.graph(for: recoveryCase)
            let initial = try Self.require(try await created.workflowState().archive, "New project has no workflow archive.")
            _ = try await created.saveWorkflow(
                graphs: [graph], runs: [], expectedRevision: initial.revision
            )
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()
            try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Controller failed to load.")

            switch recoveryCase {
            case .map, .loop:
                let target = try Self.require(subject.graph?.nodes.first(where: {
                    $0.operationID == "d.control.\(recoveryCase.rawValue)"
                })?.id, "Recovery control target is missing.")
                let owned = Task { @MainActor in await subject.run(target: target, only: false) }
                runTask = owned
                let archive = try await Self.waitForProduceBoundary(
                    store: created, engine: engine, recoveryCase: recoveryCase, ledgerURL: paths.ledger
                )
                let run = try Self.require(archive.runs.last, "Produce run was not persisted.")
                try Self.verifyProduceBoundary(recoveryCase, run: run)
                try await Self.writeProduceEvidence(
                    archive: archive,
                    engine: engine,
                    recoveryCase: recoveryCase,
                    nonce: nonce,
                    paths: paths,
                    store: created,
                    run: run
                )
            case .human:
                let target = try Self.require(subject.graph?.nodes.first(where: {
                    $0.title == "Downstream language"
                })?.id, "Human recovery target is missing.")
                await subject.run(target: target, only: false)
                try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Human produce failed.")
                let waitingRun = try Self.require(subject.runs.last, "Human waiting run is missing.")
                let waiting = try Self.require(waitingRun.planCheckpoint?.records.first(where: {
                    $0.step.node.operationID == "d.control.human"
                }), "Human waiting call is missing.")
                subject.editHumanDraft(stepID: waiting.step.id, value: .text("edited after source"))
                await subject.save()
                try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Human draft save failed.")
                let archive = try Self.require(try await created.workflowState().archive, "Saved human archive is missing.")
                let run = try Self.require(archive.runs.last, "Saved human run is missing.")
                try Self.verifyHumanProduce(run: run)
                try await Self.writeProduceEvidence(
                    archive: archive,
                    engine: engine,
                    recoveryCase: recoveryCase,
                    nonce: nonce,
                    paths: paths,
                    store: created,
                    run: run
                )
            }

            print("D_NODE_RECOVERY_ROOT=\(paths.root.path)")
            print("D_NODE_RECOVERY_READY=\(paths.ready.path)")
            try await Task.sleep(for: .seconds(300))
            throw ProcessRecoveryIssue("External termination did not arrive within 300 seconds; produce cannot pass.")
        } catch {
            await Self.cleanupAfterUnexpectedError(
                controller: controller, runTask: runTask, runtime: runtime, store: store
            )
            throw error
        }
    }

    private func reopen(
        _ recoveryCase: ProcessRecoveryCase,
        nonce: UUID,
        paths: RecoveryPaths
    ) async throws {
        let ready: ProcessRecoveryReady = try Self.readJSON(ProcessRecoveryReady.self, from: paths.ready)
        let executable = try Self.executablePath()
        try Self.check(ready.schemaVersion == 1, "Unsupported ready marker version.")
        try Self.check(ready.nonce == nonce, "Ready marker nonce does not match.")
        try Self.check(ready.recoveryCase == recoveryCase, "Ready marker case does not match.")
        try Self.check(ready.phase == .produce, "Ready marker did not come from produce.")
        try Self.check(ready.processID != getpid(), "Reopen must use a new test-host PID.")
        try Self.check(ready.executable == executable, "Reopen test-host executable identity changed.")
        try Self.check(ready.project == paths.project.path, "Ready marker project path changed.")
        try Self.check(ready.ledger == paths.ledger.path, "Ready marker ledger path changed.")
        try Self.check(ready.sourceRevision == Self.sourceRevision, "Ready marker source revision changed.")
        try Self.check(ready.testedIdentity == Self.testedIdentity, "Ready marker test identity changed.")

        let producedArchive: WorkflowArchive = try Self.readJSON(WorkflowArchive.self, from: paths.produceArchive)
        let producedRun = try Self.require(
            producedArchive.runs.first(where: { $0.id == ready.runID }),
            "Retained produce archive does not contain the marked run."
        )
        let producedSummary = try Self.summary(producedRun)
        try Self.check(producedSummary == ready.checkpoint, "Retained produce archive does not match ready.json.")
        let beforeLedger = try Self.readLedger(paths.ledger)
        let expectedProduceCount = recoveryCase == .human ? 1 : 2
        try Self.check(beforeLedger.count == expectedProduceCount, "Retained produce ledger count is wrong.")
        try Self.check(
            beforeLedger.allSatisfy { $0.phase == .produce && $0.recoveryCase == recoveryCase },
            "Retained ledger contains a foreign phase or recovery case."
        )
        try Self.check(
            beforeLedger.allSatisfy { $0.processID == ready.processID },
            "Retained produce ledger PID does not match ready.json."
        )
        try Self.check(
            beforeLedger.map(\.ordinal) == Array(1...expectedProduceCount),
            "Retained produce ledger ordinals are not contiguous."
        )
        let engine = ProcessRecoveryEngine(
            ledgerURL: paths.ledger,
            phase: .reopen,
            recoveryCase: recoveryCase,
            existingEntries: beforeLedger
        )
        var store: ProjectStore?
        var controller: WorkflowController?
        var runtime: WorkbenchSession?
        do {
            let opened = try await ProjectStore.open(at: paths.project)
            store = opened
            let projectID = await opened.snapshot().id
            try Self.check(projectID == ready.projectID, "Reopened project identity changed.")
            let session = Self.session(store: opened, root: paths.root, engine: engine)
            runtime = session
            let services = Self.services(store: opened, session: session, root: paths.root)
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()
            try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Reopen load failed.")
            let ledgerAfterLoad = await engine.snapshot()
            try Self.check(ledgerAfterLoad == beforeLedger, "Loading automatically submitted inference.")
            let loaded = try Self.require(subject.runs.first(where: { $0.id == ready.runID }), "Recovery run is missing.")
            try await Self.verifyRetainedCompletedCalls(
                produced: producedRun, current: loaded, store: opened
            )

            switch recoveryCase {
            case .map, .loop:
                try Self.verifyLoadedInterruption(recoveryCase, run: loaded)
                await subject.resume(runID: loaded.id)
                try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Recovery resume failed.")
                let completed = try Self.require(subject.runs.first(where: { $0.id == loaded.id }), "Resumed run is missing.")
                try Self.verifyCompleted(recoveryCase, run: completed)
            case .human:
                try Self.verifyHumanProduce(run: loaded)
                try Self.verifyRetainedHumanTask(
                    produced: producedRun, current: loaded, expectedDecision: nil
                )
                let waiting = try Self.require(loaded.planCheckpoint?.records.first(where: {
                    $0.step.node.operationID == "d.control.human"
                }), "Reopened human wait is missing.")
                let task = try Self.require(waiting.step.humanTask, "Reopened human task is missing.")
                let ledgerBeforeDecision = await engine.snapshot()
                try Self.check(ledgerBeforeDecision == beforeLedger, "Human reopen automatically submitted inference.")
                await subject.decideHuman(
                    stepID: waiting.step.id,
                    value: .text("edited after source"),
                    expectedTask: task
                )
                try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Human decision failed.")
                let decided = try Self.require(subject.runs.first(where: { $0.id == loaded.id }), "Decided run is missing.")
                try Self.verifyRetainedHumanTask(
                    produced: producedRun,
                    current: decided,
                    expectedDecision: .text("edited after source")
                )
                let ledgerAfterDecision = await engine.snapshot()
                try Self.check(ledgerAfterDecision == beforeLedger, "Human decision ran downstream inference.")
                await subject.decideHuman(
                    stepID: waiting.step.id,
                    value: .text("edited after source"),
                    expectedTask: task
                )
                let repeated = try Self.require(subject.runs.first(where: { $0.id == loaded.id }), "Repeated-decision run is missing.")
                try Self.check(repeated == decided, "Repeating the old human decision changed the run.")
                let ledgerAfterRepeatedDecision = await engine.snapshot()
                try Self.check(ledgerAfterRepeatedDecision == beforeLedger, "Repeating the old decision submitted inference.")
                await subject.resume(runID: loaded.id)
                try Self.check(subject.errorMessage == nil, subject.errorMessage ?? "Human downstream resume failed.")
                let completed = try Self.require(subject.runs.first(where: { $0.id == loaded.id }), "Completed human run is missing.")
                try Self.verifyCompleted(.human, run: completed)
            }

            let finalRun = try Self.require(subject.runs.first(where: { $0.id == ready.runID }), "Final run is missing.")
            try await Self.verifyRetainedCompletedCalls(
                produced: producedRun, current: finalRun, store: opened
            )
            if recoveryCase == .human {
                try Self.verifyRetainedHumanTask(
                    produced: producedRun,
                    current: finalRun,
                    expectedDecision: .text("edited after source")
                )
            }
            let afterLedger = await engine.snapshot()
            try Self.verifyLedger(
                recoveryCase, before: beforeLedger, after: afterLedger, finalRun: finalRun
            )
            let result = ProcessRecoveryResult(
                schemaVersion: 1,
                nonce: nonce,
                recoveryCase: recoveryCase,
                produceProcessID: ready.processID,
                reopenProcessID: getpid(),
                executable: executable,
                projectID: ready.projectID,
                runID: ready.runID,
                sourceRevision: Self.sourceRevision,
                testedIdentity: Self.testedIdentity,
                beforeLedger: beforeLedger,
                afterLedger: afterLedger,
                finalCheckpoint: try Self.summary(finalRun)
            )
            try await subject.close()
            try await opened.close()
            await session.shutdown()
            try Self.writeJSON(result, to: paths.reopenResult)
            print("D_NODE_RECOVERY_REOPEN_PASS=\(paths.reopenResult.path)")
        } catch {
            if let subject = controller { subject.deactivateAfterClose() }
            if let session = runtime { await session.shutdown() }
            if let opened = store { try? await opened.close(preserveExternalChanges: true) }
            throw error
        }
    }

    private static func graph(for recoveryCase: ProcessRecoveryCase) throws -> WorkflowGraph {
        switch recoveryCase {
        case .map: return try mapGraph()
        case .loop: return try loopGraph()
        case .human: return try humanGraph()
        }
    }

    private static func mapGraph() throws -> WorkflowGraph {
        let item = try publicInput("item", schema: .text, title: "Map item")
        var language = try languageNode(title: "Mapped language", task: "Return the supplied item.")
        let bodyNodes = [item, language]
        var body = WorkflowGraph(
            name: "Map language body",
            nodes: bodyNodes,
            connections: [connect(item, language, targetPort: "content")],
            layout: layout(bodyNodes)
        )
        body.interface = .init(
            inputs: [.init("item", .text)],
            outputs: [.init(name: "output", nodeID: language.id, schema: .text)]
        )

        let items = WorkflowDatum.list(element: .text, items: [
            .init(id: "first", value: .text("first input")),
            .init(id: "second", value: .text("second input")),
        ])
        let input = try valueInput(title: "Stable map items", value: items)
        var map = try node("d.control.map", title: "Recovery map")
        map.control = .map(body: body, continueOnFailure: false)
        let nodes = [input, map]
        return WorkflowGraph(
            name: "Process recovery map",
            nodes: nodes,
            connections: [connect(input, map)],
            layout: layout(nodes)
        )
    }

    private static func loopGraph() throws -> WorkflowGraph {
        let state = try publicInput("state", schema: .text, title: "Loop state")
        let language = try languageNode(title: "Loop language", task: "Return the next integer.")
        let bodyNodes = [state, language]
        var body = WorkflowGraph(
            name: "Loop language body",
            nodes: bodyNodes,
            connections: [connect(state, language, targetPort: "content")],
            layout: layout(bodyNodes)
        )
        body.interface = .init(
            inputs: [.init("state", .text)],
            outputs: [.init(name: "state", nodeID: language.id, schema: .text)]
        )

        let input = try valueInput(title: "Initial state", value: .text("0"))
        var loop = try node("d.control.loop", title: "Recovery loop")
        loop.control = .loop(
            body: body,
            stateSchema: .text,
            maximumIterations: 3,
            until: .init(comparison: .equals, value: .text("2"))
        )
        let nodes = [input, loop]
        return WorkflowGraph(
            name: "Process recovery loop",
            nodes: nodes,
            connections: [connect(input, loop)],
            layout: layout(nodes)
        )
    }

    private static func humanGraph() throws -> WorkflowGraph {
        let source = try languageNode(title: "Source language", task: "Create deterministic source text.")
        var human = try node("d.control.human", title: "Edit source text")
        human.parameters["kind"] = .text("editText")
        human.parameters["instruction"] = .text("Edit the source and explicitly submit it.")
        human.dataConfiguration = .init(schema: .text)
        let downstream = try languageNode(title: "Downstream language", task: "Use the approved text.")
        let nodes = [source, human, downstream]
        return WorkflowGraph(
            name: "Process recovery human",
            nodes: nodes,
            connections: [
                connect(source, human),
                connect(human, downstream, targetPort: "content"),
            ],
            layout: layout(nodes)
        )
    }

    private static func node(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = WorkflowRegistry.standard.operation(operationID) else {
            throw ProcessRecoveryIssue("Required standard operation is missing: \(operationID)")
        }
        var result = operation.definition.makeNode()
        result.title = title
        return result
    }

    private static func languageNode(title: String, task: String) throws -> WorkflowNode {
        var result = try node("d.model.language", title: title)
        result.parameters["task"] = .text(task)
        result.parameters["modelID"] = .text(Self.modelIdentity)
        result.parameters["outputMode"] = .text("text")
        result.parameters["maximumOutputTokens"] = .integer(16)
        result.parameters["temperature"] = .decimal(0)
        result.dataConfiguration = .init(schema: .text)
        return result
    }

    private static func valueInput(title: String, value: WorkflowDatum) throws -> WorkflowNode {
        var result = try node("d.value.input", title: title)
        result.dataConfiguration = .init(value: value)
        return result
    }

    private static func publicInput(
        _ name: String,
        schema: WorkflowDataSchema,
        title: String
    ) throws -> WorkflowNode {
        var result = try node("d.value.input", title: title)
        result.parameters["publicName"] = .text(name)
        result.dataConfiguration = .init(schema: schema)
        return result
    }

    private static func connect(
        _ source: WorkflowNode,
        _ target: WorkflowNode,
        sourcePort: String = "output",
        targetPort: String = "input"
    ) -> WorkflowConnection {
        .init(
            sourceNode: source.id,
            sourcePort: sourcePort,
            targetNode: target.id,
            targetPort: targetPort
        )
    }

    private static func layout(_ nodes: [WorkflowNode]) -> [WorkflowLayout] {
        nodes.enumerated().map {
            WorkflowLayout(nodeID: $0.element.id, x: Double($0.offset) * 260, y: 100)
        }
    }

    private static func session(
        store: ProjectStore,
        root: URL,
        engine: ProcessRecoveryEngine
    ) -> WorkbenchSession {
        WorkbenchSession(
            engine: engine,
            backendID: Self.backendID,
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {},
            cleanup: {},
            validateModel: { _ in },
            textBackendID: Self.backendID
        )
    }

    private static func services(
        store: ProjectStore,
        session: WorkbenchSession,
        root: URL
    ) -> WorkflowServices {
        WorkflowServices(
            store: store,
            session: session,
            defaultIdentity: { $0 == .text ? Self.modelIdentity : "" },
            resolveModel: { kind, selected in
                guard kind == .text, selected == Self.modelIdentity else {
                    throw ProcessRecoveryIssue("Unexpected model resolution: \(kind.rawValue)/\(selected)")
                }
                return .init(
                    identity: Self.modelIdentity,
                    reference: .init(directory: root, revision: "process-recovery-fixture-v1"),
                    backendID: Self.backendID
                )
            }
        )
    }

    private static func hasProduceBoundary(
        _ recoveryCase: ProcessRecoveryCase,
        checkpoint: WorkflowPlanCheckpoint
    ) -> Bool {
        let language = checkpoint.records.filter { $0.step.node.operationID == "d.model.language" }
        guard language.count == 2 else { return false }
        let firstAddress = recoveryCase == .map ? "item:first" : "iteration:1"
        let secondAddress = recoveryCase == .map ? "item:second" : "iteration:2"
        return language.contains {
            $0.step.status == .completed && address($0.address).contains(firstAddress)
        } && language.contains {
            $0.step.status == .running && address($0.address).contains(secondAddress)
        }
    }

    private static func verifyProduceBoundary(
        _ recoveryCase: ProcessRecoveryCase,
        run: WorkflowRun
    ) throws {
        try check(run.status == .running, "Produce run is not durably running.")
        let checkpoint = try require(run.planCheckpoint, "Produce checkpoint is missing.")
        try check(checkpoint.state == .running, "Produce checkpoint is not running.")
        let language = checkpoint.records.filter { $0.step.node.operationID == "d.model.language" }
        try check(language.count == 2, "Produce must contain exactly two language calls.")
        let firstAddress = recoveryCase == .map ? "item:first" : "iteration:1"
        let secondAddress = recoveryCase == .map ? "item:second" : "iteration:2"
        let first = try require(language.first(where: { address($0.address).contains(firstAddress) }), "First completed call is missing.")
        let second = try require(language.first(where: { address($0.address).contains(secondAddress) }), "Second running call is missing.")
        try check(first.step.status == .completed, "First call was not durably completed.")
        try check(first.step.outputs["raw"]?.asset != nil, "First call raw text reference is missing.")
        let expected = recoveryCase == .map ? "map-first" : "1"
        try check(first.step.outputs["output"]?.datum == .text(expected), "First call output is wrong.")
        try check(second.step.status == .running, "Second call was not durably running.")
        try check(second.step.outputs.isEmpty, "Second call published output before the crash boundary.")
        if recoveryCase == .loop {
            let parent = try require(checkpoint.records.first(where: {
                $0.step.node.operationID == "d.control.loop"
            }), "Produce Loop parent record is missing.")
            try check(
                parent.step.outputs["output"]?.datum == .text("1"),
                "Produce Loop parent did not retain state 1 before the second submit."
            )
            try check(parent.loopExit == nil, "Produce Loop recorded a terminal exit before recovery.")
        }
    }

    private static func verifyHumanProduce(run: WorkflowRun) throws {
        try check(run.status == .waiting, "Human run is not waiting.")
        let checkpoint = try require(run.planCheckpoint, "Human checkpoint is missing.")
        try check(checkpoint.state == .waiting, "Human checkpoint is not waiting.")
        let source = try require(checkpoint.records.first(where: {
            $0.step.node.title == "Source language"
        }), "Completed human source is missing.")
        try check(source.step.status == .completed, "Human source is not completed.")
        try check(source.step.outputs["output"]?.datum == .text("human-source"), "Human source output changed.")
        try check(source.step.outputs["raw"]?.asset != nil, "Human source raw reference is missing.")
        let waiting = try require(checkpoint.records.first(where: {
            $0.step.node.operationID == "d.control.human"
        }), "Human waiting record is missing.")
        let task = try require(waiting.step.humanTask, "Human task is missing.")
        try check(waiting.step.status == .waiting, "Human call is not waiting.")
        try check(task.id == waiting.step.id, "Human task/step identity changed.")
        try check(
            address(waiting.address).contains("node:\(waiting.step.node.id.uuidString)"),
            "Human task address does not identify its persisted node."
        )
        try check(task.kind == .editText, "Human task kind changed.")
        try check(task.materials == .text("human-source"), "Human task materials changed.")
        try check(task.resultSchema == .text, "Human result schema changed.")
        try check(task.draft == .text("edited after source"), "Human draft was not saved.")
        try check(task.decision == nil, "Human draft became an implicit decision.")
        try check(!task.rejected, "Human draft became an implicit rejection.")
        try check(
            checkpoint.records.filter { $0.step.node.title == "Downstream language" }.isEmpty,
            "Downstream language ran before explicit resume."
        )
    }

    private static func verifyLoadedInterruption(
        _ recoveryCase: ProcessRecoveryCase,
        run: WorkflowRun
    ) throws {
        try check(run.status == .interrupted, "Cold load did not mark the run interrupted.")
        let checkpoint = try require(run.planCheckpoint, "Interrupted checkpoint is missing.")
        try check(checkpoint.state == .interrupted, "Cold load did not mark the checkpoint interrupted.")
        let firstAddress = recoveryCase == .map ? "item:first" : "iteration:1"
        let secondAddress = recoveryCase == .map ? "item:second" : "iteration:2"
        let language = checkpoint.records.filter { $0.step.node.operationID == "d.model.language" }
        let first = try require(language.first(where: { address($0.address).contains(firstAddress) }), "Loaded first call is missing.")
        let second = try require(language.first(where: { address($0.address).contains(secondAddress) }), "Loaded second call is missing.")
        try check(first.step.status == .completed, "Cold load changed the completed first call.")
        try check(first.step.outputs["raw"]?.asset != nil, "Cold load lost the first raw reference.")
        try check(second.step.status == .interrupted, "Cold load did not interrupt the in-flight call.")
        try check(second.step.outputs.isEmpty, "Cold load invented output for the in-flight call.")
    }

    private static func verifyRetainedCompletedCalls(
        produced: WorkflowRun,
        current: WorkflowRun,
        store: ProjectStore
    ) async throws {
        let producedCheckpoint = try require(produced.planCheckpoint, "Retained produce checkpoint is missing.")
        let currentCheckpoint = try require(current.planCheckpoint, "Current recovery checkpoint is missing.")
        let completed = producedCheckpoint.records.filter {
            $0.step.node.operationID == "d.model.language" && $0.step.status == .completed
        }
        try check(completed.count == 1, "Produce archive must retain exactly one completed language call.")
        for original in completed {
            let retained = try require(currentCheckpoint.records.first(where: {
                $0.step.id == original.step.id
            }), "A completed produce call disappeared after reopen.")
            try check(retained.address == original.address, "Completed call address changed after reopen.")
            try check(retained.step == original.step, "Completed call step/input/output/reference changed after reopen.")
            let raw = try require(
                original.step.outputs["raw"]?.asset,
                "Completed produce call has no retained raw asset reference."
            )
            let text = try require(
                original.step.outputs["output"]?.datum?.text,
                "Completed produce call has no retained text output."
            )
            let bytes = try await store.workflowData(raw)
            try check(bytes == Data(text.utf8), "Retained raw asset bytes do not match the completed output.")
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try check(digest == raw.sha256, "Retained raw asset digest changed after reopen.")
        }
    }

    private static func verifyRetainedHumanTask(
        produced: WorkflowRun,
        current: WorkflowRun,
        expectedDecision: WorkflowDatum?
    ) throws {
        let producedCheckpoint = try require(produced.planCheckpoint, "Retained human checkpoint is missing.")
        let currentCheckpoint = try require(current.planCheckpoint, "Current human checkpoint is missing.")
        let original = try require(producedCheckpoint.records.first(where: {
            $0.step.node.operationID == "d.control.human"
        }), "Retained produce human task is missing.")
        let retained = try require(currentCheckpoint.records.first(where: {
            $0.step.id == original.step.id
        }), "Human task identity disappeared after reopen.")
        let originalTask = try require(original.step.humanTask, "Retained produce human task data is missing.")
        let retainedTask = try require(retained.step.humanTask, "Current human task data is missing.")
        try check(retained.address == original.address, "Human task address changed after reopen.")
        try check(retained.step.id == original.step.id, "Human step identity changed after reopen.")
        try check(retainedTask.id == originalTask.id, "Human task identity changed after reopen.")
        try check(retainedTask.kind == originalTask.kind, "Human task kind changed after reopen.")
        try check(retainedTask.title == originalTask.title, "Human task title changed after reopen.")
        try check(retainedTask.materials == originalTask.materials, "Human task materials changed after reopen.")
        try check(retainedTask.resultSchema == originalTask.resultSchema, "Human task result schema changed after reopen.")
        try check(retainedTask.draft == originalTask.draft, "Human draft changed after reopen.")
        try check(retainedTask.rejected == originalTask.rejected, "Human rejection state changed after reopen.")
        try check(originalTask.decision == nil, "Produce archive contains an unexpected human decision.")
        try check(retainedTask.decision == expectedDecision, "Human decision does not match the explicit submitted value.")
        if let expectedDecision {
            try check(retained.step.status == .completed, "Explicit human decision did not complete its call.")
            try check(retained.step.outputs["output"]?.datum == expectedDecision, "Explicit human decision output changed.")
        } else {
            try check(retained.step.status == .waiting, "Undecided human task is not waiting.")
        }
    }

    private static func verifyCompleted(
        _ recoveryCase: ProcessRecoveryCase,
        run: WorkflowRun
    ) throws {
        try check(run.status == .completed, "Recovered run is not completed.")
        let checkpoint = try require(run.planCheckpoint, "Completed checkpoint is missing.")
        try check(checkpoint.state == .completed, "Recovered checkpoint is not completed.")
        switch recoveryCase {
        case .map:
            guard case .data(.list(_, let items))? = checkpoint.outputs["output"] else {
                throw ProcessRecoveryIssue("Recovered Map output is not a list.")
            }
            try check(items.map(\.id) == ["first", "second"], "Recovered Map item order changed.")
            let values = items.compactMap { item -> WorkflowDatum? in
                guard case .result(let result) = item.value else { return nil }
                return result.value
            }
            try check(values == [.text("map-first"), .text("map-second")], "Recovered Map values changed.")
        case .loop:
            try check(checkpoint.outputs["output"]?.datum == .text("2"), "Recovered Loop final state is not 2.")
            let loop = try require(checkpoint.records.first(where: {
                $0.step.node.operationID == "d.control.loop"
            }), "Recovered Loop record is missing.")
            try check(loop.step.outputs["output"]?.datum == .text("2"), "Recovered Loop parent state is not 2.")
            try check(
                loop.step.outputs["exitReason"]?.datum == .enumeration(
                    "conditionMet", choices: ["conditionMet", "iterationLimit", "failed", "cancelled"]
                ),
                "Recovered Loop parent exitReason is not conditionMet."
            )
            try check(loop.loopExit == .conditionMet, "Recovered Loop did not meet its condition.")
        case .human:
            let source = try require(checkpoint.records.first(where: {
                $0.step.node.title == "Source language"
            }), "Completed human source is missing.")
            try check(source.step.status == .completed, "Completed human source status changed.")
            try check(source.step.outputs["output"]?.datum == .text("human-source"), "Completed human source output changed.")
            try check(source.step.outputs["raw"]?.asset != nil, "Completed human source reference was lost.")
            let human = try require(checkpoint.records.first(where: {
                $0.step.node.operationID == "d.control.human"
            })?.step.humanTask, "Completed human task is missing.")
            try check(human.draft == .text("edited after source"), "Completed human draft changed.")
            try check(human.decision == .text("edited after source"), "Completed human decision changed.")
            let downstream = try require(checkpoint.records.first(where: {
                $0.step.node.title == "Downstream language"
            }), "Completed downstream call is missing.")
            try check(downstream.step.status == .completed, "Downstream call is not completed.")
            try check(downstream.step.outputs["output"]?.datum == .text("human-downstream"), "Downstream output changed.")
        }
    }

    private static func verifyLedger(
        _ recoveryCase: ProcessRecoveryCase,
        before: [ProcessRecoveryLedgerEntry],
        after: [ProcessRecoveryLedgerEntry],
        finalRun: WorkflowRun
    ) throws {
        try check(after.count == before.count + 1, "Recovery must submit exactly one inference call.")
        try check(after.dropLast() == before[...], "Recovery rewrote the existing ledger.")
        try check(after.last?.phase == .reopen, "The appended ledger call is not from reopen.")
        try check(after.last?.recoveryCase == recoveryCase, "The appended ledger call has the wrong recovery case.")
        try check(after.last?.processID == getpid(), "The appended ledger call has the wrong reopen PID.")
        try check(after.last?.ordinal == before.count + 1, "The appended ledger ordinal is not contiguous.")
        let expectedPrompts: [String]
        switch recoveryCase {
        case .map:
            expectedPrompts = [
                "Return the supplied item.\n\nContent:\nfirst input",
                "Return the supplied item.\n\nContent:\nsecond input",
                "Return the supplied item.\n\nContent:\nsecond input",
            ]
        case .loop:
            expectedPrompts = [
                "Return the next integer.\n\nContent:\n0",
                "Return the next integer.\n\nContent:\n1",
                "Return the next integer.\n\nContent:\n1",
            ]
        case .human:
            expectedPrompts = [
                "Create deterministic source text.",
                "Use the approved text.\n\nContent:\nedited after source",
            ]
        }
        try check(after.map(\.input) == expectedPrompts, "Persisted request prompts do not match the frozen call inputs.")
        let checkpoint = try require(finalRun.planCheckpoint, "Final checkpoint is missing for ledger verification.")
        let language = checkpoint.records.filter { $0.step.node.operationID == "d.model.language" }
        switch recoveryCase {
        case .map, .loop:
            try check(language.count == 2, "Final structured run must have exactly two language call records.")
            let firstAddress = recoveryCase == .map ? "item:first" : "iteration:1"
            let secondAddress = recoveryCase == .map ? "item:second" : "iteration:2"
            let first = try require(language.first(where: { address($0.address).contains(firstAddress) }), "Final first call is missing.")
            let second = try require(language.first(where: { address($0.address).contains(secondAddress) }), "Final second call is missing.")
            try check(after.filter { $0.requestID == first.step.id }.count == 1, "Completed first call was resubmitted.")
            try check(after.filter { $0.requestID == second.step.id }.count == 2, "Interrupted second call was not retried exactly once.")
        case .human:
            try check(language.count == 2, "Human run must have source and downstream language calls.")
            let source = try require(language.first(where: { $0.step.node.title == "Source language" }), "Final source call is missing.")
            let downstream = try require(language.first(where: { $0.step.node.title == "Downstream language" }), "Final downstream call is missing.")
            try check(after.filter { $0.requestID == source.step.id }.count == 1, "Completed human source was resubmitted.")
            try check(after.filter { $0.requestID == downstream.step.id }.count == 1, "Human downstream did not submit exactly once.")
        }
    }

    private static func writeProduceEvidence(
        archive: WorkflowArchive,
        engine: ProcessRecoveryEngine,
        recoveryCase: ProcessRecoveryCase,
        nonce: UUID,
        paths: RecoveryPaths,
        store: ProjectStore,
        run: WorkflowRun
    ) async throws {
        let ledger = await engine.snapshot()
        try check(ledger.count == (recoveryCase == .human ? 1 : 2), "Produce ledger submission count is wrong.")
        let diskLedger = try readLedger(paths.ledger)
        try check(diskLedger == ledger, "Durable produce ledger does not match the engine ledger.")
        try writeJSON(archive, to: paths.produceArchive)
        let marker = ProcessRecoveryReady(
            schemaVersion: 1,
            nonce: nonce,
            recoveryCase: recoveryCase,
            phase: .produce,
            processID: getpid(),
            executable: try executablePath(),
            project: paths.project.path,
            ledger: paths.ledger.path,
            projectID: await store.snapshot().id,
            runID: run.id,
            sourceRevision: sourceRevision,
            testedIdentity: testedIdentity,
            checkpoint: try summary(run)
        )
        try writeJSON(marker, to: paths.ready)
    }

    private static func waitForProduceBoundary(
        store: ProjectStore,
        engine: ProcessRecoveryEngine,
        recoveryCase: ProcessRecoveryCase,
        ledgerURL: URL
    ) async throws -> WorkflowArchive {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let engineLedger = await engine.snapshot()
            let diskLedger = try readLedger(ledgerURL)
            if engineLedger.count == 2,
               diskLedger == engineLedger,
               let archive = try await store.workflowState().archive,
               let run = archive.runs.last,
               let checkpoint = run.planCheckpoint,
               hasProduceBoundary(recoveryCase, checkpoint: checkpoint) {
                return archive
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProcessRecoveryIssue(
            "Timed out waiting for both the persisted produce boundary and exactly two fsynced submit records."
        )
    }

    private static func cleanupAfterUnexpectedError(
        controller: WorkflowController?,
        runTask: Task<Void, Never>?,
        runtime: WorkbenchSession?,
        store: ProjectStore?
    ) async {
        if let controller { await controller.cancel() }
        runTask?.cancel()
        if let runTask { await runTask.value }
        if let controller {
            if (try? await controller.close()) == nil { controller.deactivateAfterClose() }
        }
        if let runtime { await runtime.shutdown() }
        if let store { try? await store.close(preserveExternalChanges: true) }
    }

    private struct RecoveryPaths {
        let root: URL
        var project: URL { root.appendingPathComponent("process-recovery.dproject", isDirectory: true) }
        var ledger: URL { root.appendingPathComponent("ledger.jsonl") }
        var ready: URL { root.appendingPathComponent("ready.json") }
        var produceArchive: URL { root.appendingPathComponent("produce-archive.json") }
        var reopenResult: URL { root.appendingPathComponent("reopen-result.json") }
    }

    private static func paths(nonce: UUID) throws -> RecoveryPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support
            .appendingPathComponent("D/NodeLanguageAcceptance/process-recovery", isDirectory: true)
            .appendingPathComponent(nonce.uuidString, isDirectory: true)
        return RecoveryPaths(root: root)
    }

    private static func summary(_ run: WorkflowRun) throws -> ProcessRecoveryCheckpointSummary {
        let checkpoint = try require(run.planCheckpoint, "Run checkpoint is missing.")
        return ProcessRecoveryCheckpointSummary(
            state: checkpoint.state.rawValue,
            records: checkpoint.records.map { record in
                ProcessRecoveryRecordSummary(
                    stepID: record.step.id,
                    operationID: record.step.node.operationID,
                    status: record.step.status.rawValue,
                    address: address(record.address),
                    outputText: record.step.outputs["output"]?.datum?.text,
                    rawAssetID: record.step.outputs["raw"]?.asset?.assetID,
                    humanDraft: record.step.humanTask?.draft?.text,
                    humanDecision: record.step.humanTask?.decision?.text
                )
            }
        )
    }

    private static func address(_ address: WorkflowExecutionAddress) -> String {
        address.path.map { component in
            switch component {
            case .node(let id): return "node:\(id.uuidString)"
            case .branch(let selected): return "branch:\(selected)"
            case .item(let id): return "item:\(id)"
            case .iteration(let value): return "iteration:\(value)"
            case .tool(let reference): return "tool:\(reference.id.uuidString):\(reference.version):\(reference.digest)"
            }
        }.joined(separator: "/")
    }

    private static func readLedger(_ url: URL) throws -> [ProcessRecoveryLedgerEntry] {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(ProcessRecoveryLedgerEntry.self, from: Data(line.utf8))
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .withoutOverwriting)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func executablePath() throws -> String {
        guard let path = Bundle.main.executableURL?.standardizedFileURL.path else {
            throw ProcessRecoveryIssue("Test-host executable path is unavailable.")
        }
        return path
    }

    private static func required(
        _ key: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw ProcessRecoveryIssue("Missing required environment variable: \(key)")
        }
        return value
    }

    private static func requiredEnum<T: RawRepresentable>(
        _ type: T.Type,
        key: String,
        environment: [String: String]
    ) throws -> T where T.RawValue == String {
        let value = try required(key, environment: environment)
        guard let result = T(rawValue: value) else {
            throw ProcessRecoveryIssue("Invalid \(key): \(value)")
        }
        return result
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        guard condition() else { throw ProcessRecoveryIssue(reason) }
    }

    private static func require<T>(_ value: T?, _ reason: String) throws -> T {
        guard let value else { throw ProcessRecoveryIssue(reason) }
        return value
    }
}

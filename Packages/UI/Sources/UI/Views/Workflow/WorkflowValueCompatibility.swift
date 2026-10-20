import DWorkbench
import Foundation

struct WorkflowConsumerMatch: Identifiable {
    var id: String { key ?? (operationID + ":" + port) }
    var key: String? = nil
    let operationID: String
    let title: String
    let port: String
    let portTitle: String
    let modelKind: WorkflowModelKind?
    let result: WorkflowInputCompatibilityResult
}
@MainActor enum WorkflowValueCompatibility {
    // Immutable registered contracts. Mutable instance schemas are evaluated separately.
    private static let contracts: [(WorkflowOperationDefinition, WorkflowInputContract)] = WorkflowRegistry.standard.definitions.flatMap { definition in
        let node = definition.makeNode()
        return definition.inputs.compactMap { port in
            (try? WorkflowInputContract(step: .init(node: node, inputs: []), portID: port.id)).map { (definition, $0) }
        }
    }
    static func consumers(_ value: WorkflowValue, decodedAsset: WorkflowDatum? = nil, language: UILanguageStore?) -> [WorkflowConsumerMatch] {
        contracts.compactMap { definition, contract in
            let result = contract.compatibility(with: value, decodedAsset: decodedAsset)
            guard contract.port.kinds.contains(value.kind) || result.status == .conversion else { return nil }
            return .init(operationID: definition.id, title: WorkflowCanvasPresentation.operationTitle(definition, language: language),
                port: contract.port.id, portTitle: WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: contract.port, input: true, language: language),
                modelKind: definition.modelKind, result: result)
        }
    }
    /// Decoding a file for display never grants it an inline-record identity or registers a version.
    static func registeredAssetConsumers(_ reference: WorkflowAssetReference?, decoded: WorkflowDatum,
        plans: [WorkflowPlan], tools: [WorkflowToolDefinition], language: UILanguageStore?) -> [WorkflowConsumerMatch] {
        guard let reference else { return [] }
        return concreteConsumers(.asset(reference), decodedAsset: decoded, plans: plans, tools: tools, language: language)
            + consumers(.asset(reference), decodedAsset: decoded, language: language)
    }
    static func concreteConsumers(_ value: WorkflowValue, decodedAsset: WorkflowDatum? = nil, plans: [WorkflowPlan], tools: [WorkflowToolDefinition], language: UILanguageStore?) -> [WorkflowConsumerMatch] {
        var result: [WorkflowConsumerMatch] = []
        var seen = Set<String>()
        func visit(_ plan: WorkflowPlan, path: String) {
            for step in plan.steps {
                let key = path + ":" + step.id.uuidString
                let definition = WorkflowRegistry.standard.definition(for: step.node, tools: tools)
                let ports: [String]
                if case .invoke(_, let body) = step.kind { ports = body.interface.inputs.map(\.name) }
                else { ports = definition?.inputs.map(\.id) ?? [] }
                for port in ports {
                    guard seen.insert(key + ":" + port).inserted,
                          let contract = try? WorkflowInputContract(step: step, portID: port, tools: tools) else { continue }
                    let match = contract.compatibility(with: value, decodedAsset: decodedAsset)
                    result.append(.init(key: key + ":" + port, operationID: step.node.operationID,
                        title: step.node.title + " · 已保存配置", port: port, portTitle: contract.port.title,
                        modelKind: definition?.modelKind, result: match))
                }
                switch step.kind {
                case .call: break
                case .branch(_, let yes, let no): visit(yes, path: key + ":yes"); visit(no, path: key + ":no")
                case .map(let body, _), .loop(let body, _, _, _), .invoke(_, let body): visit(body, path: key)
                }
            }
        }
        for plan in plans { visit(plan, path: plan.graphID.uuidString + ":" + plan.graphRevision.uuidString) }
        return result
    }
    // Bounded by the bundle's finite kind/definition registry; immutable for this App lifetime.
    // These are candidates, not compatibility verdicts. Opening a value performs real validation.
    private static let candidateReceivers: [WorkflowDataKind: Set<String>] = Dictionary(uniqueKeysWithValues:
        WorkflowDataKind.allCases.map { kind in
            (kind, Set(WorkflowRegistry.standard.definitions.filter { $0.inputs.contains { $0.kinds.contains(kind) } }.map(\.id)))
        })
    static func facts(_ value: WorkflowValue, producer: String?, format: String? = nil) -> SharedLibraryFactConditions {
        let concept = value.datum.flatMap(WorkflowInputContract.concept)
        // A candidate receiver remains explicitly conditional; the detail always
        // evaluates its actual contract and never treats a user tag as capability.
        let receivers = candidateReceivers[value.kind] ?? []
        return .init(concepts: concept.map { [$0] } ?? [], producers: producer.map { [$0] } ?? [],
            consumers: receivers, formats: format.map { [$0] } ?? [])
    }
}

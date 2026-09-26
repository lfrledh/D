import Foundation

/// Bind selected implementations into a compiled copy, preserving tool definition digests.
/// Only empty modelID fields are filled. No weight access or model lease occurs here.
public enum WorkflowPlanBinding {
    public static func freeze(_ source: WorkflowPlan, defaults: [String: String], registry: WorkflowRegistry = .standard) throws -> WorkflowPlan {
        guard Set(defaults.keys).isSubset(of: Set(WorkflowModelKind.allCases.map(\.rawValue))),
              defaults.values.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else { throw WorkflowIssue("模型默认身份无效。") }
        var result = source
        for i in result.steps.indices {
            if let kind = registry.operation(result.steps[i].node.operationID)?.definition.modelKind,
               result.steps[i].node.parameters["modelID"]?.string == "" {
                result.steps[i].node.parameters["modelID"] = .text(defaults[kind.rawValue] ?? "")
            }
            switch result.steps[i].kind {
            case .call: break
            case .branch(let predicate, let yes, let no):
                result.steps[i].kind = .branch(predicate: predicate, then: try freeze(yes, defaults: defaults, registry: registry), otherwise: try freeze(no, defaults: defaults, registry: registry))
            case .map(let body, let keepGoing): result.steps[i].kind = .map(body: try freeze(body, defaults: defaults, registry: registry), continueOnFailure: keepGoing)
            case .loop(let body, let schema, let limit, let until): result.steps[i].kind = .loop(body: try freeze(body, defaults: defaults, registry: registry), stateSchema: schema, maximumIterations: limit, until: until)
            case .invoke(let reference, let body): result.steps[i].kind = .invoke(reference: reference, body: try freeze(body, defaults: defaults, registry: registry))
            }
        }
        return result
    }
}

import DWorkbench
import Foundation

/// Read-only facts come from registered operations and exact model identities. User tags do not enter this projection.
@MainActor enum SharedLibraryProjection {
    static func operation(_ kind: WorkflowModelKind) -> String {
        switch kind { case .text: "d.model.language"; case .image: "d.image.generate"; case .music: "d.music.generate"; case .video: "d.video.generate"; case .pitch: "d.music.pitch" }
    }
    static func modelKind(_ descriptor: ModelNodeDescriptor) -> WorkflowModelKind? {
        if TextModelProfilesIdentity.contains(descriptor.modelIdentity) { return .text }
        switch descriptor.id {
        case "flux2-klein-4b-q8": return .image
        case "mrt2-small-export-v1": return .music
        case "wan21-t2v-1.3b-bf16-v1": return .video
        case "swift-f0-0.1.2-cpu-v1": return .pitch
        default: return nil
        }
    }
    private static var TextModelProfilesIdentity: Set<String> { Set(((try? TextModelProfiles.registered()) ?? []).map(\.id)) }
    static func descriptor(for choice: WorkflowModelChoice) -> ModelNodeDescriptor? {
        ModelNodeCatalog.entries.first { modelKind($0) == choice.kind && choice.id == choice.kind.rawValue + ":" + $0.revision }
    }
    static func modelKey(_ choice: WorkflowModelChoice) -> String { descriptor(for: choice)?.id ?? "model:" + choice.id }
    static func outputs(_ definition: WorkflowOperationDefinition) -> Set<WorkflowDataKind> {
        // Generic value ports express a future binding, not every concrete media capability.
        if definition.id == "d.model.language" { return [.text] }
        return Set(definition.outputs.flatMap { $0.kinds.count == WorkflowDataKind.allCases.count ? [] : $0.kinds })
    }
    static func entries(models: [WorkflowModelChoice], readiness: [String: SharedLibraryReadiness],
                        tools: [WorkflowToolDefinition], projects: [ProjectManifest], language: UILanguageStore?) -> [SharedLibraryBrowserEntry] {
        let registry = WorkflowRegistry.standard
        var result: [SharedLibraryBrowserEntry] = []
        var identities = Set<String>()
        for choice in models where identities.insert(choice.id).inserted {
            guard let definition = registry.operation(operation(choice.kind))?.definition else { continue }
            let descriptor = descriptor(for: choice)
            result.append(.init(item: .init(key: modelKey(choice), title: descriptor?.title ?? choice.displayName,
                detail: WorkflowCanvasPresentation.operationTitle(definition, language: language), kind: .model, role: "primary-model",
                inputs: Set(definition.inputs.flatMap(\.kinds)), outputs: outputs(definition), readiness: readiness[choice.id] ?? .unknown),
                selection: .operation(id: definition.id, modelID: choice.id),
                facts: [choice.id, descriptor?.precision ?? "", descriptor?.engine ?? "", "执行前重新核验模型与请求"].filter { !$0.isEmpty }))
        }
        for descriptor in ModelNodeCatalog.entries {
            guard !result.contains(where: { $0.item.key == descriptor.id }) else { continue }
            if let kind = modelKind(descriptor), let definition = registry.operation(operation(kind))?.definition {
                let identity = kind.rawValue + ":" + descriptor.revision
                result.append(.init(item: .init(key: descriptor.id, title: descriptor.title,
                    detail: WorkflowCanvasPresentation.operationTitle(definition, language: language), kind: .model, role: "primary-model",
                    inputs: Set(definition.inputs.flatMap(\.kinds)), outputs: outputs(definition), readiness: .unprepared),
                    selection: .operation(id: definition.id, modelID: identity), facts: [descriptor.modelIdentity, descriptor.revision, descriptor.precision, descriptor.deploymentNote]))
            } else {
                result.append(.init(item: .init(key: descriptor.id, title: descriptor.title, detail: descriptor.deploymentNote,
                    kind: .model, role: "separate-entry", readiness: .unsupported),
                    selection: .unavailable("此适配尚未提供快速/通用节点操作；原有编辑器与CLI责任保留。"),
                    facts: [descriptor.modelIdentity, descriptor.revision, descriptor.engine]))
            }
        }
        for definition in registry.definitions where definition.modelKind == nil {
            result.append(.init(item: .init(key: "operation:" + definition.id,
                title: WorkflowCanvasPresentation.operationTitle(definition, language: language),
                detail: WorkflowCanvasPresentation.operationDetail(definition, language: language), kind: .program, role: "program",
                inputs: Set(definition.inputs.flatMap { $0.kinds.count == WorkflowDataKind.allCases.count ? [] : $0.kinds }),
                outputs: outputs(definition), readiness: .available), selection: .operation(id: definition.id, modelID: nil),
                facts: [definition.id, "v\(definition.version)"]))
        }
        for tool in tools {
            guard let digest = try? WorkflowPlanCompiler.digest(tool) else { continue }
            let ref = WorkflowToolReference(id: tool.id, version: tool.version, digest: digest)
            result.append(.init(item: .init(key: "tool:" + tool.id.uuidString + ":\(tool.version):" + digest,
                title: tool.name, detail: "v\(tool.version)", kind: .tool, role: "workflow-tool",
                inputs: Set(tool.graph.interface?.inputs.flatMap { $0.type.portKinds } ?? []),
                outputs: Set(tool.graph.interface?.outputs.flatMap { $0.schema.portKinds } ?? []), readiness: .available), selection: .tool(ref),
                facts: ["端口来自此版本公开接口", digest]))
        }
        for project in projects {
            for asset in project.assets {
                let kind = asset.workflowContentKind
                result.append(.init(item: .init(key: "asset:" + project.id.uuidString + ":" + asset.id.uuidString,
                    title: asset.name, detail: project.name, kind: .asset, role: asset.role.rawValue,
                    contentKind: kind, readiness: .unknown), selection: .asset(projectID: project.id, assetID: asset.id),
                    facts: [asset.mediaType, "访问时核验所属项目、文件与摘要；不改变原件"]))
            }
        }
        return result
    }
}

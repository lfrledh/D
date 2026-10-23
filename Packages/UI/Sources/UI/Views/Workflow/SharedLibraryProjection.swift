import DWorkbench
import DInference
import Foundation

/// Read-only facts come from registered operations and exact model identities. User tags do not enter this projection.
@MainActor enum SharedLibraryProjection {
    static func resolvedInstanceID(projectID: UUID, instanceID: UUID?, projects: [ProjectManifest]) -> UUID? {
        let matches = projects.filter { $0.id == projectID }
        if let instanceID { return matches.first(where: { $0.effectiveInstanceID == instanceID })?.effectiveInstanceID }
        let distinct = Set(matches.map(\.effectiveInstanceID))
        return distinct.count == 1 ? distinct.first : nil
    }
    static func operation(_ kind: WorkflowModelKind) -> String {
        switch kind { case .text: "d.model.language"; case .image: "d.image.generate"; case .music: "d.music.generate"; case .video: "d.video.generate"; case .pitch: "d.music.pitch" }
    }
    static func modelKind(_ descriptor: ModelNodeDescriptor) -> WorkflowModelKind? {
        if externalProfile(descriptor) != nil { return .video }
        if TextModelProfilesIdentity.contains(descriptor.modelIdentity) { return .text }
        switch descriptor.id {
        case "flux2-klein-4b-q8", "flux2-klein-4b-bf16", "flux2-dev-bf16": return .image
        case "mrt2-small-export-v1", "ace-step-1.5-xl-sft-f32-no-lm": return .music
        case "wan21-t2v-1.3b-bf16-v1": return .video
        case "swift-f0-0.1.2-cpu-v1": return .pitch
        default: return nil
        }
    }
    // These are immutable identities from this App bundle, not installed-model
    // readiness. Re-reading their manifests for every descriptor on every draft
    // edit stalls the main thread; live installation state still comes from inputs.
    private static let TextModelProfilesIdentity: Set<String> = Set(
        (((try? TextModelProfiles.registered()) ?? []) + ((try? TextModelProfiles.registeredVLM()) ?? [])).map(\.id))
    private static func externalProfile(_ descriptor: ModelNodeDescriptor) -> ExternalVideoExecutionProfile? {
        ExternalVideoExecutionProfile.allCases.first { descriptor.id == "video.model." + $0.rawValue }
    }
    private static func identity(_ descriptor: ModelNodeDescriptor, kind: WorkflowModelKind) -> String {
        kind.rawValue + ":" + (externalProfile(descriptor)?.modelIdentity ?? descriptor.revision)
    }
    // The bundle's descriptive routes are immutable. Keep this UI-only snapshot
    // separate from live readiness and the executor's validation/admission.
    private static let bundledOperations: [String: String] = Dictionary(
        ModelNodeCatalog.entries.compactMap { descriptor in
            guard let kind = modelKind(descriptor) else { return nil }
            let choice = WorkflowModelChoice(id: identity(descriptor, kind: kind), kind: kind, displayName: descriptor.title)
            return (kind.rawValue + ":" + choice.id, uncachedOperation(choice))
        }, uniquingKeysWith: { first, _ in first })
    private static let bundledDescriptorOperations: [String: String] = Dictionary(
        ModelNodeCatalog.entries.compactMap { descriptor in
            guard let kind = modelKind(descriptor) else { return nil }
            let choice = WorkflowModelChoice(id: identity(descriptor, kind: kind), kind: kind, displayName: descriptor.title)
            return (descriptor.id, externalProfile(descriptor).map { WorkflowVideoRecipe(profile: $0).operationID } ?? WorkflowModelRoutes.operation(for: choice) ?? operation(kind))
        }, uniquingKeysWith: { first, _ in first })
    private static func operation(_ choice: WorkflowModelChoice) -> String {
        bundledOperations[choice.kind.rawValue + ":" + choice.id] ?? uncachedOperation(choice)
    }
    private static func uncachedOperation(_ choice: WorkflowModelChoice) -> String {
        if let exact = WorkflowModelRoutes.operation(for: choice) { return exact }
        if choice.kind == .video, let profile = ExternalVideoExecutionProfile.allCases.first(where: { choice.id == "video:" + $0.modelIdentity }) {
            return WorkflowVideoRecipe(profile: profile).operationID
        }
        return operation(choice.kind)
    }
    static func descriptor(for choice: WorkflowModelChoice) -> ModelNodeDescriptor? {
        ModelNodeCatalog.entries.first { modelKind($0) == choice.kind && choice.id == identity($0, kind: choice.kind) }
    }
    static func modelKey(_ choice: WorkflowModelChoice) -> String { descriptor(for: choice)?.id ?? "model:" + choice.id }
    static func outputs(_ definition: WorkflowOperationDefinition) -> Set<WorkflowDataKind> {
        // Generic value ports express a future binding, not every concrete media capability.
        if WorkflowModelRoutes.isLanguage(definition.id) { return [.text, .number, .boolean, .enumeration, .record, .list, .optional] }
        return Set(definition.outputs.flatMap { $0.kinds.count == WorkflowDataKind.allCases.count ? [] : $0.kinds })
    }
    static func entries(models: [WorkflowModelChoice], readiness: [String: SharedLibraryReadiness],
                        tools: [WorkflowToolDefinition], projects: [ProjectManifest], language: UILanguageStore?, metadata: [String: ProjectAssetMetadataSnapshot] = [:]) -> [SharedLibraryBrowserEntry] {
        let registry = WorkflowRegistry.standard
        var result: [SharedLibraryBrowserEntry] = []
        var identities = Set<String>()
        for choice in models where identities.insert(choice.id).inserted {
            guard let definition = registry.operation(operation(choice))?.definition else { continue }
            let descriptor = descriptor(for: choice)
            result.append(.init(item: .init(key: modelKey(choice), title: descriptor?.title ?? choice.displayName,
                detail: WorkflowCanvasPresentation.operationTitle(definition, language: language), kind: .model, role: "primary-model",
                inputs: Set(definition.inputs.flatMap(\.kinds)), outputs: outputs(definition), readiness: readiness[choice.id] ?? .unknown, facts: .init(concepts: [definition.title], producers: descriptor.map { [$0.modelIdentity] } ?? [])),
                selection: .operation(id: definition.id, modelID: choice.id),
                facts: [choice.id, descriptor?.precision ?? "", descriptor?.engine ?? "", consistencyText(language, "copy.verifyBeforeRun")].filter { !$0.isEmpty }))
        }
        for descriptor in ModelNodeCatalog.entries {
            guard !result.contains(where: { $0.item.key == descriptor.id }) else { continue }
            if let kind = modelKind(descriptor), let route = bundledDescriptorOperations[descriptor.id], let definition = registry.operation(route)?.definition {
                let identity = identity(descriptor, kind: kind)
                result.append(.init(item: .init(key: descriptor.id, title: descriptor.title,
                    detail: WorkflowCanvasPresentation.operationTitle(definition, language: language), kind: .model, role: "primary-model",
                    inputs: Set(definition.inputs.flatMap(\.kinds)), outputs: outputs(definition), readiness: .unprepared, facts: .init(concepts: [definition.title], producers: [descriptor.modelIdentity])),
                    selection: .operation(id: definition.id, modelID: identity), facts: [descriptor.modelIdentity, descriptor.revision, descriptor.precision, descriptor.deploymentNote]))
            } else {
                // Reviewed legacy adapters remain discoverable without claiming a new executable node route.
                let legacyAudio = ["sm-music", "sm-sfx", "medium"].contains(descriptor.id)
                let singing = descriptor.id == "audio.singing.qixuan"
                result.append(.init(item: .init(key: descriptor.id, title: descriptor.title, detail: consistencyText(language, "copy.separateAdapter"),
                    kind: .model, role: "separate-entry", inputs: legacyAudio ? [.text, .audio] : (singing ? [.record] : []),
                    outputs: legacyAudio || singing ? [.audio] : [], readiness: .unsupported),
                    selection: .unavailable(consistencyText(language, "copy.separateAdapter")),
                    facts: [descriptor.modelIdentity, descriptor.revision, descriptor.engine]))
            }
        }
        for definition in registry.definitions where definition.modelKind == nil {
            result.append(.init(item: .init(key: "operation:" + definition.id,
                title: WorkflowCanvasPresentation.operationTitle(definition, language: language),
                detail: WorkflowCanvasPresentation.operationDetail(definition, language: language), kind: .program, role: "program",
                inputs: Set(definition.inputs.flatMap { $0.kinds.count == WorkflowDataKind.allCases.count ? [] : $0.kinds }),
                outputs: outputs(definition), readiness: .available, facts: .init(concepts: [definition.title], producers: [definition.id])), selection: .operation(id: definition.id, modelID: nil),
                facts: [definition.id, "v\(definition.version)"]))
        }
        for tool in tools {
            guard let digest = try? WorkflowPlanCompiler.digest(tool) else { continue }
            let ref = WorkflowToolReference(id: tool.id, version: tool.version, digest: digest)
            result.append(.init(item: .init(key: "tool:" + tool.id.uuidString + ":\(tool.version):" + digest,
                title: tool.name, detail: "v\(tool.version)", kind: .tool, role: "workflow-tool",
                inputs: Set(tool.graph.interface?.inputs.flatMap { $0.type.portKinds } ?? []),
                outputs: Set(tool.graph.interface?.outputs.flatMap { $0.schema.portKinds } ?? []), readiness: .available), selection: .tool(ref),
                facts: [consistencyText(language, "copy.portsFromVersion"), digest]))
        }
        for project in projects {
            for asset in project.assets {
                let kind = asset.workflowContentKind
                let activityID = "asset-instance:" + project.effectiveInstanceID.uuidString + ":" + asset.id.uuidString
                let snapshot = metadata[activityID] ?? ProjectAssetMetadataSnapshot(project: project, asset: asset, record: nil,
                    job: nil, occurrences: nil, sourceIssue: "Source index unavailable / 来源尚未索引。")
                let receivers = Set(registry.definitions.filter { definition in
                    guard let kind else { return false }
                    return definition.inputs.contains { $0.kinds.contains(kind) }
                }.map(\.id))
                let concepts: Set<String> = kind.map { ["content." + $0.rawValue] } ?? []
                let facts = SharedLibraryFactConditions(concepts: concepts, producers: snapshot.record.map { [$0.operationID] } ?? [], consumers: receivers, formats: [asset.mediaType])
                result.append(.init(item: .init(key: "asset:" + project.id.uuidString + ":" + asset.id.uuidString,
                    title: asset.name, detail: project.name, kind: .asset, role: asset.role.rawValue,
                    contentKind: kind, readiness: .unknown, assetFacts: snapshot.facts,
                    facts: facts), selection: .assetInstance(projectID: project.id,
                        instanceID: project.effectiveInstanceID, assetID: asset.id),
                    facts: [asset.mediaType, consistencyText(language, "copy.verifyAssetAccess")],
                    activityID: activityID, legacyTags: asset.tags, metadataSnapshot: snapshot))
            }
        }
        return result
    }
}

/// One bounded snapshot per workbench. Navigation and canvas geometry are not
/// inputs; every mutable source fact remains part of equality. No command,
/// permission, model lease or selected runtime result is cached here.
@MainActor final class SharedLibraryProjectionCache {
    private struct Input: Equatable {
        let models: [WorkflowModelChoice]
        let readiness: [String: SharedLibraryReadiness]
        let tools: [WorkflowToolDefinition]
        let projects: [ProjectManifest]
        let metadata: [String: ProjectAssetMetadataSnapshot]
        let languageOwner: ObjectIdentifier?
        let locale: String?
        let languageRevision: UInt64?
    }
    private var input: Input?
    private var base: [SharedLibraryBrowserEntry] = []
    private var legacy: [ModelNodeTagReadState] = []
    private var result: [SharedLibraryBrowserEntry] = []
    private struct Filter: Hashable { let mode: WorkflowCanvasLibraryMode?; let family: QuickCategory? }
    private var selections: [Filter: [SharedLibraryBrowserEntry]] = [:]
    private(set) var projectionCount = 0
    func entries(models: [WorkflowModelChoice], readiness: [String: SharedLibraryReadiness],
                 tools: [WorkflowToolDefinition], projects: [ProjectManifest], language: UILanguageStore?,
                 metadata: [String: ProjectAssetMetadataSnapshot], tags: ModelNodeTagStore) -> [SharedLibraryBrowserEntry] {
        let next = Input(models: models, readiness: readiness, tools: tools, projects: projects,
            metadata: metadata, languageOwner: language.map(ObjectIdentifier.init),
            locale: language?.effectiveLanguageIdentifier, languageRevision: language?.presentationRevision)
        let changed = input != next
        if changed {
            base = SharedLibraryProjection.entries(models: models, readiness: readiness, tools: tools,
                projects: projects, language: language, metadata: metadata)
            input = next; projectionCount += 1
        }
        // Legacy preferences are not Observable: read them on every presentation
        // update, including a same-ID store replacement or corruption/recovery.
        let states = base.filter { $0.item.kind == .model || $0.item.kind == .program }.map { tags.readState(for: $0.item.key) }
        if changed || states != legacy {
            var index = 0
            result = base.map { entry in
                guard entry.item.kind == .model || entry.item.kind == .program else { return entry }
                var value = entry
                let state = SharedLibraryTagTarget.legacy(states[index]); index += 1
                value.legacyTags = state.names; value.legacyFailure = state.failure
                return value
            }
            legacy = states; selections.removeAll(keepingCapacity: true)
        }
        return result
    }
    func selection(canvasMode: WorkflowCanvasLibraryMode?, family: QuickCategory?) -> [SharedLibraryBrowserEntry] {
        let key = Filter(mode: canvasMode, family: family)
        if let current = selections[key] { return current }
        let current = result.filter { value in
            if let canvasMode {
                if let category = canvasMode.resourceCategory { return value.item.kind == .asset && category.contains(value.item.contentKind) }
                let matches = canvasMode == .nodes ? value.item.kind == .model || value.item.kind == .component : value.item.kind == .program || value.item.kind == .tool
                guard matches else { return false }
                if family == nil { return true }
            }
            guard let family else { return true }
            guard case .operation(let operation, _) = value.selection else { return false }
            return QuickCategory.category(for: operation) == family
        }
        selections[key] = current
        return current
    }
}

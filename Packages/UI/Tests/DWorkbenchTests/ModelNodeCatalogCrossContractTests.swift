import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Model node catalog cross-contract checks")
struct ModelNodeCatalogCrossContractTests {
    @Test func textProjectionUsesRegisteredIdentityAndTypedLegacyDefaults() throws {
        let settings = TextGenerationSettings.legacy
        let capability = TextExecutionCapability(
            maximumPromptTokens: settings.maximumPromptTokens,
            maximumOutputTokens: settings.maximumOutputTokens)
        let profiles = try TextModelProfiles.registered()

        for profile in profiles {
            let node = try catalogNode(profile.id)
            #expect(textMismatches(node, profile: profile, settings: settings, capability: capability).isEmpty)
        }
    }

    @Test func imageProjectionUsesFixedCatalogAndThreeTypedCapabilities() throws {
        let source = try ModelCatalog.flux2()
        let node = try catalogNode(ModelCatalog.flux2ID)
        let capabilities: [ImageExecutionCapability] = [.verified512, .scalableKlein4B, .referenceKlein4B]

        #expect(source.imageProfile.width == ImageExecutionCapability.verified512.minimumWidth)
        #expect(source.imageProfile.height == ImageExecutionCapability.verified512.minimumHeight)
        #expect(source.imageProfile.steps == ImageExecutionCapability.verified512.steps)
        #expect(source.imageProfile.maximumPromptTokens == ImageExecutionCapability.verified512.maximumTextTokens)
        #expect(imageMismatches(node, source: source, capabilities: capabilities).isEmpty)
    }

    @Test func audioProjectionUsesFixedJSONIdentityAndTypedRequestShapes() throws {
        let source = try fixedModelSource("Backends/Audio/Models/sm-music.json")
        let node = try catalogNode("sm-music")
        let reference = AudioSourceReference(
            url: URL(fileURLWithPath: "/fixture.wav"),
            sha256: String(repeating: "a", count: 64),
            frameCount: 264_600,
            sampleRate: 44_100,
            channels: 2)
        let defaultRequest = try AudioCreationDraft(prompt: "fixture").makeRequest(source: nil)
        let shapeRequests = [
            defaultRequest,
            AudioRequest(operation: .variation, prompt: "fixture", durationSeconds: 6,
                         seed: 7, steps: 3, strength: 0.5, source: reference),
            AudioRequest(operation: .inpaint, prompt: "fixture", durationSeconds: 6,
                         seed: 9, steps: 5, strength: 0.5, source: reference,
                         editRegion: AudioEditRegion(startFrame: 44_100, endFrame: 88_200))
        ]
        for request in shapeRequests { try request.validate() }

        #expect(source.schemaVersion == 1)
        #expect(source.profile == nil)
        #expect(node.modelIdentity == "\(source.repository) / \(node.id)")
        #expect(node.revision == source.revision)
        #expect(audioShapeMismatches(node, requests: shapeRequests).isEmpty)
        #expect(audioDefaultMismatches(node, defaultRequest: defaultRequest).isEmpty)

        let defaults = try #require(defaultRequest.diffusion)
        let driftedDefault = AudioRequest(
            operation: .generate, prompt: defaultRequest.prompt,
            durationSeconds: defaultRequest.durationSeconds, seed: defaultRequest.seed + 1,
            steps: defaults.steps + 1, guidanceScale: defaults.guidanceScale,
            strength: defaults.strength)
        let driftMismatches = audioDefaultMismatches(node, defaultRequest: driftedDefault)
        #expect(driftMismatches.contains("audio default seed"))
        #expect(driftMismatches.contains("audio default steps"))
    }

    @Test func videoProjectionUsesFixedJSONAndTypedDraftCapability() throws {
        let source = try fixedModelSource("Backends/Video/Models/wan21.json")
        let node = try catalogNode("wan21-t2v-1.3b-bf16-v1")
        let capability = VideoExecutionCapability.wan21
        let draft = VideoCreationDraft(prompt: "fixture")
        let request = try draft.makeRequest(capability: capability)

        #expect(source.schemaVersion == 1)
        #expect(source.profile == capability.profile.identifier)
        #expect(node.modelIdentity == source.repository)
        #expect(node.revision == source.revision)
        #expect(request.executionProfile == capability.profile)
        #expect(videoMismatches(node, draft: draft, request: request, capability: capability).isEmpty)
    }

    @Test func sameImageComparisonRejectsControlledCatalogDrift() throws {
        let source = try ModelCatalog.flux2()
        let capabilities: [ImageExecutionCapability] = [.verified512, .scalableKlein4B, .referenceKlein4B]
        let altered = try imageProjectionWithControlledDrift(try catalogNode(ModelCatalog.flux2ID))
        let mismatches = imageMismatches(altered, source: source, capabilities: capabilities)

        #expect(mismatches.contains("model revision"))
        #expect(mismatches.contains("verified512/1 prompt requirement"))
        #expect(mismatches.contains("verified512/1 steps default"))
    }
}

private struct FixedModelSource: Decodable {
    let schemaVersion: Int
    let repository: String
    let revision: String
    let profile: String?
}

private enum FixedSourceReadError: LocalizedError {
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path): "Missing fixed model source JSON: \(path)"
        }
    }
}

private func catalogNode(_ id: String) throws -> ModelNodeDescriptor {
    try #require(ModelNodeCatalog.entries.first { $0.id == id }, "Missing catalog node \(id)")
}

private func operation(_ id: String, in node: ModelNodeDescriptor) -> ModelNodeOperation? {
    node.operations.first { $0.id == id }
}

private func fixedModelSource(_ relativePath: String) throws -> FixedModelSource {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let url = root.appendingPathComponent(relativePath, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw FixedSourceReadError.missingFile(url.path)
    }
    return try JSONDecoder().decode(FixedModelSource.self, from: Data(contentsOf: url))
}

private func textMismatches(_ node: ModelNodeDescriptor, profile: TextModelProfile,
                            settings: TextGenerationSettings,
                            capability: TextExecutionCapability) -> [String] {
    var mismatches: [String] = []
    if node.id != profile.id { mismatches.append("model identity") }
    if node.revision != profile.revision { mismatches.append("model revision") }
    if settings.profile != capability.profile { mismatches.append("execution profile") }

    let operationID = "\(capability.contract.operationID)/\(capability.contract.revision)"
    guard let generation = operation(operationID, in: node) else {
        return mismatches + ["operation \(operationID)"]
    }
    if generation.inputs.map(\.id) != ["prompt"] { mismatches.append("text inputs") }
    if generation.inputs.first?.requirement != .required { mismatches.append("prompt requirement") }
    if generation.outputs.map(\.id) != ["textDelta"] { mismatches.append("text output") }
    if generation.outputs.first?.requirement != .required { mismatches.append("text output requirement") }
    if capability.contract.inputRoles != [.prompt] { mismatches.append("typed text input roles") }
    if capability.contract.outputRole != .text { mismatches.append("typed text output role") }
    if generation.parameters.first(where: { $0.id == "maximumPromptTokens" })?.defaultValue
        != String(settings.maximumPromptTokens) {
        mismatches.append("maximumPromptTokens default")
    }
    if generation.parameters.first(where: { $0.id == "maximumOutputTokens" })?.defaultValue
        != String(settings.maximumOutputTokens) {
        mismatches.append("maximumOutputTokens default")
    }
    return mismatches
}

private func imageMismatches(_ node: ModelNodeDescriptor, source: ModelCatalogEntry,
                             capabilities: [ImageExecutionCapability]) -> [String] {
    var mismatches: [String] = []
    if node.id != source.id { mismatches.append("model identity") }
    if node.modelIdentity != source.repository { mismatches.append("model repository") }
    if node.revision != source.revision { mismatches.append("model revision") }

    for capability in capabilities {
        let operationID = "\(capability.profile.identifier)/\(capability.profile.revision)"
        guard let projected = operation(operationID, in: node) else {
            mismatches.append("operation \(operationID)")
            continue
        }
        let expectedInputs = capability.contract.inputRoles.map {
            switch $0 {
            case .prompt: "prompt"
            case .image: "referenceImage"
            default: "unsupported:\($0.rawValue)"
            }
        }
        if projected.inputs.map(\.id) != expectedInputs { mismatches.append("\(operationID) inputs") }
        if projected.inputs.contains(where: { $0.requirement != .required }) {
            mismatches.append("\(operationID) prompt requirement")
        }
        if projected.outputs.map(\.id) != ["png"] || capability.contract.outputRole != .image {
            mismatches.append("\(operationID) output")
        }
        if projected.outputs.first?.requirement != .required {
            mismatches.append("\(operationID) output requirement")
        }
        if projected.parameters.first(where: { $0.id == "steps" })?.defaultValue
            != String(capability.steps) {
            mismatches.append("\(operationID) steps default")
        }
        if projected.parameters.first(where: { $0.id == "conditioningLength" })?.defaultValue
            != String(capability.maximumTextTokens) {
            mismatches.append("\(operationID) conditioning default")
        }
        if projected.parameters.first(where: { $0.id == "width" })?.defaultValue
            != String(source.imageProfile.width) {
            mismatches.append("\(operationID) width default")
        }
        if projected.parameters.first(where: { $0.id == "height" })?.defaultValue
            != String(source.imageProfile.height) {
            mismatches.append("\(operationID) height default")
        }
    }
    return mismatches
}

private func audioShapeMismatches(_ node: ModelNodeDescriptor, requests: [AudioRequest]) -> [String] {
    var mismatches: [String] = []
    for request in requests {
        let operationID = "audio.sa3.diffusion.\(request.operation.rawValue)"
        guard let projected = operation(operationID, in: node) else {
            mismatches.append("operation \(operationID)")
            continue
        }
        var expectedInputs = ["prompt"]
        if request.source != nil { expectedInputs.append("referenceAudio") }
        if request.editRegion != nil { expectedInputs.append("editRegion") }
        if projected.inputs.map(\.id) != expectedInputs { mismatches.append("\(operationID) inputs") }
        if projected.inputs.contains(where: { $0.requirement != .required }) {
            mismatches.append("\(operationID) input requirement")
        }
        if projected.outputs.map(\.id) != ["audio"] || projected.outputs.first?.requirement != .required {
            mismatches.append("\(operationID) output")
        }
    }
    return mismatches
}

private func audioDefaultMismatches(_ node: ModelNodeDescriptor,
                                    defaultRequest: AudioRequest) -> [String] {
    var mismatches: [String] = []
    guard defaultRequest.operation == .generate, defaultRequest.source == nil,
          defaultRequest.editRegion == nil, let defaults = defaultRequest.diffusion else {
        return ["audio default request shape"]
    }
    guard let projected = operation("audio.sa3.diffusion.generate", in: node) else {
        return ["audio default operation"]
    }
    if projected.parameters.first(where: { $0.id == "seed" })?.defaultValue
        != String(defaultRequest.seed) {
        mismatches.append("audio default seed")
    }
    if projected.parameters.first(where: { $0.id == "steps" })?.defaultValue
        != String(defaults.steps) {
        mismatches.append("audio default steps")
    }
    return mismatches
}

private func videoMismatches(_ node: ModelNodeDescriptor, draft: VideoCreationDraft,
                             request: VideoRequest,
                             capability: VideoExecutionCapability) -> [String] {
    var mismatches: [String] = []
    let operationID = "video.generate/\(capability.profile.revision)"
    guard let projected = operation(operationID, in: node) else { return ["operation \(operationID)"] }
    if node.id != capability.profile.identifier { mismatches.append("video profile identity") }
    if projected.inputs.map(\.id) != ["positivePrompt", "negativePrompt"] {
        mismatches.append("video inputs")
    }
    if projected.inputs.first?.requirement != .required || projected.inputs.last?.requirement != .optional {
        mismatches.append("video input requirements")
    }
    if projected.outputs.map(\.id) != ["video"] || projected.outputs.first?.requirement != .required {
        mismatches.append("video output")
    }
    let expectedDefaults = [
        "geometry": "\(request.width) × \(request.height)",
        "frames": String(request.frameCount),
        "frameRate": "\(request.frameRate.numerator)/\(request.frameRate.denominator) fps",
        "steps": draft.stepsText,
        "guidance": draft.guidanceText,
        "shift": draft.shiftText,
        "seed": draft.seedText
    ]
    for (id, expected) in expectedDefaults {
        if projected.parameters.first(where: { $0.id == id })?.defaultValue != expected {
            mismatches.append("video \(id) default")
        }
    }
    return mismatches
}

private func imageProjectionWithControlledDrift(_ node: ModelNodeDescriptor) throws -> ModelNodeDescriptor {
    var operations = node.operations
    let operationIndex = try #require(operations.firstIndex { $0.id == "verified512/1" })
    let original = operations[operationIndex]
    var inputs = original.inputs
    let promptIndex = try #require(inputs.firstIndex { $0.id == "prompt" })
    let prompt = inputs[promptIndex]
    inputs[promptIndex] = ModelNodePort(
        id: prompt.id, title: prompt.title, dataType: prompt.dataType,
        requirement: .optional, detail: prompt.detail)

    var parameters = original.parameters
    let stepsIndex = try #require(parameters.firstIndex { $0.id == "steps" })
    let steps = parameters[stepsIndex]
    parameters[stepsIndex] = ModelNodeParameter(
        id: steps.id, title: steps.title, defaultValue: "99",
        acceptedValues: steps.acceptedValues, detail: steps.detail, isAdjustable: steps.isAdjustable)
    operations[operationIndex] = ModelNodeOperation(
        id: original.id, title: original.title, summary: original.summary,
        inputs: inputs, outputs: original.outputs, parameters: parameters)

    return ModelNodeDescriptor(
        id: node.id, modality: node.modality, title: node.title, summary: node.summary,
        modelIdentity: node.modelIdentity, revision: "controlled-drift",
        engine: node.engine, device: node.device, precision: node.precision,
        availability: node.availability, deploymentNote: node.deploymentNote,
        operations: operations, notes: node.notes, evidencePaths: node.evidencePaths)
}

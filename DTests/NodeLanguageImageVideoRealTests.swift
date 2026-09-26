@preconcurrency import AVFoundation
import CryptoKit
import DInference
import DWorkbench
import Foundation
import ImageIO
import Testing
@testable import D

/// Opt-in real media checks through the production App composition root and workflow interpreter.
/// These tests do not constitute GUI, Xcode Run, publication, or system-offline acceptance.
@Suite(.serialized) @MainActor
struct NodeLanguageImageVideoRealTests {
    private static let imageRevision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"
    private static let gibibyte = UInt64(1_073_741_824)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "image"),
          .timeLimit(.minutes(90)))
    func officialE02GeneratesOwnedCandidatesAndOneReferenceResult() async throws {
        let environment = ProcessInfo.processInfo.environment
        let textModelURL = URL(fileURLWithPath: try #require(environment["D_NODE_LANGUAGE_TEXT_MODEL"]))
        let imageModelURL = URL(fileURLWithPath: try #require(environment["D_NODE_LANGUAGE_IMAGE_MODEL"]))
        let root = try Self.makeTestRoot(caseName: "image")
        let projectURL = root.appendingPathComponent("real-image.dproject", isDirectory: true)
        print("D_NODE_LANGUAGE_REAL_IMAGE_ROOT=\(root.path)")

        let store = try await ProjectStore.create(at: projectURL, name: "Node language real image")
        var runtime: WorkbenchSession?
        var controller: WorkflowController?
        let started = Date()
        var textRevision = "unvalidated"
        do {
            let session = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory)
            runtime = session
            let validateText = try #require(session.validateTextModel)
            let textReference = try await validateText(textModelURL)
            textRevision = try #require(textReference.revision)
            try await session.validateModel(imageModelURL)
            let imageReference = ModelReference(directory: imageModelURL, revision: Self.imageRevision)
            let textIdentity = "text:" + textRevision
            let imageIdentity = "image:" + Self.imageRevision
            let textBackendID = try #require(session.textBackendID)

            let services = WorkflowServices(store: store, session: session, defaultIdentity: { kind in
                switch kind {
                case .text: textIdentity
                case .image: imageIdentity
                default: ""
                }
            }, resolveModel: { kind, selected in
                switch kind {
                case .text where selected == textIdentity:
                    return .init(identity: textIdentity, reference: textReference, backendID: textBackendID)
                case .image where selected == imageIdentity:
                    return .init(identity: imageIdentity, reference: imageReference,
                                 backendID: session.backendID,
                                 imageRecipe: .klein(capability: session.imageCapability))
                default:
                    throw WorkflowIssue("Unexpected model binding in real image check: \(kind.rawValue):\(selected)")
                }
            })
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()

            // Independent cancellation proof: detach legacy upstream review nodes and wait for
            // the production image backend's observed generation phase before requesting stop.
            subject.addExample("image")
            let cancellationNode = try #require(subject.graph?.nodes.first { $0.operationID == "d.image.generate" })
            for edge in subject.graph?.connections.filter({ $0.targetNode == cancellationNode.id }) ?? [] {
                subject.disconnect(edge.id)
            }
            Self.configureImageNode(cancellationNode.id, controller: subject, modelIdentity: imageIdentity,
                                    count: 1, seed: "9001")
            subject.setParameter(nodeID: cancellationNode.id, key: "promptText",
                                 value: .text("A cobalt paper lantern in a quiet studio"))
            let cancellationTask = Task { @MainActor in
                await subject.run(target: cancellationNode.id, only: false)
            }
            let cancellationObservation: RuntimeObservation
            do {
                cancellationObservation = try await Self.awaitRuntimeMilestone(session: session) { status in
                    status.activeRunID != nil && status.phase == "正在生成图像"
                }
            } catch {
                await subject.cancel()
                await cancellationTask.value
                throw error
            }
            await subject.cancel()
            await cancellationTask.value
            let cancelledRun = try #require(subject.runs.last)
            try #require(cancelledRun.status == .cancelled)
            try await Self.requireRuntimeDrained(session)

            // Load the official editable E02. The real Qwen planner remains in the plan;
            // schema checking and repair are editable ordinary nodes inside its tool.
            subject.addLanguageExample(.images)
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "E02 could not be added"))
            let e02Graph = try #require(subject.graph)
            try #require(e02Graph.name == "E02 两主题三图")
            let planner = try #require(e02Graph.nodes.first { $0.title == "一次规划全部主题" && $0.operationID == "d.control.invoke" })
            // The official visible tool now owns schema checks and a bounded repair loop.
            // Model identities are frozen from the same explicit default resolver.
            let resultNode = try #require(e02Graph.nodes.first { $0.operationID == "d.value.return" })
            await subject.run(target: resultNode.id, only: false)
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "E02 execution failed"))
            let e02Run = try #require(subject.runs.last)
            try #require(e02Run.status == .completed)
            let checkpoint = try #require(e02Run.planCheckpoint)
            let plannerCall = try #require(checkpoint.records.first { $0.step.node.id == planner.id })
            let plannedThemes = try Self.requirePlannedThemes(plannerCall.step.outputs["output"])
            let finalCall = try #require(checkpoint.records.first { $0.step.node.id == resultNode.id })
            let finalThemes = try Self.requireE02FinalThemes(finalCall.step.outputs["output"], planned: plannedThemes)

            let generationCalls = checkpoint.records.filter {
                $0.step.node.operationID == "d.image.generate" && $0.step.status == .completed
            }
            try #require(generationCalls.count == 2)
            let itemIDs = generationCalls.compactMap(Self.mapItemID)
            try #require(itemIDs.count == 2)
            try #require(Set(itemIDs) == Set(plannedThemes.map(\.itemID)))

            let afterE02 = try #require(try await store.workflowState().archive)
            // A successful planning tool may need 0...2 visible repair calls.
            // Preserve this count instead of claiming every model response was valid first time.
            let planningCalls = checkpoint.records.filter {
                $0.step.node.operationID == "d.model.language" && $0.step.status == .completed
            }
            try #require((1...3).contains(planningCalls.count))
            for call in planningCalls {
                let raw = try #require(call.step.outputs["raw"]?.asset)
                let record = try #require(afterE02.assets.first { $0.reference == raw })
                let request = try #require(record.request)
                try #require(record.stepID == call.id && request.id == call.id)
                try #require(request.model.revision == textRevision)
                let rawBytes = try await store.workflowData(raw)
                try #require(!rawBytes.isEmpty)
            }
            let planningLoop = try #require(checkpoint.records.first {
                $0.step.node.operationID == "d.control.loop"
            })
            var candidateIDs = Set<UUID>()
            var attemptIDs = Set<UUID>()
            var outputReferences: [WorkflowAssetReference] = []
            var imageEvidence: [[String: Any]] = []
            var processedEvidence: [[String: Any]] = []
            for call in generationCalls {
                let mapItem = try #require(Self.mapItemID(call))
                let theme = try #require(plannedThemes.first { $0.itemID == mapItem })
                let finalTheme = try #require(finalThemes.first { $0.itemID == mapItem })
                let prompt = try #require(call.step.inputs["prompt"]?.datum?.text)
                try #require(prompt == theme.prompt)
                let candidates = call.step.outputs["output"]?.candidates ?? []
                try #require(candidates.count == 3)
                let localIDs = Set(candidates.map(\.id))
                let localAttempts = Set(candidates.map(\.attemptID))
                let localSeeds = Set(candidates.map(\.seed))
                try #require(localIDs.count == 3)
                try #require(localAttempts.count == 3)
                try #require(localSeeds.count == 3)
                try #require(candidates.allSatisfy { $0.asset != nil && $0.error == nil })
                try #require(finalTheme.themeID == theme.themeID)
                try #require(finalTheme.candidates.map(\.id) == candidates.map(\.id))
                try #require(finalTheme.candidates.map(\.attemptID) == candidates.map(\.attemptID))
                try #require(finalTheme.candidates.map(\.seed) == candidates.map(\.seed))
                try #require(finalTheme.candidates.map(\.asset) == candidates.compactMap(\.asset))
                candidateIDs.formUnion(localIDs)
                attemptIDs.formUnion(localAttempts)

                for candidate in candidates {
                    let output = try #require(candidate.asset)
                    outputReferences.append(output)
                    let record = try #require(afterE02.assets.first { $0.reference == output })
                    let request = try #require(record.request)
                    try #require(record.operationID == "d.image.generate")
                    try #require(record.stepID == candidate.attemptID)
                    try #require(request.id == candidate.attemptID)
                    try #require(request.model == imageReference)
                    guard case .image(let input) = request.input else {
                        throw WorkflowIssue("E02 candidate did not persist an image request.")
                    }
                    try #require(input.prompt == theme.prompt)
                    try #require(input.seed.description == candidate.seed)
                    try #require(input.width == 512 && input.height == 512)
                    try #require(input.steps == 4 && input.guidanceScale == 1)
                    try #require(input.executionProfile == session.imageCapability.profile)
                    try #require(input.referenceImage == nil)
                    let media = try await store.workflowMedia(output)
                    try Self.requirePNG(media.0, width: 512, height: 512)
                    try #require(media.1.mediaType == "image/png")
                    imageEvidence.append([
                        "themeID": theme.themeID, "mapItemID": mapItem,
                        "candidateID": candidate.id.uuidString,
                        "attemptID": candidate.attemptID.uuidString,
                        "assetID": output.assetID.uuidString,
                        "mediaPath": media.0.path,
                        "seed": candidate.seed,
                    ])
                }
                try #require(finalTheme.processed.count == 3)
                try #require(Set(finalTheme.processed).count == 3)
                for (candidate, processed) in zip(candidates, finalTheme.processed) {
                    let media = try await store.workflowMedia(processed)
                    try Self.requirePNG(media.0, width: 768, height: 768)
                    try #require(media.1.mediaType == "image/png")
                    processedEvidence.append([
                        "themeID": theme.themeID,
                        "sourceCandidateID": candidate.id.uuidString,
                        "assetID": processed.assetID.uuidString,
                        "mediaPath": media.0.path,
                    ])
                }
            }
            try #require(candidateIDs.count == 6)
            try #require(attemptIDs.count == 6)
            try #require(Set(outputReferences).count == 6)
            try #require(processedEvidence.count == 6)

            // Generate once more from one exact image produced by this E02 run.
            let sourceReference = try #require(outputReferences.first)
            subject.addExample("file")
            let sourceNode = try #require(subject.graph?.nodes.first { $0.operationID == "d.asset.reference" })
            subject.attach(sourceReference, nodeID: sourceNode.id)
            let referencePrompt = "Preserve the composition while changing the lighting to dawn."
            await subject.publishText(referencePrompt, origin: "MEDIA-CHECKS r1 reference prompt")
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "Reference prompt publication failed"))
            let promptNode = try #require(subject.selectedNodeID)
            let promptAsset = try #require(subject.graph?.nodes.first { $0.id == promptNode }?.assetReference)
            try #require(promptAsset.kind == .text)
            subject.addNode(operationID: "d.image.generate")
            let referenceNode = try #require(subject.selectedNodeID)
            Self.configureImageNode(referenceNode, controller: subject, modelIdentity: imageIdentity,
                                    count: 1, seed: "424242")
            subject.connect(source: promptNode, sourcePort: "output", target: referenceNode, targetPort: "prompt")
            subject.connect(source: sourceNode.id, sourcePort: "output", target: referenceNode, targetPort: "ref")
            await subject.run(target: referenceNode, only: false)
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "Reference generation failed"))
            let referenceRun = try #require(subject.runs.last)
            try #require(referenceRun.status == .completed)
            let referenceCall = try #require(referenceRun.planCheckpoint?.records.first {
                $0.step.node.id == referenceNode
            })
            let referenceCandidates = referenceCall.step.outputs["output"]?.candidates ?? []
            try #require(referenceCandidates.count == 1)
            let referenceCandidate = try #require(referenceCandidates.first)
            let derivedReference = try #require(referenceCandidate.asset)
            let actualPromptAsset = try #require(referenceCall.step.inputs["prompt"]?.asset)
            let actualImageAsset = try #require(referenceCall.step.inputs["ref"]?.asset)
            try #require(actualPromptAsset == promptAsset)
            try #require(actualImageAsset == sourceReference)
            try #require(actualPromptAsset.kind == .text && actualImageAsset.kind == .image)
            let expectedParents: Set<WorkflowAssetReference> = [actualPromptAsset, actualImageAsset]
            try #require(expectedParents.count == 2)

            await subject.save()
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "Workflow save failed"))
            try #require(!subject.hasPendingSaves)
            let savedArchive = try #require(try await store.workflowState().archive)
            let derivedRecord = try #require(savedArchive.assets.first { $0.reference == derivedReference })
            try #require(derivedRecord.parents.count == 2)
            try #require(Set(derivedRecord.parents) == expectedParents)
            let derivedRequest = try #require(derivedRecord.request)
            try #require(derivedRequest.id == referenceCandidate.attemptID)
            try #require(derivedRequest.model == imageReference)
            guard case .image(let derivedInput) = derivedRequest.input else {
                throw WorkflowIssue("Reference result did not persist an image request.")
            }
            let frozenReference = try #require(derivedInput.referenceImage)
            try #require(derivedInput.prompt == referencePrompt)
            try #require(derivedInput.width == 512 && derivedInput.height == 512)
            try #require(derivedInput.steps == 4 && derivedInput.guidanceScale == 1)
            try #require(derivedInput.seed == 424242)
            try #require(derivedInput.executionProfile == ImageExecutionCapability.referenceKlein4B.profile)
            try #require(frozenReference.url.path.hasSuffix(
                "/ImageInputs/\(referenceCandidate.attemptID.uuidString)/reference.rgb"))
            let sourcePNG = try await store.workflowData(sourceReference)
            let sourcePixels = try Self.requireFrozenReference(frozenReference, sourcePNG: sourcePNG)
            try #require(sourcePixels.sourceSHA256 == sourceReference.sha256)
            let derivedMedia = try await store.workflowMedia(derivedReference)
            try Self.requirePNG(derivedMedia.0, width: 512, height: 512)
            let sourceGraph = try #require(savedArchive.graphs.first { graph in
                graph.nodes.contains { $0.id == sourceNode.id && $0.assetReference == sourceReference }
            })
            try #require(sourceGraph.nodes.contains {
                $0.id == sourceNode.id && $0.assetReference == sourceReference
            })

            let report: [String: Any] = [
                "case": "image",
                "driver": "AppSessionFactory + WorkflowController + official E02",
                "project": projectURL.path,
                "textRevision": textRevision,
                "imageRevision": Self.imageRevision,
                "cancelledWorkflowRunID": cancelledRun.id.uuidString,
                "cancelledStatus": cancelledRun.status.rawValue,
                "cancelledBackendRunID": cancellationObservation.activeRunID.uuidString,
                "cancelledObservedState": cancellationObservation.state?.rawValue ?? "unknown",
                "cancelledObservedPhase": cancellationObservation.phase ?? "unknown",
                "e02RunID": e02Run.id.uuidString,
                "e02Status": e02Run.status.rawValue,
                "planningModelCalls": planningCalls.count,
                "planningRepairCalls": planningCalls.count - 1,
                "planningCallIDs": planningCalls.map { $0.id.uuidString },
                "planningLoopExit": planningLoop.loopExit?.rawValue ?? "unknown",

                "referenceRunID": referenceRun.id.uuidString,
                "referenceStatus": referenceRun.status.rawValue,
                "sourceAssetID": sourceReference.assetID.uuidString,
                "promptAssetID": promptAsset.assetID.uuidString,
                "derivedAssetID": derivedReference.assetID.uuidString,
                "derivedMediaPath": derivedMedia.0.path,
                "referenceRGBSHA256": frozenReference.sha256,
                "referenceRGBByteCount": frozenReference.byteCount,
                "referenceWidth": sourcePixels.width,
                "referenceHeight": sourcePixels.height,
                "imageCandidates": imageEvidence,
                "processedImages": processedEvidence,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "guiValidated": false,
            ]

            try await subject.close()
            let finalArchive = try #require(try await store.workflowState().archive)
            try await store.close()
            let reopened = try await ProjectStore.open(at: projectURL)
            let reopenedArchive = try #require(try await reopened.workflowState().archive)
            try #require(reopenedArchive == finalArchive)
            let reopenedDerived = try await reopened.workflowMedia(derivedReference)
            try Self.requirePNG(reopenedDerived.0, width: 512, height: 512)
            let reopenedRecord = try #require(reopenedArchive.assets.first { $0.reference == derivedReference })
            try #require(reopenedRecord.parents.count == 2)
            try #require(Set(reopenedRecord.parents) == expectedParents)
            let reopenedRequest = try #require(reopenedRecord.request)
            guard case .image(let reopenedInput) = reopenedRequest.input else {
                throw WorkflowIssue("Reopened reference result lost its image request.")
            }
            let reopenedFrozenReference = try #require(reopenedInput.referenceImage)
            try #require(reopenedFrozenReference == frozenReference)
            let reopenedSourcePNG = try await reopened.workflowData(sourceReference)
            let reopenedSourcePixels = try Self.requireFrozenReference(
                reopenedFrozenReference, sourcePNG: reopenedSourcePNG)
            try #require(reopenedSourcePixels.sourceSHA256 == sourceReference.sha256)
            try await reopened.close()
            await session.shutdown()
            runtime = nil
            try Self.writeJSON(report, to: root.appendingPathComponent("real-image-result.json"))
            print("D_NODE_LANGUAGE_REAL_IMAGE_PASS=\(root.path)")
        } catch {
            if let controller {
                await controller.cancel()
                try? await controller.close()
            }
            if let runtime { await runtime.shutdown() }
            try? await store.close(preserveExternalChanges: true)
            Self.writeFailure(error, caseName: "image", project: projectURL,
                              revisions: ["text": textRevision, "image": Self.imageRevision], root: root,
                              elapsed: Date().timeIntervalSince(started))
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "video"),
          .timeLimit(.minutes(90)))
    func productionVideoNodeCancelsAtExecutionThenPersistsDecodedMP4() async throws {
        let environment = ProcessInfo.processInfo.environment
        let videoModelURL = URL(fileURLWithPath: try #require(environment["D_NODE_LANGUAGE_VIDEO_MODEL"]))
        let root = try Self.makeTestRoot(caseName: "video")
        let projectURL = root.appendingPathComponent("real-video.dproject", isDirectory: true)
        let accessRoot = root.appendingPathComponent("VideoProcessAccess", isDirectory: true)
        try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let accessAttributes = try FileManager.default.attributesOfItem(atPath: accessRoot.path)
        let accessPermissions = try #require(accessAttributes[.posixPermissions] as? NSNumber)
        try #require(accessPermissions.intValue & 0o777 == 0o700)
        try #require(!accessRoot.path.hasPrefix(projectURL.path + "/"))
        try #require(!projectURL.path.hasPrefix(accessRoot.path + "/"))
        print("D_NODE_LANGUAGE_REAL_VIDEO_ROOT=\(root.path)")

        let resources = try #require(Bundle.main.resourceURL)
        let videoEngine = try #require(try BundledAudioEngine.resolve(
            resourceDirectory: resources, family: .video))
        let store = try await ProjectStore.create(at: projectURL, name: "Node language real video")
        var runtime: WorkbenchSession?
        var controller: WorkflowController?
        let started = Date()
        var videoRevision = "unvalidated"
        do {
            let session = try await AppSessionFactory.makeSession(
                artifactDirectory: store.artifactDirectory,
                bundledVideoEngine: videoEngine,
                videoAccessRoot: accessRoot
            )
            runtime = session
            let validateVideo = try #require(session.validateVideoModel)
            let videoReference = try await validateVideo(videoModelURL)
            videoRevision = try #require(videoReference.revision)
            try #require(videoRevision == VideoExecutionCapability.wan21.modelRevision)
            let videoBackendID = try #require(session.videoBackendID)
            let videoIdentity = "video:" + videoRevision
            let services = WorkflowServices(store: store, session: session, defaultIdentity: { kind in
                kind == .video ? videoIdentity : ""
            }, resolveModel: { kind, selected in
                guard kind == .video, selected == videoIdentity else {
                    throw WorkflowIssue("Unexpected model binding in real video check: \(kind.rawValue):\(selected)")
                }
                return .init(identity: videoIdentity, reference: videoReference, backendID: videoBackendID)
            })
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()
            subject.addLanguageExample(.multimodal)
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "E04 could not be added"))
            let graph = try #require(subject.graph)
            let videoNode = try #require(graph.nodes.first { $0.operationID == "d.video.generate" })
            let videoEdges = graph.connections.filter { $0.targetNode == videoNode.id }
            try #require(videoEdges.map(\.targetPort) == ["prompt"])
            let sourceIDs = Set(videoEdges.map(\.sourceNode))
            try #require(graph.nodes.filter { sourceIDs.contains($0.id) }.allSatisfy {
                $0.operationID != "d.image.generate" && $0.operationID != "d.asset.reference"
            })
            Self.configureVideoNode(videoNode.id, controller: subject, modelIdentity: videoIdentity)

            let cancellationTask = Task { @MainActor in
                await subject.run(target: videoNode.id, only: false)
            }
            let cancellationObservation: RuntimeObservation
            do {
                cancellationObservation = try await Self.awaitRuntimeMilestone(session: session) { status in
                    status.activeRunID != nil && status.state == .generating
                }
            } catch {
                await subject.cancel()
                await cancellationTask.value
                throw error
            }
            await subject.cancel()
            await cancellationTask.value
            let cancelledRun = try #require(subject.runs.last)
            try #require(cancelledRun.status == .cancelled)
            try await Self.requireRuntimeDrained(session)

            // A fresh workflow run after the cancelled backend request proves recovery and
            // preserves the same explicit T2V request. No image input exists in this graph path.
            await subject.run(target: videoNode.id, only: false)
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "Video execution failed"))
            let completedRun = try #require(subject.runs.last)
            try #require(completedRun.status == .completed)
            let videoCall = try #require(completedRun.planCheckpoint?.records.first {
                $0.step.node.id == videoNode.id && $0.step.status == .completed
            })
            let videoOutput = try #require(videoCall.step.outputs["output"]?.asset)
            let inputReferences = videoCall.step.inputs.values.flatMap { $0.datum?.assetReferences ?? [] }
            // E04 deliberately publishes its shared text as an asset. T2V excludes
            // image conditions, not the provenance of its text prompt.
            try #require(inputReferences.count == 1)
            let promptReference = try #require(inputReferences.first)
            try #require(promptReference.kind == .text)
            try #require(Set(videoCall.step.inputs.keys) == ["prompt"])
            let promptData = try await store.workflowData(promptReference)
            let prompt = try #require(String(data: promptData, encoding: .utf8))
            try #require(!prompt.isEmpty)

            await subject.save()
            try #require(subject.errorMessage == nil,
                         Comment(rawValue: subject.errorMessage ?? "Workflow save failed"))
            try #require(!subject.hasPendingSaves)
            let savedArchive = try #require(try await store.workflowState().archive)
            let record = try #require(savedArchive.assets.first { $0.reference == videoOutput })
            try #require(record.operationID == "d.video.generate")
            try #require(record.stepID == videoCall.step.id)
            try #require(record.parents == [promptReference])
            let request = try #require(record.request)
            try #require(request.id == videoCall.step.id)
            try #require(request.model == videoReference)
            try #require(request.memoryBudgetBytes == 13 * Self.gibibyte)
            guard case .video(let input) = request.input else {
                throw WorkflowIssue("Video node did not persist a video request.")
            }
            try #require(input.prompt == prompt)
            try #require(input.width == 256 && input.height == 256)
            try #require(input.frameCount == 17)
            try #require(input.frameRate == .init(numerator: 16))
            try #require(input.steps == 4 && input.guidanceScale == 5)
            try #require(input.scheduleShift == 5 && input.seed == 42)
            try #require(input.executionProfile == VideoExecutionCapability.wan21.profile)

            let storedMedia = try await store.workflowMedia(videoOutput)
            try #require(storedMedia.1.mediaType == "video/mp4")
            let registered = try #require(storedMedia.1.metadata.video)
            try #require(registered.width == 256 && registered.height == 256)
            try #require(registered.frameCount == 17)
            try #require(registered.frameRate == .init(numerator: 16))
            try #require(registered.durationNumerator == 17 && registered.durationDenominator == 16)
            try #require(registered.byteCount > 0)
            let independent = try await Self.inspectVideoPayload(storedMedia.0)
            try #require(independent.width == 256 && independent.height == 256)
            try #require(independent.frameCount == 17)
            try #require(independent.duration == CMTime(value: 17, timescale: 16))
            try #require(independent.decodedBytes > 0)

            let report: [String: Any] = [
                "case": "video",
                "driver": "Bundle.main video engine + AppSessionFactory + WorkflowController",
                "project": projectURL.path,
                "resourceRoot": resources.path,
                "accessRoot": accessRoot.path,
                "videoRevision": videoRevision,
                "cancelledWorkflowRunID": cancelledRun.id.uuidString,
                "cancelledStatus": cancelledRun.status.rawValue,
                "cancelledBackendRunID": cancellationObservation.activeRunID.uuidString,
                "cancelledObservedState": cancellationObservation.state?.rawValue ?? "unknown",
                "cancelledObservedPhase": cancellationObservation.phase ?? "unknown",
                "cancellationEvidence": "runtime execution-entry (.generating); GPU milestone not asserted",
                "completedRunID": completedRun.id.uuidString,
                "completedStatus": completedRun.status.rawValue,
                "requestID": request.id.uuidString,
                "assetID": videoOutput.assetID.uuidString,
                "mediaPath": storedMedia.0.path,
                "frameCount": independent.frameCount,
                "decodedBytes": independent.decodedBytes,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "guiValidated": false,
            ]

            try await subject.close()
            let finalArchive = try #require(try await store.workflowState().archive)
            try await store.close()
            let reopened = try await ProjectStore.open(at: projectURL)
            let reopenedArchive = try #require(try await reopened.workflowState().archive)
            try #require(reopenedArchive == finalArchive)
            let reopenedMedia = try await reopened.workflowMedia(videoOutput)
            let reopenedIndependent = try await Self.inspectVideoPayload(reopenedMedia.0)
            try #require(reopenedIndependent == independent)
            try await reopened.close()
            await session.shutdown()
            runtime = nil
            try Self.writeJSON(report, to: root.appendingPathComponent("real-video-result.json"))
            print("D_NODE_LANGUAGE_REAL_VIDEO_PASS=\(root.path)")
        } catch {
            if let controller {
                await controller.cancel()
                try? await controller.close()
            }
            if let runtime { await runtime.shutdown() }
            try? await store.close(preserveExternalChanges: true)
            Self.writeFailure(error, caseName: "video", project: projectURL,
                              revisions: ["video": videoRevision], root: root,
                              elapsed: Date().timeIntervalSince(started))
            throw error
        }
    }

    private struct PlannedTheme {
        let itemID: String
        let themeID: String
        let title: String
        let prompt: String
    }

    private struct E02CandidateRecord {
        let id: UUID
        let attemptID: UUID
        let seed: String
        let asset: WorkflowAssetReference
    }

    private struct E02FinalTheme {
        let itemID: String
        let themeID: String
        let candidates: [E02CandidateRecord]
        let processed: [WorkflowAssetReference]
    }

    private struct RuntimeObservation {
        let activeRunID: UUID
        let state: JobState?
        let phase: String?
    }

    private struct VideoPayloadEvidence: Equatable {
        let width: Int
        let height: Int
        let frameCount: Int
        let duration: CMTime
        let decodedBytes: Int
    }

    private static func makeTestRoot(caseName: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let parent = support.appendingPathComponent("D/NodeLanguageMediaAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(caseName + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func configureImageNode(_ id: UUID, controller: WorkflowController,
                                           modelIdentity: String, count: Int, seed: String) {
        controller.setParameter(nodeID: id, key: "modelID", value: .text(modelIdentity))
        controller.setParameter(nodeID: id, key: "width", value: .integer(512))
        controller.setParameter(nodeID: id, key: "height", value: .integer(512))
        controller.setParameter(nodeID: id, key: "steps", value: .integer(4))
        controller.setParameter(nodeID: id, key: "guidance", value: .decimal(1))
        controller.setParameter(nodeID: id, key: "seed", value: .text(seed))
        controller.setParameter(nodeID: id, key: "count", value: .integer(count))
    }

    private static func configureVideoNode(_ id: UUID, controller: WorkflowController,
                                           modelIdentity: String) {
        controller.setParameter(nodeID: id, key: "modelID", value: .text(modelIdentity))
        controller.setParameter(nodeID: id, key: "width", value: .integer(256))
        controller.setParameter(nodeID: id, key: "height", value: .integer(256))
        controller.setParameter(nodeID: id, key: "frameCount", value: .integer(17))
        controller.setParameter(nodeID: id, key: "frameRate", value: .integer(16))
        controller.setParameter(nodeID: id, key: "steps", value: .integer(4))
        controller.setParameter(nodeID: id, key: "guidance", value: .decimal(5))
        controller.setParameter(nodeID: id, key: "scheduleShift", value: .decimal(5))
        controller.setParameter(nodeID: id, key: "seed", value: .text("42"))
        controller.setParameter(nodeID: id, key: "memoryBudgetGiB", value: .integer(13))
    }

    private static func awaitRuntimeMilestone(
        session: WorkbenchSession,
        matching: (WorkbenchRuntimeStatus) -> Bool
    ) async throws -> RuntimeObservation {
        for _ in 0..<9_000 {
            let status = await session.status()
            if matching(status), let activeRunID = status.activeRunID {
                return .init(activeRunID: activeRunID, state: status.state, phase: status.phase)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkflowIssue("No usable exact runtime milestone was observed within 180 seconds; cancellation evidence is unavailable.")
    }

    private static func requireRuntimeDrained(_ session: WorkbenchSession) async throws {
        let status = await session.status()
        try #require(status.activeRunID == nil)
        try #require(status.queuedRunIDs.isEmpty)
    }

    private static func requirePlannedThemes(_ value: WorkflowValue?) throws -> [PlannedTheme] {
        let datum = try #require(value?.datum)
        let items = try #require(datum.items)
        try #require(items.count == 2)
        var identities = Set<String>()
        let themes = try items.map { item -> PlannedTheme in
            let fields = try #require(item.value.fields)
            try #require(Set(fields.keys) == Set(["themeID", "title", "prompt"]))
            let themeID = try #require(fields["themeID"]?.text)
            let title = try #require(fields["title"]?.text)
            let prompt = try #require(fields["prompt"]?.text)
            let trimmedThemeID = themeID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(!trimmedThemeID.isEmpty)
            try #require(!trimmedTitle.isEmpty)
            try #require(!trimmedPrompt.isEmpty)
            identities.insert(themeID)
            return PlannedTheme(itemID: item.id, themeID: themeID,
                                title: title, prompt: prompt)
        }
        try #require(identities.count == 2)
        return themes
    }

    private static func requireE02FinalThemes(
        _ value: WorkflowValue?,
        planned: [PlannedTheme]
    ) throws -> [E02FinalTheme] {
        let datum = try #require(value?.datum)
        let items = try #require(datum.items)
        try #require(items.count == 2)
        try #require(items.map(\.id) == planned.map(\.itemID))
        return try zip(items, planned).map { item, theme in
            guard case .result(let outerResult) = item.value else {
                throw WorkflowIssue("E02 final theme item is not a Map result.")
            }
            try #require(outerResult.status == .success)
            try #require(outerResult.issues.isEmpty)
            let group = try #require(outerResult.value)
            try #require(outerResult.expected == group.schema)
            let fields = try #require(group.fields)
            try #require(Set(fields.keys) == Set(["themeID", "candidates", "processed"]))
            try #require(fields["themeID"]?.text == theme.themeID)

            let candidateItems = try #require(fields["candidates"]?.items)
            try #require(candidateItems.count == 3)
            let candidates = try candidateItems.map { candidateItem -> E02CandidateRecord in
                let candidateFields = try #require(candidateItem.value.fields)
                try #require(Set(candidateFields.keys) == Set([
                    "id", "attemptID", "seed", "status", "asset", "error",
                ]))
                let idText = try #require(candidateFields["id"]?.text)
                let attemptText = try #require(candidateFields["attemptID"]?.text)
                let id = try #require(UUID(uuidString: idText))
                let attemptID = try #require(UUID(uuidString: attemptText))
                try #require(candidateItem.id == idText)
                let seed = try #require(candidateFields["seed"]?.text)
                guard case .enumeration(let status, let choices)? = candidateFields["status"] else {
                    throw WorkflowIssue("E02 candidate status is not an enumeration.")
                }
                try #require(status == "success")
                try #require(choices == ["success", "failed"])
                guard case .asset(let asset)? = candidateFields["asset"] else {
                    throw WorkflowIssue("E02 successful candidate has no image asset.")
                }
                try #require(asset.kind == .image)
                guard case .none(let errorType)? = candidateFields["error"] else {
                    throw WorkflowIssue("E02 successful candidate retained an error.")
                }
                try #require(errorType == .text)
                return .init(id: id, attemptID: attemptID, seed: seed, asset: asset)
            }
            try #require(Set(candidates.map(\.id)).count == 3)
            try #require(Set(candidates.map(\.attemptID)).count == 3)

            let processedItems = try #require(fields["processed"]?.items)
            try #require(processedItems.count == 3)
            try #require(processedItems.map(\.id) == candidateItems.map(\.id))
            let processed = try processedItems.map { processedItem -> WorkflowAssetReference in
                guard case .result(let result) = processedItem.value else {
                    throw WorkflowIssue("E02 processed image is not a Map result.")
                }
                try #require(result.status == .success)
                try #require(result.issues.isEmpty)
                try #require(result.expected == .asset(.image))
                guard case .asset(let asset)? = result.value else {
                    throw WorkflowIssue("E02 processed success has no image asset.")
                }
                try #require(asset.kind == .image)
                return asset
            }
            return .init(itemID: item.id, themeID: theme.themeID,
                         candidates: candidates, processed: processed)
        }
    }

    @discardableResult
    private static func requireFrozenReference(
        _ frozen: ImageReference,
        sourcePNG: Data
    ) throws -> ImageReferencePixels {
        let pixels = try ImageReferencePixels.decodePNG(sourcePNG)
        try #require(pixels.sourceSHA256 == Self.sha256(sourcePNG))
        try #require(frozen.width == pixels.width && frozen.height == pixels.height)
        try #require(frozen.byteCount == UInt64(pixels.rgb.count))
        try #require(frozen.sha256 == Self.sha256(pixels.rgb))
        let frozenRGB = try Data(contentsOf: frozen.url, options: .mappedIfSafe)
        try #require(frozenRGB.count == pixels.rgb.count)
        try #require(frozenRGB == pixels.rgb)
        try frozen.validate()
        return pixels
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mapItemID(_ record: WorkflowPlanCallRecord) -> String? {
        record.address.path.reversed().compactMap { component -> String? in
            if case .item(let id) = component { return id }
            return nil
        }.first
    }

    private static func requirePNG(_ url: URL, width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        try #require(CGImageSourceGetCount(source) == 1)
        try #require(CGImageSourceGetType(source) as String? == "public.png")
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(decoded.width == width)
        try #require(decoded.height == height)
    }

    private static func inspectVideoPayload(_ url: URL) async throws -> VideoPayloadEvidence {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(videoTracks.count == 1)
        try #require(audioTracks.isEmpty)
        let track = try #require(videoTracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let duration = try await asset.load(.duration)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])
        output.alwaysCopiesSampleData = false
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading(), Comment(rawValue: reader.error?.localizedDescription ?? "AVAssetReader did not start"))
        var frameCount = 0
        var decodedBytes = 0
        while let sample = output.copyNextSampleBuffer() {
            try #require(CMSampleBufferDataIsReady(sample))
            let pixel = try #require(CMSampleBufferGetImageBuffer(sample))
            try #require(CVPixelBufferGetWidth(pixel) == Int(dimensions.width))
            try #require(CVPixelBufferGetHeight(pixel) == Int(dimensions.height))
            let lock = CVPixelBufferLockBaseAddress(pixel, .readOnly)
            try #require(lock == kCVReturnSuccess)
            let bytes = CVPixelBufferGetDataSize(pixel)
            let hasBaseAddress = CVPixelBufferGetBaseAddress(pixel) != nil
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try #require(hasBaseAddress)
            try #require(bytes > 0)
            decodedBytes += bytes
            frameCount += 1
        }
        try #require(reader.status == .completed,
                     Comment(rawValue: reader.error?.localizedDescription ?? "AVAssetReader did not complete"))
        return .init(width: Int(dimensions.width), height: Int(dimensions.height),
                     frameCount: frameCount, duration: duration, decodedBytes: decodedBytes)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func writeFailure(_ error: Error, caseName: String, project: URL,
                                     revisions: [String: String], root: URL, elapsed: Double) {
        let report: [String: Any] = [
            "case": caseName,
            "status": "failed",
            "project": project.path,
            "revisions": revisions,
            "error": error.localizedDescription,
            "elapsedSeconds": elapsed,
            "artifactsPreserved": true,
            "guiValidated": false,
        ]
        try? writeJSON(report, to: root.appendingPathComponent("real-\(caseName)-failure.json"))
    }
}

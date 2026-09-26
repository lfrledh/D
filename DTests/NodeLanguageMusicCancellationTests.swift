@preconcurrency import AVFoundation
import DInference
@testable import DMLXBackend
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in MRT2 cancellation and recovery through the production E04 music node.
/// This is not GUI, listening, recording, publication, or instantaneous GPU-kernel evidence.
@Suite(.serialized) @MainActor
struct NodeLanguageMusicCancellationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "music-cancel"),
          .timeLimit(.minutes(30)))
    func officialE04MusicCancelsWhileGeneratingThenRecovers() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["D_NODE_LANGUAGE_MUSIC_ACKNOWLEDGED"] == "1")
        let authorization = try #require(environment["D_NODE_LANGUAGE_MUSIC_AUTHORIZATION_SOURCE"])
        let modelURL = URL(fileURLWithPath: try #require(environment["D_NODE_LANGUAGE_MUSIC_MODEL"]))

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let root = support.appendingPathComponent(
            "D/NodeLanguageMusicCancellation/" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let projectURL = root.appendingPathComponent("music-cancel.dproject", isDirectory: true)
        let accessRoot = root.appendingPathComponent("MusicProcessAccess", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accessRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let accessAttributes = try FileManager.default.attributesOfItem(atPath: accessRoot.path)
        let accessPermissions = try #require(accessAttributes[.posixPermissions] as? NSNumber)
        try #require(accessPermissions.intValue & 0o777 == 0o700)
        try #require(!accessRoot.path.hasPrefix(projectURL.path + "/"))
        try #require(!projectURL.path.hasPrefix(accessRoot.path + "/"))
        print("D_NODE_LANGUAGE_REAL_MUSIC_CANCEL_ROOT=\(root.path)")

        let resources = try #require(Bundle.main.resourceURL)
        let musicEngine = try #require(try BundledAudioEngine.resolve(
            resourceDirectory: resources, family: .mrt2Music
        ))
        let settingsSuite = "D.NodeLanguage.MusicCancellation." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: settingsSuite))
        defer { settings.removePersistentDomain(forName: settingsSuite) }
        // This isolated fixture reflects the caller's existing same-revision authorization.
        // It neither accepts a license nor substitutes for a user confirmation.
        settings.set(
            true,
            forKey: "audio.model-use.mrt2-small." + MRT2BackendConfiguration.registeredModelRevision
        )
        let consent = AudioModelUsePermission(settings: settings, model: .mrt2Music)
        let preservedTextData = Data("music cancellation fixture".utf8)
        var ownedStore: ProjectStore?
        var reopenedStore: ProjectStore?
        var runtime: WorkbenchSession?
        var controller: WorkflowController?
        var ownedControllerTask: Task<Void, Never>?
        var musicRevision = "unvalidated"
        let started = Date()
        do {
            let store = try await ProjectStore.create(
                at: projectURL, name: "E04 music cancellation"
            )
            ownedStore = store
            // A pre-existing owned asset must survive cancellation and recovery byte-for-byte.
            let preservedPublication = try await store.publishWorkflowAsset(
                data: preservedTextData,
                mediaType: "text/plain",
                name: "Preserved fixture text",
                operationID: "d.text.publish",
                details: ["origin": "MUSIC-CANCEL-CHECKS r1 owned fixture"]
            )
            let initialArchive = try #require(try await store.workflowState().archive)
            let initialAssetRecords = initialArchive.assets
            let initialProjectAssets = await store.snapshot().assets
            try #require(initialAssetRecords.count == 1)
            let initialRecord = try #require(initialAssetRecords.first)
            try #require(initialRecord.reference == preservedPublication.record.reference)

            let session = try await AppSessionFactory.makeSession(
                artifactDirectory: store.artifactDirectory,
                bundledMusicEngine: musicEngine,
                musicConsent: consent,
                audioAccessRoot: accessRoot
            )
            runtime = session
            let validateMusic = try #require(session.validateMusicModel)
            let musicReference = try await validateMusic(modelURL)
            musicRevision = try #require(musicReference.revision)
            let musicBackendID = try #require(session.musicBackendID)
            let musicIdentity = "music:" + musicRevision
            let services = WorkflowServices(
                store: store,
                session: session,
                defaultIdentity: { kind in kind == .music ? musicIdentity : "" },
                resolveModel: { kind, selected in
                    guard kind == .music, selected == musicIdentity else {
                        throw WorkflowIssue(
                            "Unexpected non-music binding in cancellation check: \(kind.rawValue):\(selected)"
                        )
                    }
                    return .init(
                        identity: musicIdentity,
                        reference: musicReference,
                        backendID: musicBackendID
                    )
                }
            )
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()
            subject.addLanguageExample(.multimodal)
            let exampleError = subject.errorMessage
            let exampleErrorComment = exampleError ?? "E04 could not be added"
            try #require(
                exampleError == nil,
                Comment(rawValue: exampleErrorComment)
            )

            let originalGraph = try #require(subject.graph)
            try #require(originalGraph.name == "E04 同主题四模态")
            let foundMusicNode = originalGraph.nodes.first {
                $0.operationID == "d.music.generate"
            }
            let musicNode = try #require(foundMusicNode)
            let foundPromptNode = originalGraph.nodes.first {
                $0.operationID == "d.text.input" && $0.title == "同一发布文字输入"
            }
            let promptNode = try #require(foundPromptNode)
            let foundNoteNode = originalGraph.nodes.first {
                $0.operationID == "d.value.input" && $0.title == "输入受控音符"
            }
            let noteNode = try #require(foundNoteNode)
            let originalPrompt = try #require(promptNode.parameters["text"]?.string)
            let originalNotesDatum = try #require(noteNode.dataConfiguration?.value)
            let originalNotes = try WorkflowNoteSequence(datum: originalNotesDatum)
            try #require(originalNotes.clock == .quarterNotes)
            try #require(originalNotes.duration == 8)

            subject.setParameter(nodeID: musicNode.id, key: "modelID", value: .text(musicIdentity))
            let expectedDurationFrames = try #require(musicNode.parameters["durationFrames"]?.integer)
            let expectedSeedText = try #require(musicNode.parameters["seed"]?.string)
            let expectedSeed = try #require(UInt64(expectedSeedText))
            try #require(expectedDurationFrames == 100)

            let tempo = WorkflowTempoMap(
                beatsPerMinute: 120, firstBeatSeconds: 0,
                numerator: 4, denominator: 4
            )
            let chords = WorkflowChordTrack(
                chords: [
                    .init(id: "C", root: 0, quality: .major, octave: 4,
                          inversion: 0, start: 0, end: 2),
                    .init(id: "Am", root: 9, quality: .minor, octave: 3,
                          inversion: 0, start: 2, end: 4),
                    .init(id: "F", root: 5, quality: .major, octave: 3,
                          inversion: 0, start: 4, end: 6),
                    .init(id: "G", root: 7, quality: .major, octave: 3,
                          inversion: 0, start: 6, end: 8),
                ],
                duration: 8,
                tempo: tempo
            )
            let chordDatum = try chords.datum()
            subject.addNode(operationID: "d.value.input")
            let chordNodeID = try #require(subject.selectedNodeID)
            subject.setDataConfiguration(nodeID: chordNodeID, value: .init(value: chordDatum))
            subject.connect(
                source: chordNodeID, sourcePort: "output",
                target: musicNode.id, targetPort: "chords"
            )
            let chordConnectionError = subject.errorMessage
            let chordConnectionComment = chordConnectionError
                ?? "Typed chord fixture could not be connected"
            try #require(chordConnectionError == nil,
                         Comment(rawValue: chordConnectionComment))

            let configuredGraph = try #require(subject.graph)
            let musicInputs = configuredGraph.connections.filter { $0.targetNode == musicNode.id }
            try #require(Set(musicInputs.map(\.targetPort)) == Set(["prompt", "notes", "chords"]))
            let foundConfiguredChordNode = configuredGraph.nodes.first { $0.id == chordNodeID }
            let configuredChordNode = try #require(foundConfiguredChordNode)
            try #require(configuredChordNode.operationID == "d.value.input")
            try #require(configuredChordNode.dataConfiguration?.value == chordDatum)
            try Self.requireOriginalE04FixturePreserved(
                originalGraph, in: configuredGraph, except: musicNode.id
            )

            let cancellationTask = Task { @MainActor in
                await subject.run(target: musicNode.id, only: false)
            }
            ownedControllerTask = cancellationTask
            let cancellationObservation = try await Self.awaitGenerating(
                session: session, controller: subject
            )
            await subject.cancel()
            await cancellationTask.value
            ownedControllerTask = nil

            let cancellationError = subject.errorMessage
            let cancellationErrorComment = cancellationError ?? "Cancellation reported an error"
            try #require(cancellationError == nil,
                         Comment(rawValue: cancellationErrorComment))
            let cancelledRun = try #require(subject.runs.last)
            try #require(cancelledRun.status == .cancelled)
            let foundCancelledCall = cancelledRun.planCheckpoint?.records.first {
                $0.step.node.id == musicNode.id
            }
            let cancelledCall = try #require(foundCancelledCall)
            try #require(cancelledCall.step.status == .cancelled)
            try #require(cancelledCall.step.id == cancellationObservation.activeRunID)
            try #require(cancelledCall.step.outputs["output"]?.asset == nil)
            try Self.requireMusicOnlyPath(cancelledRun, musicNodeID: musicNode.id)
            try await Self.requireRuntimeDrained(session)

            let foundCancelledPromptCall = cancelledRun.planCheckpoint?.records.first {
                $0.step.node.id == promptNode.id && $0.step.status == .completed
            }
            let cancelledPromptCall = try #require(foundCancelledPromptCall)
            let cancelledPromptReference = try #require(
                cancelledPromptCall.step.outputs["output"]?.asset
            )
            try #require(cancelledPromptReference.kind == .text)
            let cancelledPromptBytes = try await store.workflowData(cancelledPromptReference)
            try #require(cancelledPromptBytes == Data(originalPrompt.utf8))

            let afterCancellation = try #require(try await store.workflowState().archive)
            let foundCancelledPromptRecord = afterCancellation.assets.first {
                $0.reference == cancelledPromptReference
            }
            let cancelledPromptRecord = try #require(foundCancelledPromptRecord)
            try #require(cancelledPromptRecord.operationID == "d.text.input")
            try #require(cancelledPromptRecord.stepID == cancelledPromptCall.step.id)
            try #require(cancelledPromptRecord.parents.isEmpty)
            try #require(cancelledPromptRecord.request == nil)
            let cancelledMusicWasPublished = afterCancellation.assets.contains {
                $0.operationID == "d.music.generate" || $0.stepID == cancelledCall.step.id
            }
            try #require(!cancelledMusicWasPublished)
            let expectedAfterCancellation = Set(
                initialAssetRecords.map(\.reference) + [cancelledPromptReference]
            )
            try #require(Set(afterCancellation.assets.map(\.reference)) == expectedAfterCancellation)
            let initialWorkflowRecordsAfterCancellation = initialAssetRecords.allSatisfy {
                afterCancellation.assets.contains($0)
            }
            try #require(initialWorkflowRecordsAfterCancellation)
            let projectAssetsAfterCancellation = await store.snapshot().assets
            let expectedProjectAssetIDsAfterCancellation = Set(
                initialProjectAssets.map(\.id) + [cancelledPromptReference.assetID]
            )
            try #require(
                Set(projectAssetsAfterCancellation.map(\.id)) == expectedProjectAssetIDsAfterCancellation
            )
            let initialProjectAssetsAfterCancellation = initialProjectAssets.allSatisfy {
                projectAssetsAfterCancellation.contains($0)
            }
            try #require(initialProjectAssetsAfterCancellation)
            let preservedDataAfterCancellation = try await store.workflowData(
                preservedPublication.record.reference
            )
            try #require(preservedDataAfterCancellation == preservedTextData)
            let graphAfterCancellation = try #require(subject.graph)
            try Self.requireOriginalE04FixturePreserved(
                originalGraph, in: graphAfterCancellation, except: musicNode.id
            )
            let chordNodeAfterCancellation = try #require(
                graphAfterCancellation.nodes.first { $0.id == chordNodeID }
            )
            let currentChordDatum = try #require(chordNodeAfterCancellation.dataConfiguration?.value)
            try #require(currentChordDatum == chordDatum)

            // The recovery run uses the same graph and explicit typed conditions.
            await subject.run(target: musicNode.id, only: false)
            let recoveryError = subject.errorMessage
            let recoveryErrorComment = recoveryError ?? "Recovered music execution failed"
            try #require(recoveryError == nil,
                         Comment(rawValue: recoveryErrorComment))
            let completedRun = try #require(subject.runs.last)
            try #require(completedRun.status == .completed)
            try #require(completedRun.id != cancelledRun.id)
            try #require(completedRun.graph.id == cancelledRun.graph.id)
            try #require(completedRun.graph.revision == cancelledRun.graph.revision)
            try Self.requireMusicOnlyPath(completedRun, musicNodeID: musicNode.id)
            let foundCompletedCall = completedRun.planCheckpoint?.records.first {
                $0.step.node.id == musicNode.id && $0.step.status == .completed
            }
            let completedCall = try #require(foundCompletedCall)
            try #require(completedCall.step.id != cancelledCall.step.id)
            let executedDurationFrames = try #require(
                completedCall.step.node.parameters["durationFrames"]?.integer
            )
            let executedSeedText = try #require(
                completedCall.step.node.parameters["seed"]?.string
            )
            try #require(executedDurationFrames == expectedDurationFrames)
            try #require(executedSeedText == expectedSeedText)
            let output = try #require(completedCall.step.outputs["output"]?.asset)
            try #require(output.kind == .audio)
            let foundCompletedPromptCall = completedRun.planCheckpoint?.records.first {
                $0.step.node.id == promptNode.id && $0.step.status == .completed
            }
            let completedPromptCall = try #require(foundCompletedPromptCall)
            let completedPromptReference = try #require(
                completedPromptCall.step.outputs["output"]?.asset
            )
            try #require(completedPromptReference == cancelledPromptReference)
            let actualNotes = try WorkflowNoteSequence(
                datum: #require(completedCall.step.inputs["notes"]?.datum)
            )
            let actualChords = try WorkflowChordTrack(
                datum: #require(completedCall.step.inputs["chords"]?.datum)
            )
            try #require(try actualNotes.datum() == originalNotesDatum)
            try #require(try actualChords.datum() == chordDatum)
            try #require(actualNotes.sources.isEmpty)
            try #require(actualChords.sources.isEmpty)
            let completedPrompt = try #require(completedCall.step.inputs["prompt"]?.asset)
            try #require(completedPrompt == completedPromptReference)
            let completedPromptBytes = try await store.workflowData(completedPrompt)
            let completedPromptText = try #require(
                String(data: completedPromptBytes, encoding: .utf8)
            )
            try #require(completedPromptText == originalPrompt)

            await subject.save()
            let saveError = subject.errorMessage
            let saveErrorComment = saveError ?? "Recovered workflow save failed"
            try #require(saveError == nil,
                         Comment(rawValue: saveErrorComment))
            try #require(!subject.hasPendingSaves)
            try await Self.requireRuntimeDrained(session)
            let savedArchive = try #require(try await store.workflowState().archive)
            let savedCancelledRun = savedArchive.runs.contains {
                $0.id == cancelledRun.id && $0.status == .cancelled
            }
            let savedCompletedRun = savedArchive.runs.contains {
                $0.id == completedRun.id && $0.status == .completed
            }
            try #require(savedCancelledRun)
            try #require(savedCompletedRun)
            let preservedInitialRecords = initialAssetRecords.allSatisfy {
                savedArchive.assets.contains($0)
            }
            try #require(preservedInitialRecords)
            let foundRecord = savedArchive.assets.first { $0.reference == output }
            let record = try #require(foundRecord)
            try #require(record.operationID == "d.music.generate")
            try #require(record.stepID == completedCall.step.id)
            let actualInputParents = Set(completedCall.step.inputs.values.flatMap {
                $0.datum?.assetReferences ?? []
            })
            try #require(actualInputParents == Set([completedPromptReference]))
            try #require(Set(record.parents) == actualInputParents)
            try #require(record.parents.count == actualInputParents.count)
            let request = try #require(record.request)
            try #require(request.id == completedCall.step.id)
            try #require(request.id != cancellationObservation.activeRunID)
            try #require(request.model == musicReference)
            guard case .audio(let audioRequest) = request.input else {
                throw WorkflowIssue("Recovered music output did not retain its audio request.")
            }
            try #require(audioRequest.operation == .generate)
            try #require(audioRequest.prompt == completedPromptText)
            try #require(audioRequest.seed == expectedSeed)
            try #require(audioRequest.durationSeconds == Double(expectedDurationFrames) / 25)
            try #require(audioRequest.source == nil)
            try #require(audioRequest.editRegion == nil)
            let condition = try #require(audioRequest.noteSequence)
            try #require(condition.durationFrames == expectedDurationFrames)
            try Self.verifyCondition(condition, notes: actualNotes, chords: actualChords)

            let allowedFinalReferences = Set(
                initialAssetRecords.map(\.reference) + [completedPromptReference, output]
            )
            try #require(Set(savedArchive.assets.map(\.reference)) == allowedFinalReferences)
            let finalProjectAssets = await store.snapshot().assets
            let allowedFinalAssetIDs = Set(
                initialProjectAssets.map(\.id)
                    + [completedPromptReference.assetID, output.assetID]
            )
            try #require(Set(finalProjectAssets.map(\.id)) == allowedFinalAssetIDs)
            let initialProjectAssetsAfterRecovery = initialProjectAssets.allSatisfy {
                finalProjectAssets.contains($0)
            }
            try #require(initialProjectAssetsAfterRecovery)

            let storedMedia = try await store.workflowMedia(output)
            try #require(storedMedia.1.mediaType == "audio/wav")
            let registeredAudio = try #require(storedMedia.1.metadata.audio)
            try #require(registeredAudio.origin == .modelGenerated)
            let inspection = try AudioMediaInspector.inspect(at: storedMedia.0, policy: .generated)
            try #require(inspection.format == registeredAudio.format)
            try #require(inspection.contentSHA256 == registeredAudio.contentSHA256)
            try #require(inspection.contentSHA256 == output.sha256)
            let durationSeconds = Double(inspection.format.frameCount) / inspection.format.sampleRate
            let durationTolerance = 1 / inspection.format.sampleRate
            try #require(abs(durationSeconds - 4) <= durationTolerance)
            let decoded = try Self.requireFiniteNonzeroWAV(storedMedia.0)

            let finalGraph = try #require(subject.graph)
            try Self.requireOriginalE04FixturePreserved(
                originalGraph, in: finalGraph, except: musicNode.id
            )
            let foundFinalChordNode = finalGraph.nodes.first { $0.id == chordNodeID }
            let finalChordNode = try #require(foundFinalChordNode)
            let finalChordDatum = try #require(finalChordNode.dataConfiguration?.value)
            try #require(finalChordDatum == chordDatum)
            let finalPreservedData = try await store.workflowData(
                preservedPublication.record.reference
            )
            try #require(finalPreservedData == preservedTextData)

            let report: [String: Any] = [
                "case": "music-cancel",
                "driver": "Bundle.main MRT2 engine + AppSessionFactory + WorkflowController + official E04 music node",
                "project": projectURL.path,
                "resourceRoot": resources.path,
                "accessRoot": accessRoot.path,
                "musicRevision": musicRevision,
                "authorizationSource": authorization,
                "consent": "isolated fixture reflecting prior explicit same-revision development authorization; not a new click",
                "cancelledWorkflowRunID": cancelledRun.id.uuidString,
                "cancelledCallID": cancelledCall.step.id.uuidString,
                "cancelledBackendRunID": cancellationObservation.activeRunID.uuidString,
                "cancelledObservedState": cancellationObservation.state.rawValue,
                "cancelledObservedPhase": cancellationObservation.phase ?? "unknown",
                "cancellationEvidence": "runtime state .generating; GPU-kernel interruption timing not asserted",
                "completedRunID": completedRun.id.uuidString,
                "completedCallID": completedCall.step.id.uuidString,
                "promptCallID": cancelledPromptCall.step.id.uuidString,
                "promptAssetID": completedPromptReference.assetID.uuidString,
                "requestID": request.id.uuidString,
                "requestSeed": audioRequest.seed.description,
                "outputAssetID": output.assetID.uuidString,
                "outputSHA256": output.sha256,
                "mediaPath": storedMedia.0.path,
                "durationSeconds": durationSeconds,
                "sampleRate": inspection.format.sampleRate,
                "frameCount": inspection.format.frameCount,
                "channelCount": inspection.format.channelCount,
                "decodedFrames": decoded.frameCount,
                "peakMagnitude": decoded.peakMagnitude,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "guiValidated": false,
                "listeningValidated": false,
                "recordingValidated": false,
            ]

            try await subject.close()
            controller = nil
            let finalArchive = try #require(try await store.workflowState().archive)
            try await store.close()
            ownedStore = nil
            let reopened = try await ProjectStore.open(at: projectURL)
            reopenedStore = reopened
            let reopenedArchive = try #require(try await reopened.workflowState().archive)
            try #require(reopenedArchive == finalArchive)
            try #require(Set(reopenedArchive.assets.map(\.reference)) == allowedFinalReferences)
            let reopenedInitialWorkflowRecords = initialAssetRecords.allSatisfy {
                reopenedArchive.assets.contains($0)
            }
            try #require(reopenedInitialWorkflowRecords)
            let reopenedProjectAssets = await reopened.snapshot().assets
            try #require(Set(reopenedProjectAssets.map(\.id)) == allowedFinalAssetIDs)
            let reopenedInitialProjectAssets = initialProjectAssets.allSatisfy {
                reopenedProjectAssets.contains($0)
            }
            try #require(reopenedInitialProjectAssets)
            let reopenedPreservedData = try await reopened.workflowData(
                preservedPublication.record.reference
            )
            try #require(reopenedPreservedData == preservedTextData)
            let reopenedPromptData = try await reopened.workflowData(completedPromptReference)
            try #require(reopenedPromptData == completedPromptBytes)
            let reopenedMedia = try await reopened.workflowMedia(output)
            let reopenedInspection = try AudioMediaInspector.inspect(
                at: reopenedMedia.0, policy: .generated
            )
            try #require(reopenedInspection.format == inspection.format)
            try #require(reopenedInspection.contentSHA256 == inspection.contentSHA256)
            _ = try Self.requireFiniteNonzeroWAV(reopenedMedia.0)
            try await reopened.close()
            reopenedStore = nil
            await session.shutdown()
            runtime = nil
            try Self.writeJSON(report, to: root.appendingPathComponent("music-cancel-result.json"))
            print("D_NODE_LANGUAGE_REAL_MUSIC_CANCEL_PASS=\(root.path)")
        } catch {
            let primaryError = error
            var cleanupErrors: [String] = []
            ownedControllerTask?.cancel()
            if let controller { await controller.cancel() }
            if let task = ownedControllerTask {
                await task.value
                ownedControllerTask = nil
            }
            if let controller {
                do { try await controller.close() }
                catch { cleanupErrors.append("controller.close: \(error.localizedDescription)") }
            }
            if let runtime { await runtime.shutdown() }
            if let reopenedStore {
                do { try await reopenedStore.close(preserveExternalChanges: true) }
                catch { cleanupErrors.append("reopenedStore.close: \(error.localizedDescription)") }
            }
            if let ownedStore {
                do { try await ownedStore.close(preserveExternalChanges: true) }
                catch { cleanupErrors.append("store.close: \(error.localizedDescription)") }
            }
            do {
                try Self.writeFailure(
                    primaryError,
                    cleanupErrors: cleanupErrors,
                    project: projectURL,
                    revision: musicRevision,
                    root: root,
                    elapsed: Date().timeIntervalSince(started)
                )
            } catch {
                cleanupErrors.append("failure-report: \(error.localizedDescription)")
            }
            if cleanupErrors.isEmpty { throw primaryError }
            throw CleanupFailure(primary: primaryError, cleanupErrors: cleanupErrors)
        }
    }

    private struct RuntimeObservation {
        let activeRunID: UUID
        let state: JobState
        let phase: String?
    }

    private struct DecodedAudioSummary {
        let frameCount: Int
        let peakMagnitude: Float
    }

    private struct CleanupFailure: LocalizedError {
        let primary: Error
        let cleanupErrors: [String]

        var errorDescription: String? {
            "Primary failure: \(primary.localizedDescription) | Cleanup failures: "
                + cleanupErrors.joined(separator: " | ")
        }
    }

    private static func awaitGenerating(
        session: WorkbenchSession,
        controller: WorkflowController
    ) async throws -> RuntimeObservation {
        var observedControllerRunning = false
        for _ in 0..<9_000 {
            let status = await session.status()
            if status.state == .generating, let activeRunID = status.activeRunID {
                return .init(activeRunID: activeRunID, state: .generating, phase: status.phase)
            }
            if controller.isRunning {
                observedControllerRunning = true
            } else if observedControllerRunning {
                throw WorkflowIssue(
                    "Music execution completed before runtime .generating was observed; cancellation evidence is insufficient."
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkflowIssue(
            "Runtime .generating was not observed within 180 seconds; cancellation evidence is unavailable."
        )
    }

    private static func requireRuntimeDrained(_ session: WorkbenchSession) async throws {
        let status = await session.status()
        try #require(status.activeRunID == nil)
        try #require(status.queuedRunIDs.isEmpty)
    }

    private static func requireMusicOnlyPath(
        _ run: WorkflowRun,
        musicNodeID: UUID
    ) throws {
        let records = try #require(run.planCheckpoint?.records)
        let allowed = Set(["d.text.input", "d.value.input", "d.music.generate"])
        let containsMusic = records.contains { $0.step.node.id == musicNodeID }
        let containsOnlyAllowed = records.allSatisfy { allowed.contains($0.step.node.operationID) }
        let containsOtherModel = records.contains { record in
            ["d.model.language", "d.image.generate", "d.video.generate"].contains(
                record.step.node.operationID
            )
        }
        try #require(containsMusic)
        try #require(containsOnlyAllowed)
        try #require(!containsOtherModel)
    }

    private static func requireOriginalE04FixturePreserved(
        _ original: WorkflowGraph,
        in current: WorkflowGraph,
        except mutableNodeID: UUID
    ) throws {
        try #require(original.id == current.id)
        for node in original.nodes where node.id != mutableNodeID {
            let currentNode = current.nodes.first { $0.id == node.id }
            try #require(currentNode == node)
        }
        for connection in original.connections {
            try #require(current.connections.contains(connection))
        }
    }

    /// Independent occupancy/onset oracle proving both typed note and chord inputs reached MRT2.
    private static func verifyCondition(
        _ actual: AudioNoteSequence,
        notes: WorkflowNoteSequence,
        chords: WorkflowChordTrack
    ) throws {
        try #require(actual.durationFrames == 100)
        var expectedHeld = Set<String>()
        var expectedOnsets = Set<String>()
        func add(_ pitch: Int, _ start: Double, _ end: Double) {
            let first = Int((start * 25).rounded(.toNearestOrAwayFromZero))
            let last = Int((end * 25).rounded(.toNearestOrAwayFromZero))
            if last > first {
                expectedOnsets.insert("\(pitch):\(first)")
                for frame in first..<last { expectedHeld.insert("\(pitch):\(frame)") }
            }
        }
        let noteTempo = try #require(notes.tempo)
        for note in notes.notes where note.velocity > 0 {
            add(
                note.pitch,
                noteTempo.firstBeatSeconds + note.start * 60 / noteTempo.beatsPerMinute,
                noteTempo.firstBeatSeconds + note.end * 60 / noteTempo.beatsPerMinute
            )
        }
        let chordTempo = try #require(chords.tempo)
        for chord in chords.chords {
            let intervals: [Int] = switch chord.quality {
            case .major: [0, 4, 7]
            case .minor: [0, 3, 7]
            case .dominant7: [0, 4, 7, 10]
            case .major7: [0, 4, 7, 11]
            case .minor7: [0, 3, 7, 10]
            case .diminished: [0, 3, 6]
            }
            for (index, interval) in intervals.enumerated() {
                add(
                    (chord.octave + 1) * 12 + chord.root + interval
                        + (index < chord.inversion ? 12 : 0),
                    chordTempo.firstBeatSeconds + chord.start * 60 / chordTempo.beatsPerMinute,
                    chordTempo.firstBeatSeconds + chord.end * 60 / chordTempo.beatsPerMinute
                )
            }
        }
        var observedHeld = Set<String>()
        var observedOnsets = Set<String>()
        let actualNotes = try #require(actual.notes)
        for note in actualNotes {
            observedOnsets.insert("\(note.pitch):\(note.startFrame)")
            for frame in note.startFrame..<note.endFrame {
                observedHeld.insert("\(note.pitch):\(frame)")
            }
        }
        try #require(observedHeld == expectedHeld)
        try #require(observedOnsets == expectedOnsets)
    }

    private static func requireFiniteNonzeroWAV(_ url: URL) throws -> DecodedAudioSummary {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ))
        try file.read(into: buffer)
        try #require(buffer.frameLength > 0)
        let channels = try #require(buffer.floatChannelData)
        var peak: Float = 0
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            let samples = UnsafeBufferPointer(
                start: channels[channelIndex],
                count: Int(buffer.frameLength)
            )
            let allFinite = samples.allSatisfy { $0.isFinite }
            try #require(allFinite)
            for sample in samples { peak = max(peak, abs(sample)) }
        }
        try #require(peak > 0.00001)
        return .init(frameCount: Int(buffer.frameLength), peakMagnitude: peak)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func writeFailure(
        _ error: Error,
        cleanupErrors: [String],
        project: URL,
        revision: String,
        root: URL,
        elapsed: Double
    ) throws {
        let report: [String: Any] = [
            "case": "music-cancel",
            "status": "failed",
            "project": project.path,
            "musicRevision": revision,
            "primaryError": error.localizedDescription,
            "cleanupErrors": cleanupErrors,
            "elapsedSeconds": elapsed,
            "artifactsPreserved": true,
            "guiValidated": false,
            "listeningValidated": false,
            "recordingValidated": false,
        ]
        try writeJSON(report, to: root.appendingPathComponent("music-cancel-failure.json"))
    }
}

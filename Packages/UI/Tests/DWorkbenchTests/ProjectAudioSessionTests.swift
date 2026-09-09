import DInference
import Foundation
import Observation
import Synchronization
import Testing
@testable import DWorkbench

private actor AudioSessionEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) throws -> InferenceRun {
        InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() },
                     cancel: {}, outcome: { .cancelled })
    }
}

private actor AudioSessionGate {
    private(set) var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SessionPlaybackDevice: AudioPlaybackDevice {
    var currentFrame: Int64 = 0
    private(set) var stopCount = 0
    func playSegment(startFrame: Int64, frameCount: Int64,
                     completion: @escaping @MainActor @Sendable (String?) -> Void) throws -> Bool {
        currentFrame = startFrame
        return true
    }
    func pause() -> Int64 { currentFrame }
    func stop() { stopCount += 1 }
}

@MainActor
private final class SessionRecordingDevice: AudioRecordingDevice {
    let url: URL
    var currentSeconds = 0.01
    var stopError: String?
    var corruptOnStop = false
    private(set) var stopCount = 0
    private var completion: (@MainActor @Sendable (AudioRecordingResult) -> Void)?

    init(url: URL) { self.url = url }
    func start(completion: @escaping @MainActor @Sendable (AudioRecordingResult) -> Void) throws -> Bool {
        self.completion = completion
        return true
    }
    func stop(error: String?) -> AudioRecordingResult {
        stopCount += 1
        if corruptOnStop { try? Data("truncated".utf8).write(to: url) }
        return .init(url: url, error: error ?? stopError)
    }
    func finishFromDevice(error: String? = nil) {
        stopCount += 1
        completion?(.init(url: url, error: error))
    }
}

@MainActor
private final class SessionAudioFactory: AudioTransportDeviceFactory {
    var permissionResult = true
    var suspendPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var configureRecording: ((SessionRecordingDevice) -> Void)?
    private(set) var permissionRequests = 0
    private(set) var playbacks: [SessionPlaybackDevice] = []
    private(set) var recordings: [SessionRecordingDevice] = []

    func requestRecordPermission() async -> Bool {
        permissionRequests += 1
        if suspendPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return permissionResult
    }
    func resolvePermission(_ value: Bool) {
        permissionContinuation?.resume(returning: value)
        permissionContinuation = nil
    }
    func makePlayback(url: URL, expected: AudioFormatInfo) throws -> any AudioPlaybackDevice {
        let device = SessionPlaybackDevice()
        playbacks.append(device)
        return device
    }
    func makeRecording(url: URL) throws -> any AudioRecordingDevice {
        try AudioTestMedia.writePCM(to: url, samples: [[0, 0.25, -0.25, 0.5]],
                                    sampleRate: 8_000, bitDepth: 32, floatingPoint: true)
        let device = SessionRecordingDevice(url: url)
        configureRecording?(device)
        recordings.append(device)
        return device
    }
}

@Suite("Project audio session", .serialized)
@MainActor
struct ProjectAudioSessionTests {
    private struct Fixture {
        let root: URL
        let project: URL
        let settings: UserDefaults
        let settingsName: String
    }

    private func fixture(_ name: String) throws -> Fixture {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("audio-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsName = "D.ProjectAudioSessionTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        return Fixture(root: root.resolvingSymlinksInPath(),
                       project: root.resolvingSymlinksInPath().appendingPathComponent("\(name).dproject"),
                       settings: settings, settingsName: settingsName)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.settings.removePersistentDomain(forName: fixture.settingsName)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func session(_ fixture: Fixture, factory: SessionAudioFactory,
                         recording: Bool = false) -> ProjectSession {
        let engine = AudioSessionEngine()
        let transport = AudioTransport(recordingEnabled: recording, deviceFactory: factory)
        return ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "test.audio.session", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: {}, validateModel: { _ in },
            textBackendID: "test.text")
        }, settings: fixture.settings, audioEnabled: true,
        audioRecordingEnabled: recording, audioTransport: transport)
    }

    private func source(in fixture: Fixture, name: String = "source.wav") throws -> URL {
        let url = fixture.root.appendingPathComponent(name)
        try AudioTestMedia.writePCM(to: url, samples: [[0, 0.25, -0.5, 0.75]],
                                    sampleRate: 8_000, bitDepth: 32, floatingPoint: true)
        return url
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func importEditCloseReopenAndExportsPreserveBytesAndPreparePlayback() async throws {
        let f = try fixture("Lifecycle")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        let subject = session(f, factory: factory)
        let input = try source(in: f)
        let inputBytes = try Data(contentsOf: input)

        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: input, name: "原声 🎙️"))
        let audio = try #require(subject.audio)
        let context = audio.contextID
        let documentID = try #require(audio.documentID)
        #expect(audio.transport.state == .recorded)
        #expect(!factory.playbacks.isEmpty)

        let note = "Cafe\u{301} 🎧"
        #expect(subject.setAudioNoteInput(note, contextID: context, documentID: documentID))
        #expect(await subject.saveAudioNote(contextID: context, documentID: documentID))
        #expect(subject.setAudioClipInput(name: "片段", range: .init(startFrame: 1, endFrame: 3),
                                          note: "保留", contextID: context, documentID: documentID))
        #expect(await subject.addAudioClip(contextID: context, documentID: documentID))
        let clip = try #require(audio.document?.clips.first)
        #expect(await subject.selectAudioClip(id: clip.id, contextID: context, documentID: documentID))

        let original = f.root.appendingPathComponent("original-export.wav")
        let clipped = f.root.appendingPathComponent("clip-export.wav")
        #expect(await subject.exportOriginalAudio(to: original, contextID: context, documentID: documentID))
        #expect(await subject.exportAudioClip(id: clip.id, to: clipped,
                                              contextID: context, documentID: documentID))
        #expect(try Data(contentsOf: original) == inputBytes)
        #expect(try AudioMediaInspector.inspect(at: clipped).format.frameCount == 2)

        #expect(await subject.requestClose())
        await subject.openProject(at: f.project)
        let reopened = try #require(subject.audio)
        let reopenedID = try #require(reopened.documentID)
        #expect(reopened.contextID != context)
        #expect(await subject.refreshActiveAudioInspection(contextID: reopened.contextID,
                                                            documentID: reopenedID))
        #expect(reopened.transport.state == .recorded)
        #expect(reopened.document?.note.utf8.elementsEqual(note.utf8) == true)
        #expect(reopened.document?.clips == [clip])
        #expect(!audio.setNoteInput("stale", contextID: context, documentID: documentID))
    }

    @Test
    func canonicallyEqualTextRemainsByteDirtyAndRapidSavesUseConsecutiveRevisions() async throws {
        let f = try fixture("UTF8")
        defer { cleanup(f) }
        let subject = session(f, factory: SessionAudioFactory())
        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: try source(in: f), name: "bytes"))
        let audio = try #require(subject.audio)
        let context = audio.contextID
        let documentID = try #require(audio.documentID)
        let composed = "é 🎼"
        let decomposed = "e\u{301} 🎼"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))

        #expect(subject.setAudioNoteInput(composed, contextID: context, documentID: documentID))
        #expect(await subject.saveAudioNote(contextID: context, documentID: documentID))
        let observed = Mutex(false)
        withObservationTracking {
            _ = audio.hasUnsubmittedInput
        } onChange: {
            observed.withLock { $0 = true }
        }
        #expect(subject.setAudioNoteInput(decomposed, contextID: context, documentID: documentID))
        #expect(observed.withLock { $0 })
        #expect(audio.isDirty)
        let first = Task { await subject.saveAudioNote(contextID: context, documentID: documentID) }
        await Task.yield()
        let newest = decomposed + "!"
        #expect(subject.setAudioNoteInput(newest, contextID: context, documentID: documentID))
        let second = Task { await subject.saveAudioNote(contextID: context, documentID: documentID) }
        #expect(await first.value)
        #expect(await second.value)
        #expect(audio.document?.revision == 3)
        #expect(audio.document?.note.utf8.elementsEqual(newest.utf8) == true)
        #expect(!audio.isDirty)
    }

    @Test
    func invalidRangeAndDirtyInputBlockNavigationUntilExplicitDiscard() async throws {
        let f = try fixture("Dirty")
        defer { cleanup(f) }
        let subject = session(f, factory: SessionAudioFactory())
        await subject.createProject(at: f.project)
        let imageID = try #require(subject.activeDocumentID)
        #expect(await subject.importAudio(at: try source(in: f), name: "dirty"))
        let audio = try #require(subject.audio)
        let context = audio.contextID
        let documentID = try #require(audio.documentID)
        let originalDraft = try #require(audio.document)

        #expect(subject.setAudioClipInput(name: "bad", range: .init(startFrame: 0, endFrame: 99),
                                          contextID: context, documentID: documentID))
        #expect(!(await subject.addAudioClip(contextID: context, documentID: documentID)))
        #expect(audio.document == originalDraft)
        #expect(audio.clipNameInput == "bad")
        await subject.selectDocument(id: imageID)
        #expect(subject.activeDocumentID == documentID)
        #expect(!(await subject.requestClose()))

        #expect(subject.discardAudioEditorInput(contextID: context, documentID: documentID))
        for index in 0..<AudioLimits.maximumClips {
            #expect(subject.setAudioClipInput(name: "clip \(index)",
                range: .init(startFrame: 0, endFrame: 1),
                contextID: context, documentID: documentID))
            #expect(await subject.addAudioClip(contextID: context, documentID: documentID))
        }
        #expect(subject.setAudioClipInput(name: "overflow", range: .init(startFrame: 0, endFrame: 1),
                                          contextID: context, documentID: documentID))
        #expect(!(await subject.addAudioClip(contextID: context, documentID: documentID)))
        #expect(audio.document?.clips.count == AudioLimits.maximumClips)
        #expect(audio.clipNameInput == "overflow")
        #expect(subject.discardAudioEditorInput(contextID: context, documentID: documentID))
        await subject.selectDocument(id: imageID)
        #expect(subject.activeDocumentID == imageID)
        await subject.createTextDocument(name: "text")
        #expect(subject.activeDocument?.kind == .text)
        await subject.showAllArtworks()
        #expect(subject.visibleAssets.allSatisfy { $0.mediaType == "image/png" })
        #expect(!subject.visibleAssets.contains { $0.metadata.audio != nil })
    }

    @Test
    func externalSaveFailureKeepsPersistedDraftOriginalAndExactInputForRetry() async throws {
        let f = try fixture("Failure")
        defer { cleanup(f) }
        let subject = session(f, factory: SessionAudioFactory())
        let input = try source(in: f)
        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: input, name: "failure"))
        let audio = try #require(subject.audio)
        let context = audio.contextID
        let documentID = try #require(audio.documentID)
        let owned = try #require(audio.inspection?.url)
        let ownedBytes = try Data(contentsOf: owned)
        let manifestURL = f.project.appendingPathComponent(ProjectStore.manifestFilename)
        let originalManifestBytes = try Data(contentsOf: manifestURL)
        var external = try JSONDecoder().decode(ProjectManifest.self, from: originalManifestBytes)
        external.name += " external"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(external).write(to: manifestURL)

        let value = "unsaved e\u{301} 🔒"
        #expect(subject.setAudioNoteInput(value, contextID: context, documentID: documentID))
        #expect(!(await subject.saveAudioNote(contextID: context, documentID: documentID)))
        #expect(audio.document?.revision == 0)
        #expect(audio.noteInput.utf8.elementsEqual(value.utf8))
        #expect(audio.isDirty)
        #expect(try Data(contentsOf: owned) == ownedBytes)

        try originalManifestBytes.write(to: manifestURL)
        #expect(await subject.saveAudioNote(contextID: context, documentID: documentID))
        #expect(audio.document?.note.utf8.elementsEqual(value.utf8) == true)
    }

    @Test
    func disabledRecordingNeverReservesOrRequestsPermission() async throws {
        let f = try fixture("Disabled")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        let subject = session(f, factory: factory, recording: false)
        await subject.createProject(at: f.project)
        #expect(!(await subject.startAudioRecording(name: "disabled")))
        #expect(factory.permissionRequests == 0)
        #expect(subject.manifest?.pendingAudioCaptures.isEmpty == true)
        #expect(factory.recordings.isEmpty)
    }

    @Test
    func cancelledPermissionDoesNotBlockCloseAndLateGrantCannotStartOrReuseContext() async throws {
        let f = try fixture("Permission")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        factory.suspendPermission = true
        let subject = session(f, factory: factory, recording: true)
        await subject.createProject(at: f.project)
        let oldContext = try #require(subject.audio?.contextID)
        let starting = Task { await subject.startAudioRecording(name: "pending") }
        try await waitUntil { subject.audio?.transport.state == .requestingPermission }
        #expect(subject.manifest?.pendingAudioCaptures.count == 1)
        #expect(await subject.finishAudioRecording())
        #expect(await subject.requestClose())
        factory.resolvePermission(true)
        #expect(!(await starting.value))
        #expect(factory.recordings.isEmpty)

        await subject.openProject(at: f.project)
        #expect(subject.audio?.contextID != oldContext)
        #expect(subject.manifest?.pendingAudioCaptures.count == 1)
        #expect(subject.audio?.transport.state != .recording)
    }

    @Test
    func cancellingSecondPermissionAfterSuccessfulRecordingKeepsOldRecordedURLButNotNewOwnership() async throws {
        let f = try fixture("SecondPermission")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        let subject = session(f, factory: factory, recording: true)
        await subject.createProject(at: f.project)

        #expect(await subject.startAudioRecording(name: "first"))
        #expect(await subject.finishAudioRecording())
        let controller = try #require(subject.audio)
        let oldContext = controller.contextID
        let oldRecordedURL = try #require(controller.transport.recordedURL)
        #expect(controller.transport.state == .recorded)
        #expect(factory.recordings.count == 1)

        factory.suspendPermission = true
        let second = Task { await subject.startAudioRecording(name: "second pending") }
        try await waitUntil { controller.transport.state == .requestingPermission }
        let secondReservation = try #require(subject.manifest?.pendingAudioCaptures.first)
        #expect(secondReservation.id != subject.manifest?.assets.first?.id)
        #expect(await subject.finishAudioRecording())
        #expect(controller.transport.state == .recorded)
        #expect(controller.transport.recordedURL == oldRecordedURL)
        #expect(await subject.requestClose())

        factory.resolvePermission(true)
        #expect(!(await second.value))
        #expect(factory.recordings.count == 1)
        await subject.openProject(at: f.project)
        #expect(subject.audio?.contextID != oldContext)
        #expect(subject.manifest?.pendingAudioCaptures.contains(secondReservation) == true)
        #expect(subject.manifest?.assets.contains { $0.id == secondReservation.id } == false)
    }

    @Test
    func recordingStopsBeforeNavigationAndPreparedPlaybackIsReleasedBeforeRecording() async throws {
        let f = try fixture("Navigation")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        let subject = session(f, factory: factory, recording: true)
        await subject.createProject(at: f.project)

        #expect(await subject.startAudioRecording(name: "from image"))
        let firstDevice = try #require(factory.recordings.first)
        #expect(!subject.keepPendingAudioCaptureForRecovery(id:
            try #require(subject.manifest?.pendingAudioCaptures.first?.id)))
        await subject.createDocument(name: "after recording")
        #expect(firstDevice.stopCount == 1)
        #expect(subject.audio?.transport.state != .recording)
        #expect(subject.activeDocument?.kind == .image)

        #expect(await subject.importAudio(at: try source(in: f, name: "prepared.wav"), name: "prepared"))
        let playback = try #require(factory.playbacks.last)
        #expect(subject.audio?.transport.state == .recorded)
        #expect(await subject.startAudioRecording(name: "after playback"))
        #expect(playback.stopCount == 1)
        #expect(await subject.finishAudioRecording())

        await subject.createTextDocument(name: "text source")
        #expect(await subject.startAudioRecording(name: "from text"))
        let textDevice = try #require(factory.recordings.last)
        await subject.selectDocument(id: try #require(subject.documents.first?.id))
        #expect(textDevice.stopCount == 1)
        #expect(subject.audio?.transport.state != .recording)
    }

    @Test
    func autostopSettlesOnceAndFinalizeFailureRetainsRegisteredRawForExplicitRetry() async throws {
        let f = try fixture("Finalize")
        defer { cleanup(f) }
        let factory = SessionAudioFactory()
        let subject = session(f, factory: factory, recording: true)
        await subject.createProject(at: f.project)

        #expect(await subject.startAudioRecording(name: "autostop"))
        let automatic = try #require(factory.recordings.last)
        automatic.finishFromDevice()
        try await waitUntil { subject.audio?.isBusy == false }
        #expect(automatic.stopCount == 1)
        #expect(subject.manifest?.pendingAudioCaptures.isEmpty == true)
        #expect(subject.manifest?.documents.filter { $0.kind == .audio }.count == 1)

        factory.configureRecording = { $0.corruptOnStop = true }
        #expect(await subject.startAudioRecording(name: "recoverable"))
        let reservation = try #require(subject.manifest?.pendingAudioCaptures.first)
        #expect(!(await subject.finishAudioRecording()))
        let raw = f.project.appendingPathComponent(reservation.relativePath)
        #expect(try Data(contentsOf: raw) == Data("truncated".utf8))
        #expect(subject.manifest?.pendingAudioCaptures.contains(reservation) == true)
        #expect(!(await subject.requestClose()))

        let controller = try #require(subject.audio)
        let currentDocument = try #require(controller.documentID)
        #expect(subject.setAudioNoteInput("blocks recovery", contextID: controller.contextID,
                                          documentID: currentDocument))
        #expect(!(await subject.retryPendingAudioCapture(id: reservation.id)))
        #expect(subject.manifest?.pendingAudioCaptures.contains(reservation) == true)
        #expect(!(await subject.retryPendingAudioCapture(id: UUID())))
        #expect(subject.discardAudioEditorInput(contextID: controller.contextID,
                                                documentID: currentDocument))

        try AudioTestMedia.writePCM(to: raw, samples: [[0, 0.1, 0.2, 0.3]],
                                    sampleRate: 8_000, bitDepth: 32, floatingPoint: true)
        factory.configureRecording = nil
        #expect(await subject.retryPendingAudioCapture(id: reservation.id))
        #expect(subject.manifest?.pendingAudioCaptures.contains(reservation) == false)
        #expect(subject.manifest?.assets.contains { $0.id == reservation.id } == true)
    }

    @Test
    func relocationCreatesFreshStoreContextAndRejectsOldController() async throws {
        let f = try fixture("Relocate")
        defer { cleanup(f) }
        let subject = session(f, factory: SessionAudioFactory())
        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: try source(in: f), name: "move"))
        let old = try #require(subject.audio)
        let oldContext = old.contextID
        let oldDocument = try #require(old.documentID)
        let moved = f.root.appendingPathComponent("Moved.dproject")
        try FileManager.default.moveItem(at: f.project, to: moved)

        await subject.openProject(at: moved)
        let fresh = try #require(subject.audio)
        #expect(fresh.contextID != oldContext)
        #expect(!old.setNoteInput("old", contextID: oldContext, documentID: oldDocument))
        let freshDocument = try #require(fresh.documentID)
        #expect(subject.setAudioNoteInput("new", contextID: fresh.contextID, documentID: freshDocument))
        #expect(await subject.saveAudioNote(contextID: fresh.contextID, documentID: freshDocument))
        #expect(fresh.document?.note == "new")
        #expect(await subject.refreshActiveAudioInspection(contextID: fresh.contextID,
                                                            documentID: freshDocument))
    }

    @Test
    func closeClosesBothSessionAndControllerAdmissionBeforeSuspendedCleanup() async throws {
        let f = try fixture("CloseAdmission")
        defer { cleanup(f) }
        let gate = AudioSessionGate()
        let engine = AudioSessionEngine()
        let factory = SessionAudioFactory()
        let transport = AudioTransport(deviceFactory: factory)
        let subject = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "test.close.audio", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: { await gate.wait() }, validateModel: { _ in })
        }, settings: f.settings, audioEnabled: true, audioTransport: transport)
        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: try source(in: f), name: "close"))
        let controller = try #require(subject.audio)
        let context = controller.contextID
        let documentID = try #require(controller.documentID)

        let closing = Task { await subject.requestClose() }
        try await waitUntil { await gate.reached }
        #expect(!subject.setAudioNoteInput("late", contextID: context, documentID: documentID))
        #expect(!controller.setNoteInput("direct late", contextID: context, documentID: documentID))
        #expect(controller.noteInput.isEmpty)
        await gate.open()
        #expect(await closing.value)
    }

    @Test
    func explicitRangeExportRejectsInvalidRangeWithoutChangingSavedSelection() async throws {
        let f = try fixture("Range")
        defer { cleanup(f) }
        let subject = session(f, factory: SessionAudioFactory())
        await subject.createProject(at: f.project)
        #expect(await subject.importAudio(at: try source(in: f), name: "range"))
        let audio = try #require(subject.audio)
        let context = audio.contextID
        let documentID = try #require(audio.documentID)
        let selectedBefore = audio.document?.selectedClipID
        let invalidTarget = f.root.appendingPathComponent("invalid-range.wav")
        #expect(!(await subject.exportAudioRange(.init(startFrame: 3, endFrame: 30),
                                                  to: invalidTarget, contextID: context,
                                                  documentID: documentID)))
        #expect(!FileManager.default.fileExists(atPath: invalidTarget.path))
        #expect(audio.document?.selectedClipID == selectedBefore)

        let target = f.root.appendingPathComponent("explicit-range.wav")
        #expect(await subject.exportAudioRange(.init(startFrame: 0, endFrame: 2), to: target,
                                               contextID: context, documentID: documentID))
        #expect(try AudioMediaInspector.inspect(at: target).format.frameCount == 2)
        #expect(audio.document?.selectedClipID == selectedBefore)
    }
}

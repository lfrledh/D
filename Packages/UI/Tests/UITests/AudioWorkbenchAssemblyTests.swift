import AppKit
import DInference
@testable import DWorkbench
import Foundation
import Testing
import SwiftUI
@testable import UI

private struct AudioAssemblyEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        InferenceRun(
            id: request.id,
            events: AsyncThrowingStream { $0.finish() },
            cancel: {},
            outcome: { .cancelled }
        )
    }
}

@MainActor
private final class AssemblyPlaybackDevice: AudioPlaybackDevice {
    var currentFrame: Int64 = 0
    func playSegment(startFrame: Int64, frameCount: Int64,
                     completion: @escaping @MainActor @Sendable (String?) -> Void) throws -> Bool {
        currentFrame = startFrame
        return true
    }
    func pause() -> Int64 { currentFrame }
    func stop() {}
}

@MainActor
private final class NoHardwareAudioFactory: AudioTransportDeviceFactory {
    private(set) var permissionRequests = 0
    private(set) var recordingDevices = 0

    func requestRecordPermission() async -> Bool {
        permissionRequests += 1
        return false
    }

    func makePlayback(url: URL, expected: AudioFormatInfo) throws -> any AudioPlaybackDevice {
        AssemblyPlaybackDevice()
    }

    func makeRecording(url: URL) throws -> any AudioRecordingDevice {
        recordingDevices += 1
        throw AudioMediaError.unavailable("测试不打开录音设备")
    }
}

@MainActor
private final class AssemblyPanels: AudioWorkbenchPanelProviding {
    private(set) var importRequests = 0
    var nextImport: URL?
    var nextExport: URL?
    var suspendImport = false
    var suspendExport = false
    private(set) var lastExportRequest: AudioExportPanelRequest?
    private(set) var importContinuation: CheckedContinuation<URL?, Never>?
    private(set) var exportContinuation: CheckedContinuation<URL?, Never>?

    func chooseAudioImport() async -> URL? {
        importRequests += 1
        if suspendImport {
            return await withCheckedContinuation { importContinuation = $0 }
        }
        defer { nextImport = nil }
        return nextImport
    }

    func chooseAudioExport(_ request: AudioExportPanelRequest) async -> URL? {
        lastExportRequest = request
        if suspendExport {
            return await withCheckedContinuation { exportContinuation = $0 }
        }
        defer { nextExport = nil }
        return nextExport
    }

    func resumeImport(with url: URL?) {
        suspendImport = false
        importContinuation?.resume(returning: url)
        importContinuation = nil
    }

    func resumeExport(with url: URL?) {
        suspendExport = false
        exportContinuation?.resume(returning: url)
        exportContinuation = nil
    }
}

@Suite("Audio workbench production assembly", .serialized)
@MainActor
struct AudioWorkbenchAssemblyTests {
    private func root() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("audio-assembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(panels: AssemblyPanels, factory: NoHardwareAudioFactory) -> WorkbenchModel {
        let engine = AudioAssemblyEngine()
        let transport = AudioTransport(recordingEnabled: false, deviceFactory: factory)
        return WorkbenchModel(
            sessionFactory: { _ in
                WorkbenchSession(
                    engine: engine,
                    backendID: "audio.assembly.fixture",
                    status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                    shutdown: {}, cleanup: {}, validateModel: { _ in }
                )
            },
            settings: UserDefaults(suiteName: "D.AudioAssembly.\(UUID().uuidString)")!,
            audioEnabled: true,
            audioRecordingEnabled: false,
            audioTransport: transport,
            audioPanels: panels
        )
    }

    private func makePCM16WAV(frameCount: Int = 32) -> Data {
        let channelCount: UInt16 = 1
        let sampleRate: UInt32 = 8_000
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(frameCount) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        var data = Data()
        data.append(Data("RIFF".utf8))
        append(UInt32(36) + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8), to: &data)
        append(channelCount * (bitsPerSample / 8), to: &data)
        append(bitsPerSample, to: &data)
        data.append(Data("data".utf8))
        append(dataSize, to: &data)
        for index in 0..<frameCount {
            append(Int16((index % 8) * 1_000 - 3_500), to: &data)
        }
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func openImportedAudio(root: URL, panels: AssemblyPanels,
                                   factory: NoHardwareAudioFactory) async throws
        -> (WorkbenchModel, URL, Data, ProjectAudioController) {
        let source = root.appendingPathComponent("输入-é.wav")
        let bytes = makePCM16WAV()
        try bytes.write(to: source)
        let model = model(panels: panels, factory: factory)
        let project = root.appendingPathComponent("Assembly.dproject")
        await model.createProject(at: project)
        try #require(model.manifest != nil, Comment(rawValue: model.errorMessage ?? "项目未创建"))
        panels.nextImport = source
        await model.importAudio()
        let controller = try #require(model.projectSession.audio)
        try #require(controller.document != nil, Comment(rawValue: model.errorMessage ?? "音频未导入"))
        try #require(controller.metadata != nil, Comment(rawValue: controller.errorMessage ?? "音频未检查"))
        return (model, source, bytes, controller)
    }

    @Test
    func importEditSelectSaveReopenAndExportPreserveOwnership() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let panels = AssemblyPanels()
        let factory = NoHardwareAudioFactory()
        let (model, source, sourceBytes, controller) = try await openImportedAudio(
            root: root, panels: panels, factory: factory
        )
        let documentID = try #require(controller.documentID)
        let contextID = controller.contextID
        let firstNote = "先保存的注释"
        let note = "稍后输入 e\u{301} 👩‍💻"
        #expect(model.projectSession.setAudioNoteInput(
            firstNote, contextID: contextID, documentID: documentID
        ))
        #expect(!(await model.projectSession.saveAudioNote(
            contextID: UUID(), documentID: documentID
        )))
        #expect(controller.noteInput == firstNote)
        let firstSave = Task {
            await model.projectSession.saveAudioNote(
                contextID: contextID, documentID: documentID
            )
        }
        await Task.yield()
        #expect(model.projectSession.setAudioNoteInput(
            note, contextID: contextID, documentID: documentID
        ))
        _ = await firstSave.value
        #expect(controller.noteInput.utf8.elementsEqual(note.utf8))
        #expect(await model.projectSession.saveAudioNote(
            contextID: contextID, documentID: documentID
        ))
        let range = AudioFrameRange(startFrame: 4, endFrame: 20)
        let clipName = "片段 🎵"
        #expect(model.projectSession.setAudioClipInput(
            name: clipName, range: range, contextID: contextID, documentID: documentID
        ))
        #expect(await model.projectSession.addAudioClip(
            contextID: contextID, documentID: documentID
        ))
        let clip = try #require(controller.document?.clips.first)
        #expect(await model.projectSession.selectAudioClip(
            id: clip.id, contextID: contextID, documentID: documentID
        ))

        let originalExport = root.appendingPathComponent("原件.wav")
        panels.nextExport = originalExport
        await model.exportOriginalAudio(contextID: contextID, documentID: documentID)
        #expect(try Data(contentsOf: originalExport) == sourceBytes)
        #expect(try Data(contentsOf: source) == sourceBytes)

        let rangeExport = root.appendingPathComponent("片段.wav")
        panels.nextExport = rangeExport
        await model.exportSavedAudioClip(id: clip.id, contextID: contextID, documentID: documentID)
        let exported = try AudioMediaInspector.inspect(at: rangeExport)
        #expect(exported.format.container == .wav)
        #expect(exported.format.floatingPoint)
        #expect(exported.format.bitDepth == 32)
        #expect(exported.format.frameCount == range.endFrame - range.startFrame)
        #expect(exported.format.sampleRate == controller.metadata?.format.sampleRate)
        #expect(exported.format.channelCount == controller.metadata?.format.channelCount)

        let projectURL = try #require(model.projectURL)
        #expect(await model.requestClose())
        await model.openProject(at: projectURL)
        let reopened = try #require(model.projectSession.audio)
        let reopenedID = try #require(reopened.documentID)
        #expect(await model.projectSession.refreshActiveAudioInspection(
            contextID: reopened.contextID, documentID: reopenedID
        ))
        #expect(reopened.document?.note == note)
        #expect(reopened.document?.clips.first?.name == clipName)
        #expect(try Data(contentsOf: source) == sourceBytes)

        let existing = root.appendingPathComponent("existing.wav")
        let marker = Data("不得覆盖".utf8)
        try marker.write(to: existing)
        panels.nextExport = existing
        await model.exportOriginalAudio(contextID: reopened.contextID, documentID: reopenedID)
        #expect(try Data(contentsOf: existing) == marker)
        #expect(reopened.errorMessage != nil)
        #expect(factory.permissionRequests == 0)
        #expect(factory.recordingDevices == 0)
    }

    @Test
    func cancelledAndSuspendedPanelsRejectStaleDocumentAndRange() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let panels = AssemblyPanels()
        let factory = NoHardwareAudioFactory()
        let model = model(panels: panels, factory: factory)
        let project = root.appendingPathComponent("Stale.dproject")
        await model.createProject(at: project)
        let originalDocumentID = try #require(model.activeDocumentID)
        panels.nextImport = nil
        await model.importAudio()
        #expect(model.activeDocumentID == originalDocumentID)
        #expect(model.documents.allSatisfy { $0.kind != .audio })

        let malformed = root.appendingPathComponent("malformed.wav")
        let malformedBytes = Data("not pcm".utf8)
        try malformedBytes.write(to: malformed)
        let documentCount = model.documents.count
        panels.nextImport = malformed
        await model.importAudio()
        #expect(model.documents.count == documentCount)
        #expect(model.documents.allSatisfy { $0.kind != .audio })
        #expect(try Data(contentsOf: malformed) == malformedBytes)
        model.clearError()

        let source = root.appendingPathComponent("stale.wav")
        try makePCM16WAV().write(to: source)
        panels.suspendImport = true
        let importTask = Task { await model.importAudio() }
        let importPanelOpened = await waitUntil { panels.importContinuation != nil }
        if !importPanelOpened { panels.resumeImport(with: nil) }
        try #require(importPanelOpened)
        await model.projectSession.createDocument(name: "面板期间的新文档")
        panels.resumeImport(with: source)
        await importTask.value
        #expect(model.documents.allSatisfy { $0.kind != .audio })
        #expect(try Data(contentsOf: source) == makePCM16WAV())

        panels.nextImport = source
        await model.importAudio()
        let controller = try #require(model.projectSession.audio)
        let documentID = try #require(controller.documentID)
        let firstRange = AudioFrameRange(startFrame: 2, endFrame: 12)
        #expect(controller.setClipInput(
            name: "待导出", range: firstRange,
            contextID: controller.contextID, documentID: documentID
        ))
        let revision = controller.editorRevision
        let destination = root.appendingPathComponent("stale-range.wav")
        panels.suspendExport = true
        let exportTask = Task {
            await model.exportAudioRange(
                firstRange, editorRevision: revision,
                contextID: controller.contextID, documentID: documentID
            )
        }
        let exportPanelOpened = await waitUntil { panels.exportContinuation != nil }
        if !exportPanelOpened { panels.resumeExport(with: nil) }
        try #require(exportPanelOpened)
        #expect(controller.setClipInput(
            name: "更新范围", range: .init(startFrame: 3, endFrame: 14),
            contextID: controller.contextID, documentID: documentID
        ))
        panels.resumeExport(with: destination)
        await exportTask.value
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(controller.clipNameInput == "更新范围")
        #expect(!(await model.requestClose()))
        #expect(model.projectSession.discardAudioEditorInput(
            contextID: controller.contextID, documentID: documentID
        ))
        #expect(!controller.hasUnsubmittedInput)
    }

    @Test
    func productionViewRoutesBindingsAndNeverRequestsDisabledMicrophone() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let panels = AssemblyPanels()
        let factory = NoHardwareAudioFactory()
        let (model, _, _, controller) = try await openImportedAudio(
            root: root, panels: panels, factory: factory
        )
        let actions = productionActions(model)
        let audioView = AudioWorkbenchView(
            controller: controller, recordingEnabled: false, actions: actions
        )
        let audioHost = NSHostingView(rootView: audioView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = audioHost
        defer { window.contentView = nil }
        settle(audioHost, width: 520)
        let noteField = try #require(descendants(audioHost).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "原始媒体注释" })
        let unicode = "生产输入 e\u{301} 👩‍💻"
        noteField.stringValue = unicode
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: noteField)
        settle(audioHost, width: 520)
        #expect(controller.noteInput.utf8.elementsEqual(unicode.utf8))
        settle(audioHost, width: 1_000)
        #expect(audioHost.fittingSize.width <= 1_001)

        await model.startAudioRecording()
        #expect(factory.permissionRequests == 0)
        #expect(factory.recordingDevices == 0)
        #expect(model.errorMessage?.contains("录音") == true)

        model.clearError() // The disabled-recording error was asserted above; do not present an alert.
        var audioRectangles: [String: CGRect] = [:]
        let workbenchHost = NSHostingController(rootView: WorkbenchView(model: model)
            .observingLayout { audioRectangles[$0] = $1 })
        let workbenchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 580),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        workbenchWindow.contentViewController = workbenchHost
        defer { workbenchWindow.contentViewController = nil }
        settle(workbenchHost.view, width: 1_000)
        let identifiers = Set(audioRectangles.filter { $0.value.width > 0 && $0.value.height > 0 }.keys)
        #expect(identifiers.contains("audio-workbench"))
        #expect(!identifiers.contains("export-artwork"))
        #expect(!identifiers.contains("toggle-inspector"))
        #expect(!identifiers.contains("copy-settings"))

        // Positive controls prevent an empty collector from pretending image actions are absent.
        let imageModel = self.model(panels: AssemblyPanels(), factory: NoHardwareAudioFactory())
        await imageModel.createProject(at: root.appendingPathComponent("ImageControls.dproject"))
        var imageRectangles: [String: CGRect] = [:]
        let imageHost = NSHostingController(rootView: WorkbenchView(model: imageModel)
            .observingLayout { imageRectangles[$0] = $1 })
        let imageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 580),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        imageWindow.contentViewController = imageHost
        defer { imageWindow.contentViewController = nil }
        settle(imageHost.view, width: 1_000)
        let imageIDs = Set(imageRectangles.filter { $0.value.width > 0 && $0.value.height > 0 }.keys)
        #expect(imageIDs.contains("export-artwork"))
        #expect(imageIDs.contains("toggle-inspector"))
        #expect(imageIDs.contains("copy-settings"))
        #expect(!imageIDs.contains("audio-workbench"))
    }

    @Test
    func productionViewRefreshesWhenNavigationGateReleases() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let panels = AssemblyPanels()
        let factory = NoHardwareAudioFactory()
        let (model, _, _, _) = try await openImportedAudio(
            root: root, panels: panels, factory: factory
        )
        let projectURL = try #require(model.projectURL)
        #expect(await model.requestClose())
        await model.openProject(at: projectURL)
        let controller = try #require(model.projectSession.audio)
        try #require(controller.documentID != nil)
        #expect(controller.metadata == nil)

        var refreshCount = 0
        var actions = productionActions(model)
        actions.refreshInspection = { contextID, documentID in
            refreshCount += 1
            return await model.projectSession.refreshActiveAudioInspection(
                contextID: contextID, documentID: documentID
            )
        }
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: AudioWorkbenchView(
            controller: controller, recordingEnabled: false,
            navigationInProgress: true, actions: actions
        ).observingLayout { rectangles[$0] = $1 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        settle(host, width: 700)
        #expect(refreshCount == 0)
        #expect(controller.metadata == nil)

        host.rootView = AudioWorkbenchView(
            controller: controller, recordingEnabled: false,
            navigationInProgress: false, actions: actions
        ).observingLayout { rectangles[$0] = $1 }
        settle(host, width: 700)
        let refreshed = await waitUntil { controller.metadata != nil }
        #expect(refreshed)
        #expect(refreshCount == 1)
        settle(host, width: 700)
        let identifiers = Set(rectangles.filter { $0.value.width > 0 && $0.value.height > 0 }.keys)
        #expect(identifiers.contains("audio-waveform"))
        #expect(identifiers.contains("audio-prepared-range"))
    }

    @Test
    func staleRenderedImportDoesNotOpenPanelOrAttachToReplacementDocument() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let panels = AssemblyPanels()
        let factory = NoHardwareAudioFactory()
        let model = model(panels: panels, factory: factory)
        await model.createProject(at: root.appendingPathComponent("Origin.dproject"))
        let contextID = try #require(model.projectSession.audio?.contextID)
        let originalID = try #require(model.activeDocumentID)
        let staleAction = model.audioImportAction(contextID: contextID, documentID: originalID)
        await model.projectSession.createDocument(name: "替代文档")
        let replacementID = try #require(model.activeDocumentID)
        #expect(replacementID != originalID)
        let source = root.appendingPathComponent("should-not-import.wav")
        let bytes = makePCM16WAV()
        try bytes.write(to: source)
        panels.nextImport = source
        let priorCount = panels.importRequests
        staleAction()
        let settled = await waitUntil { panels.importRequests != priorCount || model.errorMessage != nil }
        #expect(settled)
        #expect(panels.importRequests == priorCount)
        #expect(model.activeDocumentID == replacementID)
        #expect(model.documents.allSatisfy { $0.kind != .audio })
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test
    func debugIsolationRequiresBothExactInputs() {
        let token = UUID().uuidString
        #if DEBUG
        #expect(AudioWorkbenchIsolation.isEnabled(environment: [
            "D_UI_TEST_SESSION": token,
            "D_AUDIO_WORKBENCH_TEST": "1"
        ]))
        #endif
        #expect(!AudioWorkbenchIsolation.isEnabled(environment: [
            "D_UI_TEST_SESSION": token
        ]))
        #expect(!AudioWorkbenchIsolation.isEnabled(environment: [
            "D_UI_TEST_SESSION": "not-a-uuid",
            "D_AUDIO_WORKBENCH_TEST": "1"
        ]))
        #expect(!AudioWorkbenchIsolation.isEnabled(environment: [
            "D_UI_TEST_SESSION": token,
            "D_AUDIO_WORKBENCH_TEST": "true"
        ]))
    }

    private func productionActions(_ model: WorkbenchModel) -> AudioWorkbenchProductionActions {
        AudioWorkbenchProductionActions(
            importOriginal: {}, startRecording: {}, finishRecording: {},
            refreshInspection: { contextID, documentID in
                await model.projectSession.refreshActiveAudioInspection(
                    contextID: contextID, documentID: documentID
                )
            },
            saveNote: { contextID, documentID in
                await model.projectSession.saveAudioNote(contextID: contextID, documentID: documentID)
            },
            addClip: { contextID, documentID in
                await model.projectSession.addAudioClip(contextID: contextID, documentID: documentID)
            },
            discardInput: { contextID, documentID in
                model.projectSession.discardAudioEditorInput(
                    contextID: contextID, documentID: documentID
                )
            },
            selectClip: { id, contextID, documentID in
                if let id {
                    await model.projectSession.selectAudioClip(
                        id: id, contextID: contextID, documentID: documentID
                    )
                } else {
                    await model.projectSession.selectFullAudio(
                        contextID: contextID, documentID: documentID
                    )
                }
            },
            prepareRange: { range, contextID, documentID in
                await model.projectSession.prepareAudioPlayback(
                    range: range, contextID: contextID, documentID: documentID
                )
            },
            exportOriginal: { _, _ in }, exportSavedClip: { _, _, _ in },
            exportRange: { _, _, _, _ in }, retryCapture: { _, _, _ in },
            keepCapture: { _, _, _ in }
        )
    }

    private func descendants(_ parent: NSView) -> [NSView] {
        parent.subviews.flatMap { [$0] + descendants($0) }
    }

    private func waitUntil(timeout: Duration = .seconds(2),
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle(_ host: NSView, width: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 580)
        let deadline = Date().addingTimeInterval(0.2)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
    }
}

import AppKit
@testable import DWorkbench
import SwiftUI
import Testing
@testable import UI

@MainActor
private final class PendingPermissionFactory: AudioTransportDeviceFactory {
    var continuation: CheckedContinuation<Bool, Never>?
    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func makePlayback(
        url: URL,
        expected: AudioFormatInfo
    ) throws -> any AudioPlaybackDevice {
        throw AudioMediaError.unavailable("unused")
    }
    func makeRecording(capture: AudioCaptureFile) throws -> any AudioRecordingDevice {
        throw AudioMediaError.unavailable("unused")
    }
    func resolve() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}

@Suite("Audio workbench view", .serialized)
@MainActor
struct AudioWorkbenchViewTests {
    private let metadata = AudioAssetMetadata(
        format: .init(
            container: .wav,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 480_000,
            bitDepth: 32,
            floatingPoint: true
        ),
        contentSHA256: "fixture",
        origin: .importedFile
    )

    private func actions(
        saves: @escaping (UUID, String) -> Void = { _, _ in }
    ) -> AudioWorkbenchActions {
        AudioWorkbenchActions(
            importOriginal: {},
            startRecording: {},
            finishRecording: {},
            saveNote: saves,
            selectClip: { _ in },
            addClip: { _, _ in },
            exportOriginal: {},
            exportRange: { _ in }
        )
    }

    private func descendants(_ parent: NSView) -> [NSView] {
        parent.subviews.flatMap { [$0] + descendants($0) }
    }

    private func settle(
        _ host: NSHostingView<AudioWorkbenchView>,
        width: CGFloat,
        height: CGFloat = 580,
        until condition: () -> Bool = { true }
    ) {
        host.window?.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let deadline = Date().addingTimeInterval(0.25)
        repeat {
            host.window?.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.window?.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            if condition() { return }
        } while Date() < deadline
        host.window?.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    private func enclosingEditorScroll(in host: NSView) -> NSScrollView? {
        descendants(host)
            .compactMap { $0 as? NSScrollView }
            .filter { scroll in
                guard let document = scroll.documentView else { return false }
                let height = max(document.bounds.height, document.frame.height)
                return height > scroll.contentSize.height + 1
            }
            .max { lhs, rhs in
                let lhsHeight = max(lhs.documentView?.bounds.height ?? 0, lhs.documentView?.frame.height ?? 0)
                let rhsHeight = max(rhs.documentView?.bounds.height ?? 0, rhs.documentView?.frame.height ?? 0)
                return lhsHeight < rhsHeight
            }
    }

    @Test
    func wideNarrowWideKeepsEditorAndControlsReachableWithMaximumClips() throws {
        var clips: [AudioClip] = []
        for index in 0..<AudioLimits.maximumClips {
            let start = Int64(index) * 100
            let range = AudioFrameRange(startFrame: start, endFrame: start + 80)
            clips.append(AudioClip(name: "片段 \(index)", range: range))
        }
        let document = AudioDraftDocument(
            id: UUID(),
            assetID: UUID(),
            clips: clips,
            note: "e\u{301} 音符 🎵"
        )
        var saves: [(UUID, String)] = []
        var rectangles: [String: CGRect] = [:]
        let view = AudioWorkbenchView(
            document: document,
            metadata: metadata,
            waveform: [.init(minimum: -0.5, maximum: 0.5)],
            transport: AudioTransport(),
            actions: actions { saves.append(($0, $1)) }
        ).observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }

        settle(host, width: 1000)
        let originalEditor = try #require(
            descendants(host).compactMap { $0 as? NSTextField }.first
        )
        let editorIdentity = ObjectIdentifier(originalEditor)

        for width: CGFloat in [520, 1000] {
            settle(host, width: width)
            let views = descendants(host)
            let editor = try #require(views.compactMap { $0 as? NSTextField }.first)
            #expect(ObjectIdentifier(editor) == editorIdentity)
            #expect(host.fittingSize.width <= width + 1)

            let viewport = host.bounds.insetBy(dx: -1, dy: -1)
            for key in ["audio-export-original", "audio-add-clip", "audio-note"] {
                let rectangle = try #require(rectangles[key])
                #expect(rectangle.width > 0 && rectangle.height > 0)
                #expect(rectangle.minX >= viewport.minX && rectangle.maxX <= viewport.maxX)
            }
            #expect(viewport.intersects(try #require(rectangles["audio-export-original"])))
            let scroll = try #require(enclosingEditorScroll(in: host))
            let content = try #require(scroll.documentView)
            let documentHeight = max(content.bounds.height, content.frame.height)
            #expect(documentHeight > scroll.contentSize.height + 1)
            let topOrigin = scroll.contentView.bounds.origin
            #expect(abs(topOrigin.y) <= 1)
            let finalRowID = "audio-clip-row-\(clips.last!.id.uuidString)"
            scroll.contentView.scroll(to: NSPoint(
                x: 0,
                y: max(0, documentHeight - scroll.contentSize.height)
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host, width: width) {
                scroll.contentView.bounds.origin.y > topOrigin.y + 1
                    && rectangles[finalRowID].map(viewport.intersects) == true
            }
            #expect(scroll.contentView.bounds.origin.y > topOrigin.y + 1)
            let lastClip = try #require(rectangles[finalRowID])
            #expect(lastClip.minX >= viewport.minX && lastClip.maxX <= viewport.maxX)
            #expect(viewport.intersects(lastClip), "The final supported clip must be reachable by scrolling.")
            scroll.contentView.scroll(to: NSPoint.zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host, width: width) { abs(scroll.contentView.bounds.origin.y) <= 1 }
            #expect(abs(scroll.contentView.bounds.origin.y) <= 1)
        }
        #expect(saves.isEmpty)
        #expect(originalEditor.stringValue.utf8.elementsEqual(document.note.utf8))
    }

    @Test
    func switchingDocumentReplacesDraftWithoutSavingPreviousNote() throws {
        let first = AudioDraftDocument(
            id: UUID(),
            assetID: UUID(),
            note: "第一份 e\u{301}"
        )
        let second = AudioDraftDocument(
            id: UUID(),
            assetID: UUID(),
            note: "第二份 👩‍💻"
        )
        var saves: [(UUID, String)] = []
        let transport = AudioTransport()
        let callbacks = actions { saves.append(($0, $1)) }
        let host = NSHostingView(rootView: AudioWorkbenchView(
            document: first,
            metadata: metadata,
            waveform: [],
            transport: transport,
            actions: callbacks
        ))
        settle(host, width: 700)
        host.rootView = AudioWorkbenchView(
            document: second,
            metadata: metadata,
            waveform: [],
            transport: transport,
            actions: callbacks
        )
        settle(host, width: 700)

        let editor = try #require(
            descendants(host).compactMap { $0 as? NSTextField }.first
        )
        #expect(editor.stringValue.utf8.elementsEqual(second.note.utf8))
        #expect(saves.isEmpty)
    }

    @Test
    func pendingPermissionWithDocumentOffersFinishInsteadOfAnotherStart() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] else {
            throw AudioMediaError.unavailable("D_TEST_TEMP_DIR is required")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = PendingPermissionFactory()
        let transport = AudioTransport(recordingEnabled: true, deviceFactory: factory)
        let request = Task {
            try await transport.requestAndStartRecording(
                to: root.appendingPathComponent("pending.caf"),
                revalidate: {},
                createCapture: { throw AudioMediaError.unavailable("cancelled fixture") }
            )
        }
        defer { transport.shutdown(); factory.resolve(); request.cancel() }
        let deadline = Date().addingTimeInterval(2)
        while transport.state != .requestingPermission && Date() < deadline { await Task.yield() }
        try #require(transport.state == .requestingPermission)

        var rectangles: [String: CGRect] = [:]
        let document = AudioDraftDocument(id: UUID(), assetID: UUID())
        let host = NSHostingView(rootView: AudioWorkbenchView(
            document: document,
            metadata: metadata,
            waveform: [],
            transport: transport,
            actions: actions()
        ).observingLayout { rectangles[$0] = $1 })
        settle(host, width: 520)
        let finish = try #require(rectangles["audio-record-finish"])
        #expect(host.bounds.intersects(finish))
        #expect(rectangles["audio-record-start"] == nil)

        _ = try transport.finishRecording()
        factory.resolve()
        try await request.value
        #expect(transport.state == .idle)
    }

    @Test
    func actionValuePreservesUnicodeAndImmutableRangeInput() {
        var suppliedName = ""
        var suppliedRange: AudioFrameRange?
        let callbacks = AudioWorkbenchActions(
            importOriginal: {},
            startRecording: {},
            finishRecording: {},
            saveNote: { _, _ in },
            selectClip: { _ in },
            addClip: { range, name in
                suppliedRange = range
                suppliedName = name
            },
            exportOriginal: {},
            exportRange: { _ in }
        )
        let unicode = "片段 e\u{301} 👩‍💻"
        let original = AudioFrameRange(startFrame: 1, endFrame: 2)
        callbacks.addClip(original, unicode)

        #expect(suppliedName.utf8.elementsEqual(unicode.utf8))
        #expect(suppliedRange == original)
    }

    @Test
    func hostedUnicodeEditorValuesReachSharedButtonHandlerWithoutClaimingGUIActivation() throws {
        let document = AudioDraftDocument(
            id: UUID(),
            assetID: UUID(),
            note: "注释 e\u{301} 👩‍💻"
        )
        var saves: [(UUID, String)] = []
        var additions: [(AudioFrameRange, String)] = []
        var rejections: [AudioMediaError] = []
        let callbacks = AudioWorkbenchActions(
            importOriginal: {},
            startRecording: {},
            finishRecording: {},
            saveNote: { saves.append(($0, $1)) },
            selectClip: { _ in },
            addClip: { additions.append(($0, $1)) },
            exportOriginal: {},
            exportRange: { _ in }
        )
        let host = NSHostingView(rootView: AudioWorkbenchView(
            document: document,
            metadata: metadata,
            waveform: [],
            transport: AudioTransport(),
            actions: callbacks
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        settle(host, width: 700)

        let fields = descendants(host).compactMap { $0 as? NSTextField }
        let noteEditor = try #require(fields.first { $0.placeholderString == "原始媒体注释" })
        let clipEditor = try #require(fields.first { $0.placeholderString == "片段名称" })
        let clipUnicode = "片段 e\u{301} 🎵"
        clipEditor.stringValue = clipUnicode
        let range = AudioFrameRange(startFrame: 7, endFrame: 19)

        #expect(AudioWorkbenchButtonHandler.saveNote(
            documentID: document.id,
            editingDocumentID: document.id,
            note: noteEditor.stringValue,
            actions: callbacks,
            reject: { rejections.append($0) }
        ))
        #expect(AudioWorkbenchButtonHandler.addClip(
            documentID: document.id,
            editingDocumentID: document.id,
            existingClipCount: document.clips.count,
            name: clipEditor.stringValue,
            range: { range },
            actions: callbacks,
            reject: { rejections.append($0) }
        ))
        #expect(saves.count == 1)
        #expect(saves[0].0 == document.id)
        #expect(saves[0].1.utf8.elementsEqual(document.note.utf8))
        #expect(additions.count == 1)
        #expect(additions[0].0 == range)
        #expect(additions[0].1.utf8.elementsEqual(clipUnicode.utf8))
        #expect(rejections.isEmpty)

        #expect(!AudioWorkbenchButtonHandler.saveNote(
            documentID: document.id,
            editingDocumentID: UUID(),
            note: noteEditor.stringValue,
            actions: callbacks,
            reject: { rejections.append($0) }
        ))
        #expect(!AudioWorkbenchButtonHandler.addClip(
            documentID: document.id,
            editingDocumentID: document.id,
            existingClipCount: AudioLimits.maximumClips,
            name: clipEditor.stringValue,
            range: { range },
            actions: callbacks,
            reject: { rejections.append($0) }
        ))
        #expect(saves.count == 1)
        #expect(additions.count == 1)
        #expect(rejections == [.limitExceeded])
    }
}

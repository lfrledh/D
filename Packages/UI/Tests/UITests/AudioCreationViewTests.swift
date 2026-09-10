import AppKit
import DInference
@testable import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite("Audio creation view", .serialized)
@MainActor
struct AudioCreationViewTests {
    private func asset(id: UUID = UUID(), name: String = "候选 e\u{301} 🎵",
                       sampleRate: Double = 44_100, channels: Int = 2,
                       frames: Int64 = 88_200) -> ProjectAsset {
        ProjectAsset(id: id, relativePath: "Audio/fixture.wav", mediaType: "audio/wav", role: .result,
                     metadata: .init(audio: .init(format: .init(container: .wav, sampleRate: sampleRate,
                                                               channelCount: channels, frameCount: frames,
                                                               bitDepth: 32, floatingPoint: true),
                                                   contentSHA256: "fixture", origin: .importedFile)), name: name)
    }

    private func actions(generated: @escaping () -> Void = {}) -> AudioCreationActions {
        AudioCreationActions(generate: generated, cancel: {}, save: {}, select: { _ in }, play: { _ in },
                             stop: {}, adopt: { _ in }, reject: { _, _ in }, export: { _ in },
                             createFrom: { _ in }, chooseModel: {})
    }

    @Test
    func validGenerateRoutesOnlyTheExplicitGenerateCallback() {
        var generated = 0
        var adopted = 0
        let draft = AudioCreationDraft(prompt: "鼓点", strengthText: "1")
        let callbacks = AudioCreationActions(
            generate: { generated += 1 }, cancel: {}, save: {}, select: { _ in }, play: { _ in }, stop: {},
            adopt: { _ in adopted += 1 }, reject: { _, _ in }, export: { _ in }, createFrom: { _ in }, chooseModel: {}
        )
        #expect(AudioCreationButtonHandler.submit(draft, source: nil, hostAllowsGeneration: true,
                                                   actions: callbacks))
        #expect(generated == 1)
        #expect(adopted == 0)
        #expect(draft.seedText == "42")
    }

    @Test
    func preservesFullSeedButRejectsUnsupportedProfileValue() {
        let draft = AudioCreationDraft(prompt: "鼓点", seedText: "18446744073709551615", strengthText: "1")
        #expect(draft.seedText == "18446744073709551615")
        #expect(!AudioCreationButtonHandler.numericInputsAreValid(draft))
    }

    @Test
    func invalidRangeAndMissingSourceNeverRouteGenerate() {
        var generated = 0
        var inpaint = AudioCreationDraft(operation: .inpaint, editRegion: .init(startFrame: 44_100, endFrame: 44_100))
        #expect(!AudioCreationButtonHandler.submit(inpaint, source: nil, hostAllowsGeneration: true,
                                                    actions: actions { generated += 1 }))
        #expect(generated == 0)
        inpaint.editRegion = .init(startFrame: 0, endFrame: 99_999)
        #expect(!AudioCreationButtonHandler.submit(inpaint, source: asset(), hostAllowsGeneration: true,
                                                    actions: actions { generated += 1 }))
        #expect(generated == 0)
    }

    @Test
    func sourceEditingRequires44KHzStereoWAV() {
        let unsupported = asset(sampleRate: 48_000, channels: 1)
        #expect(!AudioCreationButtonHandler.sourceIsEditable(unsupported))
        var draft = AudioCreationDraft(prompt: "参考", operation: .variation)
        #expect(!AudioCreationButtonHandler.canGenerate(draft, source: unsupported))
        draft.operation = .inpaint
        draft.editRegion = .init(startFrame: 0, endFrame: 44_100)
        #expect(AudioCreationButtonHandler.canGenerate(draft, source: asset()))
    }

    @Test
    func rejectRestoreAndAdoptionRouteDesiredStateAndRespectBusy() {
        let id = UUID()
        var rejected: [(UUID, Bool)] = []
        var adopted: [UUID?] = []
        let callbacks = AudioCreationActions(generate: {}, cancel: {}, save: {}, select: { _ in }, play: { _ in },
                                             stop: {}, adopt: { adopted.append($0) },
                                             reject: { rejected.append(($0, $1)) }, export: { _ in },
                                             createFrom: { _ in }, chooseModel: {})
        #expect(AudioCreationButtonHandler.setRejected(id, currentlyRejected: false, isBusy: false, actions: callbacks))
        #expect(AudioCreationButtonHandler.setRejected(id, currentlyRejected: true, isBusy: false, actions: callbacks))
        #expect(rejected.map(\.1) == [true, false])
        #expect(!AudioCreationButtonHandler.adopt(id, isRejected: true, isBusy: false, actions: callbacks))
        #expect(!AudioCreationButtonHandler.adopt(id, isRejected: false, isBusy: true, actions: callbacks))
        #expect(AudioCreationButtonHandler.adopt(nil, isRejected: false, isBusy: false, actions: callbacks))
        #expect(adopted == [nil])
    }

    @Test
    func sourceActionsRouteIdentityAndBusySuppressesMutations() {
        let id = UUID()
        var played: [UUID] = []
        var exported: [UUID] = []
        let callbacks = AudioCreationActions(generate: {}, cancel: {}, save: {}, select: { _ in },
                                             play: { played.append($0) }, stop: {}, adopt: { _ in }, reject: { _, _ in },
                                             export: { exported.append($0) }, createFrom: { _ in }, chooseModel: {})
        #expect(AudioCreationButtonHandler.play(id, isBusy: false, actions: callbacks))
        #expect(AudioCreationButtonHandler.export(id, isBusy: false, actions: callbacks))
        #expect(!AudioCreationButtonHandler.play(id, isBusy: true, actions: callbacks))
        #expect(!AudioCreationButtonHandler.export(id, isBusy: true, actions: callbacks))
        #expect(played == [id])
        #expect(exported == [id])
    }

    @Test
    func rangeConversionRejectsUnsafeAndOutOfBoundsValues() {
        let format = asset().metadata.audio!.format
        for values in [("-1", "1"), ("nan", "1"), ("0", "1e300"), ("0", "3")] {
            #expect(AudioCreationButtonHandler.frameRange(startText: values.0, endText: values.1, format: format) == nil)
        }
        #expect(AudioCreationButtonHandler.frameRange(startText: "0", endText: "1", format: format)
                == AudioFrameRange(startFrame: 0, endFrame: 44_100))
    }

    @Test
    func oldRangeSurvivesAnInvalidUnappliedReplacement() {
        var draft = AudioCreationDraft(prompt: "重绘", operation: .inpaint,
                                       editRegion: .init(startFrame: 0, endFrame: 44_100))
        let oldRange = draft.editRegion
        #expect(AudioCreationButtonHandler.frameRange(startText: "0", endText: "1e300",
                                                       format: asset().metadata.audio!.format) == nil)
        #expect(draft.editRegion == oldRange)
    }

    @Test
    func narrowViewKeepsRequiredControlsAndUnicodeAsset() throws {
        let candidate = asset(name: "这是一个特别特别长的中文候选名称 e\u{301} 👩‍💻，不能在窄窗口被截断")
        var draft = AudioCreationDraft(prompt: "很长的中文提示 e\u{301} 👩‍💻")
        var rectangles: [String: CGRect] = [:]
        let host = NSHostingView(rootView: AudioCreationView(
            draft: Binding(get: { draft }, set: { draft = $0 }), source: nil, candidates: [candidate],
            selectedAssetID: candidate.id, adoptedAssetID: nil, modelStatus: "模型已就绪", canGenerate: true,
            isBusy: false, progress: nil, status: nil, transport: AudioTransport(), actions: actions()
        ).observingLayout { rectangles[$0] = $1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 500)
        host.layoutSubtreeIfNeeded()
        let identifiers = descendants(host).compactMap(\.identifier?.rawValue)
        for identifier in ["audio-create-prompt", "audio-create-generate", "audio-create-save",
                           "audio-create-select-\(candidate.id.uuidString)"] {
            #expect(identifiers.contains(identifier))
        }
        #expect(host.fittingSize.width <= 521)
        let viewport = host.bounds.insetBy(dx: -1, dy: -1)
        for id in ["audio-create-play-\(candidate.id.uuidString)", "audio-create-adopt-\(candidate.id.uuidString)",
                   "audio-create-reject-\(candidate.id.uuidString)", "audio-create-export-\(candidate.id.uuidString)",
                   "audio-create-from-\(candidate.id.uuidString)"] {
            let rectangle = try #require(rectangles[id])
            #expect(rectangle.minX >= viewport.minX && rectangle.maxX <= viewport.maxX)
            #expect(viewport.intersects(rectangle))
        }
    }

    private func descendants(_ parent: NSView) -> [NSView] {
        parent.subviews.flatMap { [$0] + descendants($0) }
    }
}

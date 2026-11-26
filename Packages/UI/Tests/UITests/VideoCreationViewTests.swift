import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Video creation view", .serialized)
@MainActor
struct VideoCreationViewTests {
    private func actions(generated: @escaping () -> Void = {}) -> VideoCreationActions {
        VideoCreationActions(generate: generated, cancel: {}, save: {}, chooseModel: {}, stop: {},
                             select: { _ in }, adopt: { _ in }, preview: { _ in }, export: { _ in },
                             reject: { _, _ in })
    }

    @Test
    func validGenerateRoutesOnlyTheExplicitGenerateCallback() {
        var generated = 0
        var adopted = 0
        let draft = VideoCreationDraft(prompt: "很长的中文提示 e\u{301} 👩‍💻")
        let callbacks = VideoCreationActions(generate: { generated += 1 }, cancel: {}, save: {}, chooseModel: {},
                                             stop: {}, select: { _ in }, adopt: { _ in adopted += 1 }, preview: { _ in },
                                             export: { _ in }, reject: { _, _ in })
        #expect(VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: true, isBusy: false, actions: callbacks))
        #expect(generated == 1)
        #expect(adopted == 0)
        #expect(draft.prompt == "很长的中文提示 e\u{301} 👩‍💻")
    }

    @Test
    func incompleteOrUnsupportedNumericTextIsPreservedAndNeverSubmits() {
        var generated = 0
        let draft = VideoCreationDraft(prompt: "视频", widthText: "-")
        #expect(!VideoCreationButtonHandler.isValid(draft))
        #expect(!VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: true, isBusy: false,
                                                    actions: actions { generated += 1 }))
        #expect(generated == 0)
        #expect(draft.widthText == "-")
        #expect(VideoCreationButtonHandler.submissionMessage(draft, hostAllowsGeneration: true).contains("输入保持不变"))
        let invalidBudget = VideoCreationDraft(prompt: "视频", memoryBudgetMiBText: "0")
        #expect(!VideoCreationButtonHandler.submit(invalidBudget, hostAllowsGeneration: true, isBusy: false,
                                                    actions: actions { generated += 1 }))
        #expect(generated == 0)
        #expect(invalidBudget.memoryBudgetMiBText == "0")
    }

    @Test
    func hostOrBusyStateCannotRouteGeneration() {
        var generated = 0
        let draft = VideoCreationDraft(prompt: "视频")
        #expect(!VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: false, isBusy: false,
                                                    actions: actions { generated += 1 }))
        #expect(!VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: true, isBusy: true,
                                                    actions: actions { generated += 1 }))
        #expect(generated == 0)
    }

    @Test
    func candidateActionsRouteIdentityAndBusySuppressesMutation() {
        let id = UUID()
        var selected: [UUID?] = []
        var adopted: [UUID?] = []
        var previewed: [UUID] = []
        var exported: [UUID] = []
        var rejected: [(UUID, Bool)] = []
        let callbacks = VideoCreationActions(generate: {}, cancel: {}, save: {}, chooseModel: {}, stop: {},
                                             select: { selected.append($0) }, adopt: { adopted.append($0) },
                                             preview: { previewed.append($0) }, export: { exported.append($0) },
                                             reject: { rejected.append(($0, $1)) })
        #expect(VideoCreationButtonHandler.select(id, isBusy: false, actions: callbacks))
        #expect(VideoCreationButtonHandler.preview(id, isBusy: false, actions: callbacks))
        #expect(VideoCreationButtonHandler.export(id, isBusy: false, actions: callbacks))
        #expect(VideoCreationButtonHandler.setRejected(id, currentlyRejected: false, isBusy: false, actions: callbacks))
        #expect(VideoCreationButtonHandler.setRejected(id, currentlyRejected: true, isBusy: false, actions: callbacks))
        #expect(!VideoCreationButtonHandler.adopt(id, isRejected: true, isBusy: false, actions: callbacks))
        #expect(VideoCreationButtonHandler.adopt(nil, isRejected: false, isBusy: false, actions: callbacks))
        #expect(!VideoCreationButtonHandler.preview(id, isBusy: true, actions: callbacks))
        #expect(selected == [id])
        #expect(adopted == [nil])
        #expect(previewed == [id])
        #expect(exported == [id])
        #expect(rejected.map(\.1) == [true, false])
    }

    @Test
    func offscreenLayoutsKeepLongUnicodeCandidateWithinBothViewportsAndPresentationKeepsDraft() async throws {
        let id = UUID()
        let candidate = ProjectAsset(id: id, relativePath: "Video/fixture.mp4", mediaType: "video/mp4",
                                     name: "这是一个特别特别长的中文候选名称 e\u{301} 👩‍💻，不能在窄窗口丢失")
        let draft = VideoCreationDraft(prompt: "很长的中文提示 e\u{301} 👩‍💻", widthText: "-")
        var rectangles: [String: CGRect] = [:]
        let base = ProjectVideoCandidatesView(draft: draft, candidates: [candidate],
            selectedAssetID: id, adoptedAssetID: nil, isBusy: false, previewURL: nil,
            previewIdentity: UUID(), actions: actions()).observingLayout { rectangles[$0] = $1 }
        let surfaces = [base]
        #expect(draft.prompt == "很长的中文提示 e\u{301} 👩‍💻")
        #expect(draft.widthText == "-")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 2400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.contentView = nil }
        for width: CGFloat in [520, 1_000] {
            for surface in surfaces {
                rectangles.removeAll()
                let host = NSHostingView(rootView: surface)
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 2400))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 2400)
                for _ in 0..<5 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                }
                    let row = try #require(rectangles["video-create-candidate-\(id.uuidString)"])
                    #expect(row.width > 0 && row.minX >= -1 && row.maxX <= width + 1)
                    for action in ["preview", "adopt", "reject", "export"] {
                        let button = try #require(rectangles["video-create-\(action)-\(id.uuidString)"])
                        #expect(button.width > 0 && button.height > 0)
                        #expect(button.minX >= -1 && button.maxX <= width + 1)
                    }
            }
        }
        #expect(draft.widthText == "-")
    }

    @Test
    func candidateViewDisappearingStopsPlayback() async throws {
        let draft = VideoCreationDraft(prompt: "视频")
        var stops = 0
        var mounted = false
        let callbacks = VideoCreationActions(generate: {}, cancel: {}, save: {}, chooseModel: {},
            stop: { stops += 1 }, select: { _ in }, adopt: { _ in }, preview: { _ in }, export: { _ in }, reject: { _, _ in })
        let view = ProjectVideoCandidatesView(draft: draft, candidates: [], selectedAssetID: nil,
            adoptedAssetID: nil, isBusy: false, previewURL: nil, previewIdentity: UUID(), actions: callbacks)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let host = NSHostingView(rootView: AnyView(view.onAppear { mounted = true }))
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(mounted)
        host.rootView = AnyView(EmptyView())
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(stops == 1)
    }
}

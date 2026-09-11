import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Project resource browser", .serialized)
@MainActor
struct ProjectResourceBrowserTests {
    private func request() -> InferenceRequest {
        .init(model: .init(directory: URL(fileURLWithPath: "/fixture")),
              input: .image(.init(prompt: "p", width: 1, height: 1, steps: 1, guidanceScale: 0, seed: 1)))
    }

    @Test func projectsOnlySavedTextDocumentsAndKeepsIdentitySpacesSeparate() throws {
        let imageDocument = ProjectDocument(id: UUID(), name: "同名", kind: .image)
        let audioDocument = ProjectDocument(id: UUID(), name: "同名", kind: .audio)
        let sharedID = UUID()
        let textDocument = ProjectDocument(id: sharedID, name: "同名", kind: .text,
                                           textDraft: try TextDraftDocument(text: "你好，e\u{301} 👩‍💻"))
        let imageOwnedByAudio = ProjectAsset(id: sharedID, jobID: UUID(), relativePath: "z",
                                             mediaType: "image/png", name: "同名")
        let missingJob = ProjectAsset(id: UUID(), jobID: UUID(), relativePath: "lost",
                                      mediaType: "application/octet-stream", name: "丢失任务")
        let deletedOrigin = ProjectAsset(id: UUID(), jobID: UUID(), relativePath: "gone",
                                         mediaType: "image/png", name: "丢失来源")
        let audio = ProjectAsset(id: UUID(), relativePath: "sound", mediaType: "audio/x-wav",
                                 metadata: .init(audio: .init(format: .init(container: .wav, sampleRate: 44_100,
                                                                            channelCount: 2, frameCount: 88_200,
                                                                            bitDepth: 32, floatingPoint: true),
                                                               contentSHA256: "fixture", origin: .importedFile)), name: "录音")
        let audioJob = ProjectJob(id: imageOwnedByAudio.jobID!, documentID: audioDocument.id, request: request())
        let deletedJob = ProjectJob(id: deletedOrigin.jobID!, documentID: UUID(), request: request())
        let manifest = ProjectManifest(name: "fixture", jobs: [audioJob, deletedJob],
                                       assets: [imageOwnedByAudio, missingJob, deletedOrigin, audio],
                                       documents: [imageDocument, audioDocument, textDocument],
                                       activeDocumentID: imageDocument.id)
        let imageOnly = ProjectResourceCatalog.items(in: manifest, mode: .image, includeOtherModes: false)
        #expect(imageOnly.contains { $0.id == .media(sharedID) && $0.mode == .image && $0.originDocumentID == audioDocument.id })
        #expect(!imageOnly.contains { $0.id == .media(missingJob.id) })
        #expect(imageOnly.contains { $0.id == .media(deletedOrigin.id) && $0.originDocumentID == nil })
        #expect(!imageOnly.contains { if case .document = $0.id { return true }; return false })
        let all = ProjectResourceCatalog.items(in: manifest, mode: .image, includeOtherModes: true)
        #expect(all.contains { $0.id == .media(missingJob.id) && $0.mode == nil && $0.originDocumentID == nil })
        #expect(all.contains { $0.id == .media(audio.id) && $0.mode == .audio && $0.mediaType == "audio/x-wav" })
        #expect(all.contains { $0.id == .document(sharedID) && $0.textPreview == "你好，e\u{301} 👩‍💻" })
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(ProjectResourceCatalog.items(in: ProjectManifest(name: "empty", documents: [imageDocument],
                                                                  activeDocumentID: imageDocument.id),
                                             mode: .image, includeOtherModes: false).isEmpty)
    }

    @Test func narrowBrowserKeepsActualControlsVisibleAndDoesNotOpenWithoutExplicitButton() async throws {
        let text = ProjectDocument(id: UUID(), name: "文稿", kind: .text,
                                   textDraft: try TextDraftDocument(text: "正文"))
        let manifest = ProjectManifest(name: "fixture", documents: [text], activeDocumentID: text.id)
        var rectangles: [String: CGRect] = [:]
        var opened: [UUID] = []
        var actions: ProjectResourceBrowserTestingActions?
        let browser = ProjectResourceBrowser(manifest: manifest, mode: .text, availableModes: [.text],
                                             assetURL: { _ in fatalError("URL resolution must be explicit") },
                                             onOpenDocument: { opened.append($0) })
            .observingLayout { rectangles[$0] = $1 }
            .observingActions { actions = $0 }
        var host = NSHostingView(rootView: browser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for width: CGFloat in [210, 260] {
            // A geometry observer emits changes, not a new sample on every layout pass.
            // Use a fresh host for each independent width so unchanged button rectangles
            // cannot disappear merely because the evidence dictionary was cleared.
            rectangles.removeAll()
            host = NSHostingView(rootView: browser)
            window.contentView = host
            await settle(host, window: window, width: width)
            for id in ["assets-filter-other", "resource-document-\(text.id.uuidString)", "asset-preview"] {
                let rectangle = try #require(rectangles[id], "missing real control \(id)")
                #expect(rectangle.width > 0 && rectangle.height > 0)
                #expect(rectangle.minX >= -1 && rectangle.maxX <= width + 1)
            }
        }
        #expect(opened.isEmpty)
        let actual = try #require(actions)
        actual.select(.document(text.id))
        await settle(host, window: window, width: 260)
        #expect(opened.isEmpty)
        actual.setIncludeOtherModes(true)
        await settle(host, window: window, width: 260)
        #expect(opened.isEmpty)
        actual.openSelected()
        #expect(opened.isEmpty, "Changing the scope clears the preview selection.")
        actual.select(.document(text.id))
        await settle(host, window: window, width: 260)
        actual.openSelected()
        #expect(opened == [text.id])
    }

    @Test func audioUsesRecordedMetadataAndUnknownSelectionNeverResolvesURL() async throws {
        let audio = ProjectAsset(id: UUID(), relativePath: "audio", mediaType: "audio/wav",
                                 metadata: .init(audio: .init(format: .init(container: .wav, sampleRate: 44_100,
                                                                            channelCount: 2, frameCount: 88_200,
                                                                            bitDepth: 32, floatingPoint: true),
                                                               contentSHA256: "fixture", origin: .importedFile)), name: "录音")
        let unknown = ProjectAsset(id: UUID(), relativePath: "unknown.png", mediaType: "application/octet-stream",
                                   name: "未知")
        let manifest = ProjectManifest(name: "fixture", assets: [audio, unknown])
        var resolvedURLs = 0
        var actions: ProjectResourceBrowserTestingActions?
        let host = NSHostingView(rootView: ProjectResourceBrowser(manifest: manifest, mode: .audio,
            availableModes: [.audio], assetURL: { _ in resolvedURLs += 1; return nil }, onOpenDocument: { _ in })
            .observingActions { actions = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host, window: window, width: 260)
        let actual = try #require(actions)
        actual.select(.media(audio.id))
        await settle(host, window: window, width: 260)
        #expect(actual.selectedAudioDescription()?.contains("44100 Hz") == true)
        #expect(resolvedURLs == 0)
        actual.setIncludeOtherModes(true)
        await settle(host, window: window, width: 260)
        actual.select(.media(unknown.id))
        await settle(host, window: window, width: 260)
        #expect(resolvedURLs == 0)
    }

    private func settle(_ host: NSHostingView<ProjectResourceBrowser>, window: NSWindow, width: CGFloat) async {
        window.setContentSize(NSSize(width: width, height: 520))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

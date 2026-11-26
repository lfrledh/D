import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkbenchNavigationViewsTests {
    @Test
    func chooserRendersSuppliedUnicodeSummariesAndEmptyStateWithoutOpeningAnything() {
        let recent = RecentProjectSummary(
            id: "saved-project",
            name: "很长的中文项目 👩‍💻 e\u{301}",
            detail: "外置磁盘 · 昨天"
        )
        var rectangles: [String: CGRect] = [:]
        let populated = ProjectChooserView(
            recentProjects: [recent], isBusy: false,
            onNew: {}, onOpen: {}, onRecent: { _ in }, onModels: {}
        ).observingLayout { rectangles[$0] = $1 }
        let populatedHost = NSHostingView(rootView: populated)
        settle(populatedHost, width: 860, height: 580)

        for identifier in ["new-project", "open-project", "open-model-library", "recent-project-saved-project"] {
            let rectangle = rectangles[identifier]
            #expect(rectangle?.width ?? 0 > 0)
            #expect(rectangle?.height ?? 0 > 0)
            #expect(isInsideViewport(rectangle, of: populatedHost))
        }

        rectangles.removeAll()
        let empty = ProjectChooserView(
            recentProjects: [], isBusy: true,
            onNew: {}, onOpen: {}, onRecent: { _ in }, onModels: {}
        ).observingLayout { rectangles[$0] = $1 }
        let emptyHost = NSHostingView(rootView: empty)
        settle(emptyHost, width: 860, height: 580)
        #expect(rectangles["recent-projects-empty"] != nil)
        #expect(rectangles["recent-project-saved-project"] == nil)
    }

    @Test
    func documentListShowsOnlyTheRequestedModalityAndKeepsStableIdentifiers() {
        let image = ProjectDocument(name: "图像 e\u{301}", kind: .image)
        let text = ProjectDocument(name: "文字 👩‍💻", kind: .text)
        let audio = ProjectDocument(name: "声音 🎵", kind: .audio)
        var rectangles: [String: CGRect] = [:]
        let view = ModalityDocumentList(
            documents: [image, text, audio], mode: .text, selectedDocumentID: text.id,
            onSelect: { _ in }, onCreate: {}
        ).observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        settle(host, width: 260, height: 500)

        #expect(rectangles["document-\(text.id.uuidString)"] != nil)
        #expect(rectangles["document-\(image.id.uuidString)"] == nil)
        #expect(rectangles["document-\(audio.id.uuidString)"] == nil)
        #expect(rectangles["new-text-document"] != nil)
        #expect(rectangles["new-document"] == nil)
        #expect(rectangles["new-audio-creation"] == nil)
    }

    @Test
    func emptyModalityDoesNotCreateOrBorrowADocument() {
        let image = ProjectDocument(name: "已有图像", kind: .image)
        var rectangles: [String: CGRect] = [:]
        let view = ModalityDocumentList(
            documents: [image], mode: .audio, selectedDocumentID: image.id,
            onSelect: { _ in }, onCreate: {}
        ).observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        settle(host, width: 260, height: 500)

        #expect(rectangles["modality-documents-empty"] != nil)
        #expect(rectangles["document-\(image.id.uuidString)"] == nil)
        #expect(rectangles["new-audio-creation"] != nil)
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func isInsideViewport<Content: View>(_ rectangle: CGRect?, of host: NSHostingView<Content>) -> Bool {
        guard let rectangle else { return false }
        let viewport = host.bounds.insetBy(dx: -1, dy: -1)
        return rectangle.minX >= viewport.minX && rectangle.maxX <= viewport.maxX
            && rectangle.minY >= viewport.minY && rectangle.maxY <= viewport.maxY
    }
}

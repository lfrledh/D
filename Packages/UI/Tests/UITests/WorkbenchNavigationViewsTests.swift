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

    @Test(arguments: [CGFloat(860), CGFloat(1_024), CGFloat(1_440)])
    func workspaceKeepsNavigationAndEditorInsideSupportedWidths(width: CGFloat) {
        let (host, rectangles) = hostedShell(width: width, hasInspector: true)

        for identifier in [
            "back-to-projects", "open-project-tasks", "open-model-library",
            "toggle-creations", "toggle-inspector", "creator-mode-image", "creator-mode-text", "shell-editor"
        ] {
            let rectangle = rectangles[identifier]
            #expect(rectangle?.width ?? 0 > 0, "Missing \(identifier) at width \(width)")
            #expect(rectangle?.height ?? 0 > 0, "Missing \(identifier) at width \(width)")
            #expect(isInsideViewport(rectangle, of: host), "\(identifier) is clipped at width \(width)")
        }
        #expect(rectangles["creator-mode-audio"] == nil)
        #expect(rectangles["shell-sidebar"] != nil)
        #expect((rectangles["shell-inspector"] != nil) == (width >= 1_100))
        #expect(host.fittingSize.width <= width + 1)
    }

    @Test
    func unsupportedInspectorHasNeitherAColumnNorAControl() {
        let (_, rectangles) = hostedShell(width: 1_440, hasInspector: false)
        #expect(rectangles["toggle-inspector"] == nil)
        #expect(rectangles["shell-inspector"] == nil)
        #expect(rectangles["shell-editor"] != nil)
    }

    @Test
    func veryNarrowPresentationMovesBothSecondaryColumnsOutOfTheEditor() {
        let (host, rectangles) = hostedShell(width: 620, hasInspector: true)
        #expect(rectangles["shell-sidebar"] == nil)
        #expect(rectangles["shell-inspector"] == nil)
        #expect(rectangles["shell-editor"] != nil)
        for identifier in ["toggle-creations", "toggle-inspector", "back-to-projects", "open-project-tasks"] {
            #expect(isInsideViewport(rectangles[identifier], of: host))
        }
    }

    private func hostedShell(
        width: CGFloat,
        hasInspector: Bool
    ) -> (NSHostingView<ProjectWorkspaceShell<Text, Text, Text>>, [String: CGRect]) {
        var rectangles: [String: CGRect] = [:]
        let view = ProjectWorkspaceShell(
            projectName: "这是一个很长的项目名称 👩‍💻 e\u{301} — 不应挤掉项目导航",
            mode: .text,
            availableModes: [.image, .text, .text],
            hasInspector: hasInspector,
            taskCount: 12,
            onMode: { _ in }, onBack: {}, onTasks: {}, onModels: {},
            sidebar: { Text("创作列表") },
            editor: { Text("编辑器") },
            inspector: { Text("创作参数") }
        ).observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        settle(host, width: width, height: 580)
        return (host, rectangles)
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

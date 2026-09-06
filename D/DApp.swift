import AppKit
import SwiftUI
import UI

@main
struct DApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchApplicationDelegate.self) private var applicationDelegate
    @State private var model = WorkbenchModel(sessionFactory: AppSessionFactory.makeSession)

    var body: some Scene {
        Window("D", id: "workbench") {
            WorkbenchView(model: model)
                .background(WorkbenchWindowConnection(delegate: applicationDelegate, model: model))
                .task { await model.restoreLastProject() }
                .onOpenURL { url in Task { await model.openProject(at: url) } }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { WorkbenchCommands(model: model) }
    }
}

private struct WorkbenchCommands: Commands {
    let model: WorkbenchModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建项目…") {
                openWindow(id: "workbench")
                Task { await model.newProject() }
            }
            .keyboardShortcut("n")
            .disabled(model.isChangingProject)

            Button("打开项目…") {
                openWindow(id: "workbench")
                Task { await model.openProject() }
            }
            .keyboardShortcut("o")
            .disabled(model.isChangingProject)
        }
        CommandGroup(after: .importExport) {
            Button("导出所选作品…") { Task { await model.exportSelected() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedAsset == nil)
        }
        CommandMenu("创作") {
            Button("生成图片") { Task { await model.generate() } }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canGenerate)
            Button("注册本地模型…") { Task { await model.registerModel() } }
                .disabled(model.manifest == nil || model.isBusy || model.isChangingProject)
        }
    }
}

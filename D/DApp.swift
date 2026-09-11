import AppKit
import DWorkbench
import SwiftUI
import UI

@main
struct DApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchApplicationDelegate.self) private var applicationDelegate
    @State private var bootstrap = WorkbenchBootstrap()

    var body: some Scene {
        Window("D", id: "workbench") {
            Group {
                if let model = bootstrap.model, let library = bootstrap.libraryModel {
                    WorkbenchView(model: model, library: library)
                        .background(WorkbenchWindowConnection(delegate: applicationDelegate, model: model,
                            prepareLibraryForTermination: bootstrap.prepareLibraryForTermination))
                } else if let error = bootstrap.startupError {
                    VStack(spacing: 18) {
                        Label("无法准备工作台", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title2)
                        Text(error).textSelection(.enabled).multilineTextAlignment(.center)
                        Button("重试") { Task { await bootstrap.start() } }.buttonStyle(.glassProminent)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("正在准备工作台…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(bootstrap.isTerminating)
            .task { await bootstrap.start() }
            .onOpenURL { url in Task { await bootstrap.openProject(at: url) } }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { WorkbenchCommands(bootstrap: bootstrap) }
    }
}

private struct WorkbenchCommands: Commands {
    let bootstrap: WorkbenchBootstrap
    @Environment(\.openWindow) private var openWindow
    private var modalResourceOperation: Bool {
        bootstrap.libraryModel?.isPresented == true || bootstrap.libraryModel?.isChoosingLocation == true
            || bootstrap.model?.hasPendingEditor == true
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建项目…") {
                openWindow(id: "workbench")
                Task { await bootstrap.model?.newProject() }
            }
            .keyboardShortcut("n")
            .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model == nil || bootstrap.model?.isChangingProject == true)

            Button("打开项目…") {
                openWindow(id: "workbench")
                Task { await bootstrap.model?.openProject() }
            }
            .keyboardShortcut("o")
            .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model == nil || bootstrap.model?.isChangingProject == true)
        }
        CommandGroup(after: .importExport) {
            Button("导出所选作品…") { Task { await bootstrap.model?.exportSelected() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model?.selectedAsset == nil || bootstrap.model?.creatorMode != .image)
        }
        CommandMenu("创作") {
            Button(bootstrap.model?.visibleGenerationTitle ?? "生成") {
                Task { await bootstrap.model?.generateVisible() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model?.canRunVisibleGeneration != true)
            Button("保存文稿") { Task { await bootstrap.model?.projectSession.saveText() } }
                .keyboardShortcut("s")
                .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model?.projectSession.text == nil || bootstrap.model?.creatorMode != .text)
        }
        CommandMenu("资源") {
            Button("管理模型…") {
                openWindow(id: "workbench")
                bootstrap.libraryModel?.isPresented = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(bootstrap.isTerminating || bootstrap.libraryModel == nil)
        }
    }
}

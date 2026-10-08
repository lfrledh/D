import AppKit
import DWorkbench
import SwiftUI
import UI

@main
struct DApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchApplicationDelegate.self) private var applicationDelegate
    @State private var bootstrap = WorkbenchBootstrap()
    @State private var settingsRequest: UUID?
    @State private var fallbackSettingsVisible = false

    private var fallbackSettingsReady: Bool {
        bootstrap.quick == nil && bootstrap.model != nil && bootstrap.libraryModel != nil
            && bootstrap.startupError != nil && !applicationDelegate.hasPresentedSheet
    }
    private func consumeFallbackSettings() {
        guard settingsRequest != nil, fallbackSettingsReady else { return }
        settingsRequest = nil; fallbackSettingsVisible = true
    }

    private var deploymentProbeEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return UUID(uuidString: env["D_UI_TEST_SESSION"] ?? "") != nil
            && env["D_AUDIO_DEPLOYMENT_CHECK"] == "1"
            && env["D_AUDIO_PROBE_PYTHON"]?.hasPrefix("/") == true
            && env["D_AUDIO_PROBE_SHA256"]?.count == 64
        #else
        return false
        #endif
    }

    var body: some Scene {
        Window("D", id: "workbench") {
            Group {
                if deploymentProbeEnabled {
                    #if DEBUG
                    AudioDeploymentCheck(expectedExecutable: ProcessInfo.processInfo.environment["D_AUDIO_PROBE_PYTHON"]!,
                        expectedDigest: ProcessInfo.processInfo.environment["D_AUDIO_PROBE_SHA256"]!)
                    #endif
                } else if let model = bootstrap.model, let library = bootstrap.libraryModel,
                          let quickModel = bootstrap.quickModel, let quick = bootstrap.quick, let nodeTags = bootstrap.nodeTags {
                    DualWorkbenchView(model: model, quickModel: quickModel, quick: quick, library: library, nodeTags: nodeTags, metadata: bootstrap.sharedLibrary, metadataIssue: bootstrap.sharedLibraryIssue, settingsRequest: $settingsRequest, windowHasSheet: applicationDelegate.hasPresentedSheet)
                        .background(WorkbenchWindowConnection(delegate: applicationDelegate, model: model,
                            prepareLibraryForTermination: bootstrap.prepareLibraryForTermination,
                            prepareQuickForTermination: bootstrap.prepareQuickForTermination, cancelTermination: bootstrap.cancelTermination))
                } else if let model = bootstrap.model, let library = bootstrap.libraryModel, let tags = bootstrap.nodeTags {
                    VStack(spacing: 0) {
                        if let issue = bootstrap.startupError { Text(issue).textSelection(.enabled).padding().background(.regularMaterial) }
                        WorkbenchView(model: model, library: library, nodeTags: tags)
                    }.background(WorkbenchWindowConnection(delegate: applicationDelegate, model: model,
                        prepareLibraryForTermination: bootstrap.prepareLibraryForTermination,
                            prepareQuickForTermination: bootstrap.prepareQuickForTermination, cancelTermination: bootstrap.cancelTermination))
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
            .safeAreaInset(edge: .bottom) {
                if bootstrap.audioEngineIssue != nil || bootstrap.videoEngineIssue != nil {
                    let issue = [bootstrap.audioEngineIssue, bootstrap.videoEngineIssue].compactMap { $0 }.joined(separator: "\n")
                    Text(issue).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(.regularMaterial)
                }
            }
            .environment(\.dLanguageStore, bootstrap.languageStore)
            .disabled(bootstrap.isTerminating)
            .onChange(of: settingsRequest) { _, _ in consumeFallbackSettings() }
            .onChange(of: fallbackSettingsReady) { _, ready in if ready { consumeFallbackSettings() } }
            .sheet(isPresented: $fallbackSettingsVisible) {
                if let model = bootstrap.model, let library = bootstrap.libraryModel {
                    VStack(spacing: 0) {
                        if let issue = bootstrap.startupError { Text(issue).textSelection(.enabled).padding() }
                        WorkbenchSettingsView(model: model, library: library, language: bootstrap.languageStore,
                            projectPath: model.projectSession.currentStore?.rootURL.path, searchTargetLabel: nil,
                            onProjectFiles: nil, onSearchSettings: nil)
                    }
                }
            }
            .task { if !deploymentProbeEnabled { await bootstrap.start() } }
            .onOpenURL { url in
                if deploymentProbeEnabled { print("D_AUDIO_DEPLOYMENT_IGNORED_OPEN_REQUEST") }
                else { Task { await bootstrap.openProject(at: url) } }
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { WorkbenchCommands(bootstrap: bootstrap, settingsBlocked: applicationDelegate.hasPresentedSheet, requestSettings: { settingsRequest = UUID() }) }
    }
}

private struct WorkbenchCommands: Commands {
    let bootstrap: WorkbenchBootstrap
    let settingsBlocked: Bool
    let requestSettings: () -> Void
    @FocusedValue(\.workbenchGeneration) private var generationCommand
    @Environment(\.openWindow) private var openWindow
    private var modalResourceOperation: Bool {
        bootstrap.libraryModel?.isPresented == true || bootstrap.libraryModel?.isChoosingLocation == true
            || bootstrap.model?.hasPendingEditor == true
    }

    private func label(_ key: String, _ fallback: String) -> String { bootstrap.languageStore.text(key, fallback: fallback) }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(label("refinement.settings.title", "设置") + "…") {
                // A single pending intent survives a closed window or an existing sheet.
                // The workbench captures its exact owner only when presentation is admitted.
                requestSettings()
                openWindow(id: "workbench")
            }.keyboardShortcut(",", modifiers: .command)
                .disabled(bootstrap.isTerminating || settingsBlocked || modalResourceOperation)
        }
        CommandGroup(replacing: .newItem) {
            Button(label("command.project.new", "新建项目…")) {
                openWindow(id: "workbench")
                Task { await bootstrap.model?.newProject() }
            }
            .keyboardShortcut("n")
            .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model == nil || bootstrap.model?.isChangingProject == true)

            Button(label("command.project.open", "打开项目…")) {
                openWindow(id: "workbench")
                Task { await bootstrap.model?.openProject() }
            }
            .keyboardShortcut("o")
            .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model == nil || bootstrap.model?.isChangingProject == true)
        }
        CommandGroup(after: .importExport) {
            Button(label("command.asset.export", "导出所选作品…")) { Task { await bootstrap.model?.exportSelected() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model?.selectedAsset == nil || bootstrap.model?.creatorMode != .image)
        }
        CommandMenu(label("command.creation", "创作")) {
            Button(generationCommand?.title ?? bootstrap.model?.visibleGenerationTitle ?? "生成") {
                generationCommand?.action()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(modalResourceOperation || bootstrap.isTerminating || generationCommand?.isEnabled != true)
            Button(label("command.text.save", "保存文稿")) { Task { await bootstrap.model?.projectSession.saveText() } }
                .keyboardShortcut("s")
                .disabled(modalResourceOperation || bootstrap.isTerminating || bootstrap.model?.projectSession.text == nil || bootstrap.model?.creatorMode != .text)
        }
        CommandMenu(label("command.resources", "资源")) {
            Button(label("command.models", "管理模型…")) {
                openWindow(id: "workbench")
                bootstrap.libraryModel?.isPresented = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(bootstrap.isTerminating || bootstrap.libraryModel == nil)
        }
    }
}

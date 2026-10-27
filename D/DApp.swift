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
        guard (try? WorkbenchLaunchContext.current.get().permitsDeploymentProbe) == true else { return false }
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
                    AudioDeploymentCheck(language: bootstrap.languageStore, expectedExecutable: ProcessInfo.processInfo.environment["D_AUDIO_PROBE_PYTHON"]!,
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
                        if let issue = bootstrap.startupError { Text(issue).textSelection(.enabled).padding().modifier(DOpaqueNoticePlate()) }
                        WorkbenchView(model: model, library: library, nodeTags: tags)
                    }.background(WorkbenchWindowConnection(delegate: applicationDelegate, model: model,
                        prepareLibraryForTermination: bootstrap.prepareLibraryForTermination,
                            prepareQuickForTermination: bootstrap.prepareQuickForTermination, cancelTermination: bootstrap.cancelTermination))
                } else if let error = bootstrap.startupError {
                    VStack(spacing: 18) {
                        Label(bootstrap.languageStore.text("workbench.startup.failed", fallback: "—"), systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title2)
                        Text(error).textSelection(.enabled).multilineTextAlignment(.center)
                        Button(bootstrap.languageStore.text("workbench.startup.retry", fallback: "—")) { Task { await bootstrap.start() } }.buttonStyle(.glassProminent)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView(bootstrap.languageStore.text("workbench.startup.preparing", fallback: "—"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if bootstrap.audioEngineIssue != nil || bootstrap.videoEngineIssue != nil {
                    let issue = [bootstrap.audioEngineIssue, bootstrap.videoEngineIssue].compactMap { $0 }.joined(separator: "\n")
                    Text(issue).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .modifier(DOpaqueNoticePlate())
                }
            }
            .environment(\.dLanguageStore, bootstrap.languageStore)
            .disabled(bootstrap.isTerminating)
            .onAppear { consumeFallbackSettings() }
            .onChange(of: settingsRequest) { _, _ in consumeFallbackSettings() }
            .onChange(of: fallbackSettingsReady) { _, ready in if ready { consumeFallbackSettings() } }
            .workbenchSheet(isPresented: $fallbackSettingsVisible, title: bootstrap.languageStore.text("refinement.settings.title", fallback: "设置")) {
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
    @FocusedValue(\.workbenchCanvas) private var canvasCommands
    @FocusedValue(\.workbenchWorkspace) private var workspace
    @FocusedValue(\.workbenchAssetExport) private var exportCommand
    @FocusedValue(\.workbenchChat) private var chatCommands
    @Environment(\.openWindow) private var openWindow
    private var modalResourceOperation: Bool {
        settingsBlocked || bootstrap.libraryModel?.isPresented == true || bootstrap.libraryModel?.isChoosingLocation == true
            || bootstrap.model?.hasPendingEditor == true
    }
    private var blocked: Bool { bootstrap.isTerminating || modalResourceOperation }
    private var navigationBlocked: Bool { bootstrap.isTerminating || bootstrap.libraryModel?.isChoosingLocation == true || NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil }
    private var current: Bool { workspace?.scope.permitsNavigation == true && !navigationBlocked }
    private var canvas: WorkbenchCanvasCommands? {
        guard workspace?.workflow == true, current, canvasCommands?.scope?.permitsCommands == true else { return nil }
        return canvasCommands
    }
    private var visibleSave: WorkbenchGenerationCommand? {
        // Save belongs to the displayed project owner, not the canvas selection
        // or its SwiftUI focus. The shared owner command revalidates that owner;
        // the native scope still blocks hidden pages, child panels and sheets.
        guard current, let workspace, workspace.scope.permitsVisibleCommands,
              workspace.save.isEnabled else { return nil }
        return workspace.save
    }
    private var generation: WorkbenchGenerationCommand? { workspace?.workflow == true ? canvas?.run : workspace?.chat == true ? chatCommands?.run : generationCommand }
    private func label(_ key: String, _ fallback: String = "—") -> String { bootstrap.languageStore.text(key, fallback: fallback) }
    private func text(_ key: String) -> String { label("systemMenu." + key) }
    @ViewBuilder private func button(_ command: WorkbenchGenerationCommand?, title: String) -> some View {
        Button(command?.title ?? title) { if !blocked { command?.action() } }
            .disabled(blocked || command?.isEnabled != true)
    }
    @ViewBuilder private func choices(_ items: [WorkbenchChoiceCommand]) -> some View {
        ForEach(items.indices, id: \.self) { i in
            let item = items[i]
            Toggle(item.command.title, isOn: Binding(get: { item.selected }, set: { selected in if selected { item.command.action() } }))
                .disabled(!current || !item.command.isEnabled)
        }
    }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(label("refinement.settings.title", "设置") + "…") { WorkbenchChildPanels.navigate(on: NSApp.keyWindow) { requestSettings(); openWindow(id: "workbench") } }
                .keyboardShortcut(",", modifiers: .command).disabled(navigationBlocked)
        }
        CommandGroup(replacing: .newItem) {
            Button(label("command.project.new")) {
                if let workspace, current { workspace.newProject.action() }
                else if !blocked && NSApp.keyWindow == nil { openWindow(id: "workbench"); Task { await bootstrap.model?.newProject() } }
            }.keyboardShortcut("n").disabled(navigationBlocked || bootstrap.model == nil || (NSApp.keyWindow != nil && (!current || workspace?.newProject.isEnabled != true)))
            Button(label("command.project.open")) {
                if let workspace, current { workspace.openProject.action() }
                else if !blocked && NSApp.keyWindow == nil { openWindow(id: "workbench"); Task { await bootstrap.model?.openProject() } }
            }.keyboardShortcut("o").disabled(navigationBlocked || bootstrap.model == nil || (NSApp.keyWindow != nil && (!current || workspace?.openProject.isEnabled != true)))
            Menu(text("recent")) {
                if let workspace, !workspace.recent.isEmpty {
                    ForEach(workspace.recent.indices, id: \.self) { i in button(workspace.recent[i], title: "") }
                } else if let model = bootstrap.model, !model.recentProjects.isEmpty {
                    ForEach(model.recentProjects) { project in
                        Button(project.name) {
                            guard !blocked, NSApp.keyWindow == nil else { return }
                            openWindow(id: "workbench"); Task { await model.openRecentProject(id: project.id) }
                        }.disabled(NSApp.keyWindow != nil)
                    }
                } else { Button(text("recentEmpty")) {}.disabled(true) }
            }.disabled(blocked || (NSApp.keyWindow != nil && !current))
        }
        CommandGroup(replacing: .saveItem) {
            Button(label("layoutInteraction.save", "保存更改")) { visibleSave?.action() }
                .keyboardShortcut("s").disabled(visibleSave?.isEnabled != true)
            button(current ? workspace?.files : nil, title: label("layoutInteraction.projectFiles"))
            if let workspace, !workspace.quickDestination.isEmpty {
                Menu(label("layoutInteraction.quickDestination")) { choices(workspace.quickDestination) }
            }
        }
        CommandGroup(replacing: .importExport) {
            button(current ? workspace?.importAsset : nil, title: text("import"))
            Button(text("export")) { if !bootstrap.isTerminating { exportCommand?.action() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(bootstrap.isTerminating || exportCommand?.isEnabled != true)
            Divider()
            Menu(label("layoutInteraction.advanced")) { button(current ? workspace?.legacy : nil, title: label("layoutInteraction.legacy")) }
            Divider()
            Button(label("command.window.close")) { WorkbenchWindowCloseCommand.perform(on: NSApp.keyWindow) }
                .keyboardShortcut("w").disabled(bootstrap.isTerminating || NSApp.keyWindow == nil || NSApp.keyWindow?.attachedSheet != nil)
        }
        CommandGroup(after: .undoRedo) {
            Menu(label("workflow.dock.nodeEditing")) {
                ForEach(Array((canvas?.edit ?? []).enumerated()), id: \.offset) { _, command in
                    Button(command.title, action: command.action).disabled(!command.isEnabled || NSApp.keyWindow?.firstResponder is NSTextView)
                }
            }.disabled(canvas == nil || NSApp.keyWindow?.firstResponder is NSTextView)
        }
        CommandGroup(replacing: .sidebar) {
            choices(workspace?.modes ?? [])
            Divider()
            let sidebars = workspace?.workflow == true ? (canvas?.sidebars ?? []) : (current ? workspace?.sidebars ?? [] : [])
            ForEach(sidebars.indices, id: \.self) { i in button(sidebars[i], title: "") }
            Divider()
            if let canvas {
                ForEach(canvas.zoom.indices, id: \.self) { i in button(canvas.zoom[i], title: "") }
            } else {
                ForEach(["zoomIn", "zoomOut", "actualSize", "fit"], id: \.self) { key in button(nil, title: text(key)) }
            }
        }
        CommandMenu(label("command.creation", "创作")) {
            if workspace?.chat == true {
                // The native composer exclusively owns its send shortcut.
                button(current ? generation : nil, title: text("generate"))
            } else {
                Button(generation?.title ?? text("generate")) { if current { generation?.action() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!current || generation?.isEnabled != true || NSApp.keyWindow?.firstResponder is NSTextView)
            }
            button(canvas?.settings, title: text("runSettings"))
            button(canvas?.pause, title: text("pause"))
            button(canvas?.resume, title: text("resume"))
            button(workspace?.workflow == true ? canvas?.stop : (current ? (workspace?.chat == true ? chatCommands?.stop : workspace?.stop) : nil), title: text("stop"))
            if let retry = workspace?.workflow == true ? canvas?.retrySave : (current ? (workspace?.chat == true ? chatCommands?.retrySave : workspace?.retrySave) : nil) { button(retry, title: text("retrySave")) }
            Divider()
            Menu(text("workflow")) {
                Menu(label("workflow.management.switch")) { choices(canvas?.workflowChoices ?? []) }
                Divider()
                button(canvas?.workflow.first, title: text("blankFlow"))
                // Menu children can update after the key window is lost. Keep
                // the offered values; each action still revalidates its scope.
                Menu(text("templates")) {
                    ForEach(Array((canvas?.templates ?? []).enumerated()), id: \.offset) { _, command in button(command, title: "") }
                }
                Divider()
                button(canvas?.save, title: label("layoutInteraction.save"))
                ForEach(Array((canvas?.workflow ?? []).dropFirst().enumerated()), id: \.offset) { _, command in button(command, title: "") }
            }.disabled(canvas == nil)
            Divider()
            button(canvas?.manageNodes, title: label("layoutInteraction.manageNodes"))
        }
        CommandGroup(before: .windowList) {
            Button(text("showWorkbench")) { openWindow(id: "workbench") }.disabled(bootstrap.isTerminating)
            Button(label("modelManagement.downloadTitle") + "…") { WorkbenchChildPanels.navigate(on: NSApp.keyWindow) { openWindow(id: "workbench"); bootstrap.libraryModel?.presentDownloads() } }
                .disabled(navigationBlocked || bootstrap.libraryModel == nil)
            Button(label("command.models")) { WorkbenchChildPanels.navigate(on: NSApp.keyWindow) { openWindow(id: "workbench"); bootstrap.libraryModel?.presentManagement() } }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(navigationBlocked || bootstrap.libraryModel == nil)
        }
        CommandGroup(replacing: .help) {
            button(current ? workspace?.help : nil, title: text("guide"))
            button(current ? workspace?.thirdPartyNotices : nil, title: label("notices.title"))
            if let command = canvas?.legend { button(command, title: "") }
        }
    }
}

/// Startup/service notices outside the canvas use an explicit opaque fallback.
/// System window chrome and standard buttons retain their normal OS appearance.
private struct DOpaqueNoticePlate: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.foregroundStyle(scheme == .dark ? Color(red: 0.91, green: 0.95, blue: 0.93) : Color(red: 0.09, green: 0.18, blue: 0.16))
            .background(scheme == .dark ? Color(red: 0.11, green: 0.17, blue: 0.15) : Color(red: 0.98, green: 0.99, blue: 0.98))
    }
}

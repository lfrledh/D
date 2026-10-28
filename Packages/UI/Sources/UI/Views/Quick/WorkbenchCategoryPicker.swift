import DWorkbench
import SwiftUI
import os

/// Preview state stays inside the shared control; only release reaches the owner.
struct WorkbenchCategoryPicker: View {
    let selection: QuickCategory
    let owner: ObjectIdentifier
    let enabled: Bool
    let onSelect: (QuickCategory) -> Void
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        WorkbenchGlassSegments(title: workflowText(language, "refinement.shell.category"),
            selection: Binding(get: { selection }, set: onSelect),
            choices: QuickCategory.allCases.map { ($0, workflowText(language, "quick.category.\($0.rawValue)", fallback: $0.rawValue)) },
            identifiers: QuickCategory.allCases.map { "quick-category-\($0.rawValue)" },
            owner: AnyHashable(owner), standard: true, trackThickness: 32)
            .frame(width: 264).disabled(!enabled).accessibilityIdentifier("quick-category")
    }
}

#if DEBUG
/// Opt-in counters for the bounded hosting regression; nil in ordinary use.
@MainActor enum WorkbenchCategoryUpdateProbe {
    static var workbenchBody: (() -> Void)?
    static var retainedUpdate: (() -> Void)?
    private static let enabled = ProcessInfo.processInfo.environment["D_UI_DRAG_TRACE"] == "1"
    private static var events = 0, rootUpdates = 0, retainedUpdates = 0, presentations = 0
    private static var started: TimeInterval?
    private static var lastInput: TimeInterval?
    private static var maxLag: TimeInterval = 0
    static var phaseObserver: ((String) -> Void)?
    private static var committedAt: TimeInterval?
    private static var deliveredPhases = Set<String>()
    private static var postCommitRoots = 0, postCommitHosts = 0
    private static var backgroundStart = WorkbenchBackgroundCounters.Snapshot()
    static func beginCommit() {
        phaseObserver?("commit")
        guard enabled else { return }
        committedAt = ProcessInfo.processInfo.systemUptime; deliveredPhases = []
        backgroundStart = WorkbenchBackgroundCounters.snapshot
        postCommitRoots = 0; postCommitHosts = 0
        workbenchBody = { postCommitRoots += 1 }
        retainedUpdate = { postCommitHosts += 1 }
        phase("commit")
    }
    static func phase(_ name: String) {
        phaseObserver?(name)
        guard let committedAt, deliveredPhases.insert(name).inserted else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - committedAt) * 1000
        let background = WorkbenchBackgroundCounters.snapshot
        Logger(subsystem: "com.dworkbench.ui", category: "category-release").notice(
            "phase=\(name) elapsedMs=\(ms) root=\(postCommitRoots) retained=\(postCommitHosts) decodes=\(background.decodes-backgroundStart.decodes) blurs=\(background.blurs-backgroundStart.blurs) backgroundDraws=\(background.draws-backgroundStart.draws)")
    }
    static func beginTrace() {
        guard enabled else { return }
        committedAt = nil; deliveredPhases = []
        events = 0; rootUpdates = 0; retainedUpdates = 0; presentations = 0; maxLag = 0
        started = ProcessInfo.processInfo.systemUptime
        backgroundStart = WorkbenchBackgroundCounters.snapshot
        workbenchBody = { rootUpdates += 1 }; retainedUpdate = { retainedUpdates += 1 }
    }
    static func inputTrace() {
        guard started != nil else { return }
        events += 1; lastInput = ProcessInfo.processInfo.systemUptime
    }
    static func presentationTrace() {
        guard let lastInput else { return }
        presentations += 1; maxLag = max(maxLag, ProcessInfo.processInfo.systemUptime - lastInput)
        self.lastInput = nil
    }
    static func endTrace() {
        guard let started else { return }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let background = WorkbenchBackgroundCounters.snapshot
        Logger(subsystem: "com.dworkbench.ui", category: "category-drag").notice(
            "drag events=\(events) root=\(rootUpdates) retained=\(retainedUpdates) presentations=\(presentations) maxDeliveryMs=\(maxLag * 1000) seconds=\(seconds) decodes=\(background.decodes-backgroundStart.decodes) blurs=\(background.blurs-backgroundStart.blurs) backgroundDraws=\(background.draws-backgroundStart.draws)")
        self.started = nil; lastInput = nil; workbenchBody = nil; retainedUpdate = nil
    }
}
#endif

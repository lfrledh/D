import DWorkbench
import SwiftUI
import os

/// Mouse-rate presentation belongs to this small control. The workbench and its
/// retained editors only receive an actual category change on release.
struct WorkbenchCategoryPicker: View {
    let selection: QuickCategory
    let owner: ObjectIdentifier
    let enabled: Bool
    let onSelect: (QuickCategory) -> Void
    @Environment(\.dLanguageStore) private var language
    @Environment(\.chatDisplayPreferences) private var displayPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var controlsEnabled
    @FocusState private var focused: QuickCategory?
    @State private var hovered: QuickCategory?
    @State private var pressed: QuickCategory?
    @State private var preview: CGFloat?

    private var index: Int { QuickCategory.allCases.firstIndex(of: selection) ?? 0 }
    private var motion: Animation? {
        WorkbenchEffectsPolicy(appearance: displayPreferences.resolvedAppearance,
            reduceMotion: reduceMotion, reduceTransparency: false, increasedContrast: false).morphAnimation
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(QuickCategory.allCases, id: \.self) { category in
                Button { select(category) } label: {
                    Text(workflowText(language, "quick.category.\(category.rawValue)", fallback: category.rawValue))
                        .foregroundStyle(.clear)
                }
                .buttonStyle(WorkbenchCategoryButtonStyle(onPressChanged: { down in
                    if down { pressed = category } else if pressed == category { pressed = nil }
                }))
                .onHover { inside in
                    if inside && enabled { hovered = category } else if hovered == category { hovered = nil }
                }
                .focused($focused, equals: category)
                .accessibilityAddTraits(selection == category ? .isSelected : [])
                .accessibilityIdentifier("quick-category-\(category.rawValue)")
            }
        }
        .overlay(alignment: .leading) {
            WorkbenchCategoryLensTrack(selection: preview ?? CGFloat(index),
                titles: QuickCategory.allCases.map { workflowText(language, "quick.category.\($0.rawValue)", fallback: $0.rawValue) },
                engagement: preview != nil || pressed != nil ? 1 : 0,
                hovered: hovered.flatMap { QuickCategory.allCases.firstIndex(of: $0) },
                pressed: pressed.flatMap { QuickCategory.allCases.firstIndex(of: $0) },
                dragReceiver: WorkbenchCategoryDragReceiver(selection: index, owner: owner,
                    enabled: controlsEnabled && enabled, onPreview: { preview = $0 },
                    onCommit: { select(QuickCategory.allCases[$0]) }))
                .animation(preview == nil ? motion : nil, value: preview ?? CGFloat(index))
                .animation(motion, value: preview != nil || pressed != nil)
                .opacity(enabled ? 1 : 0.45)
        }
        .padding(4).frame(width: 264)
        .workbenchPanel(in: Capsule())
        .disabled(!enabled)
        .onChange(of: enabled) { _, available in if !available { clear() } }
        .onChange(of: controlsEnabled) { _, available in if !available { clear() } }
        .onChange(of: owner) { _, _ in clear() }
        .onChange(of: selection) { _, _ in preview = nil }
        .onDisappear { clear() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workflowText(language, "refinement.shell.category", fallback: "创作分类"))
        .accessibilityIdentifier("quick-category")
        .onMoveCommand { direction in
            guard enabled && controlsEnabled,
                  let current = QuickCategory.allCases.firstIndex(of: focused ?? selection) else { return }
            let next: Int
            switch direction {
            case .left: next = max(0, current - 1)
            case .right: next = min(QuickCategory.allCases.count - 1, current + 1)
            default: return
            }
            guard next != current else { return }
            select(QuickCategory.allCases[next]); focused = QuickCategory.allCases[next]
        }
    }

    private func select(_ category: QuickCategory) {
        guard enabled && controlsEnabled, category != selection else { return }
        onSelect(category)
    }
    private func clear() { preview = nil; hovered = nil; pressed = nil }
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
    static func beginTrace() {
        guard enabled else { return }
        events = 0; rootUpdates = 0; retainedUpdates = 0; presentations = 0; maxLag = 0
        started = ProcessInfo.processInfo.systemUptime
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
        Logger(subsystem: "com.dworkbench.ui", category: "category-drag").notice(
            "drag events=\(events) root=\(rootUpdates) retained=\(retainedUpdates) presentations=\(presentations) maxDeliveryMs=\(maxLag * 1000) seconds=\(seconds)")
        self.started = nil; lastInput = nil; workbenchBody = nil; retainedUpdate = nil
    }
}
#endif

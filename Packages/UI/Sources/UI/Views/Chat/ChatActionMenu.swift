import AppKit
import SwiftUI

/// A value captured by the caller for one menu update. IDs identify actions to
/// callers; the coordinator dispatches the exact closure of the displayed row.
struct ChatActionMenuItem: Identifiable {
    let id: String
    let title: String
    let enabled: Bool
    let selected: Bool
    let isSeparator: Bool
    let children: [ChatActionMenuItem]?
    let action: (@MainActor () -> Void)?

    init(id: String, title: String, enabled: Bool = true, selected: Bool = false,
         children: [ChatActionMenuItem]? = nil, isSeparator: Bool = false, action: (@MainActor () -> Void)? = nil) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.selected = selected
        self.isSeparator = isSeparator
        self.children = children
        self.action = action
    }
    static func grouped(_ items: [Self], ids: [[String]]) -> [Self] {
        var remaining = items, result: [Self] = []
        for group in ids {
            let members = group.compactMap { id -> Self? in
                guard let index = remaining.firstIndex(where: { $0.id == id }) else { return nil }
                return remaining.remove(at: index)
            }
            guard !members.isEmpty else { continue }
            if !result.isEmpty { result.append(.init(id: "separator-" + group[0], title: "", enabled: false, isSeparator: true)) }
            result += members
        }
        if !remaining.isEmpty {
            if !result.isEmpty { result.append(.init(id: "separator-other", title: "", enabled: false, isSeparator: true)) }
            result += remaining
        }
        return result
    }
}

/// AppKit owns the visible menu while it tracks; SwiftUI updates only replace a
/// pending snapshot until native tracking has fully ended.
@MainActor
struct ChatActionMenu: NSViewRepresentable {
    let title: String
    let accessibilityIdentifier: String
    let items: [ChatActionMenuItem]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = true
        button.autoenablesItems = false
        context.coordinator.install(on: button)
        context.coordinator.update(button, title: title,
                                   accessibilityIdentifier: accessibilityIdentifier, items: items, isEnabled: isEnabled)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.update(button, title: title,
                                   accessibilityIdentifier: accessibilityIdentifier, items: items, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.dismantle(button)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        private struct Snapshot {
            let title: String
            let accessibilityIdentifier: String
            let items: [ChatActionMenuItem]
        }

        private struct RowPresentation: Equatable {
            let id: String
            let title: String
            let enabled: Bool
            let selected: Bool
            let isSeparator: Bool
            let children: [RowPresentation]?
            let hasAction: Bool

            init(_ item: ChatActionMenuItem) {
                id = item.id; title = item.title; enabled = item.enabled; selected = item.selected; isSeparator = item.isSeparator
                children = item.children?.map(Self.init)
                hasAction = item.action != nil
            }
        }

        private struct DisplayedAction {
            let item: NSMenuItem
            let enabled: Bool
            let action: @MainActor () -> Void
        }

        private weak var button: NSPopUpButton?
        private var rootMenu: NSMenu?
        private var displayedActions: [ObjectIdentifier: DisplayedAction] = [:]
        // AppKit can send the item action after end-tracking, including after
        // the deferred drain has installed a newer snapshot.
        private var endedCycleActions: [ObjectIdentifier: DisplayedAction] = [:]
        private var pendingSnapshot: Snapshot?
        private var rowPresentation: [RowPresentation]?
        private var displayedTitle: String?
        private var displayedAccessibilityIdentifier: String?
        private var rowsNeedRenewal = false
        private var queuedActions: [@MainActor () -> Void] = []
        private var cycleStarted = false
        private var menuClosed = false
        private var trackingEnded = false
        private var selectionCaptured = false
        private var drainScheduled = false
        private var refreshOnNeedsUpdate = false
        private var dismantled = false

        private var isTracking: Bool {
            cycleStarted && !(menuClosed && trackingEnded)
        }

        func install(on button: NSPopUpButton) {
            button.menu = NSMenu()
            guard let menu = button.menu else { return }
            menu.autoenablesItems = false
            menu.delegate = self
            // AppKit may report a pull-down selection through the control as
            // well as the item; both paths share the one-shot gate below.
            button.target = self
            button.action = #selector(selectButton(_:))
            self.button = button
            rootMenu = menu
            NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking(_:)),
                                                   name: NSMenu.didEndTrackingNotification, object: menu)
        }

        func update(_ button: NSPopUpButton, title: String,
                    accessibilityIdentifier: String, items: [ChatActionMenuItem], isEnabled: Bool = true) {
            guard !dismantled, button === self.button else { return }
            // Control availability is immediate; menu rows/closures still obey
            // the existing immutable tracking snapshot and one-shot drain.
            button.isEnabled = isEnabled && !items.isEmpty
            if !button.isEnabled {
                // Re-enabling must not revive a late sender from this cancelled
                // cycle. Already captured selections remain queued exactly once.
                endedCycleActions.removeAll()
                if cycleStarted { selectionCaptured = true }
            }
            let snapshot = Snapshot(title: title, accessibilityIdentifier: accessibilityIdentifier, items: items)
            if cycleStarted {
                pendingSnapshot = snapshot
            } else {
                apply(snapshot, to: button)
            }
            if !button.isEnabled { rootMenu?.cancelTracking() }
        }

        private func apply(_ snapshot: Snapshot, to button: NSPopUpButton, renewRows: Bool = false) {
            guard let menu = rootMenu else { return }
            let presentation = snapshot.items.map(RowPresentation.init)
            // A late AppKit action must retain its old row identity across a
            // completed tracking cycle. Idle SwiftUI updates need no such rebuild.
            let rebuild = rowPresentation != presentation || renewRows || rowsNeedRenewal
            displayedActions.removeAll()
            if rebuild {
                menu.removeAllItems()
                // AppKit hides the first row of a standard pull-down. Reserve
                // it for the control title, never for a caller's first action.
                menu.addItem(NSMenuItem(title: snapshot.title, action: nil, keyEquivalent: ""))
                append(snapshot.items, to: menu, parentEnabled: true)
                rowPresentation = presentation
                rowsNeedRenewal = false
            } else {
                refreshActions(snapshot.items, in: menu)
            }
            if rebuild || displayedTitle != snapshot.title {
                menu.item(at: 0)?.title = snapshot.title
                button.synchronizeTitleAndSelectedItem()
            }
            if displayedTitle != snapshot.title {
                button.setAccessibilityLabel(snapshot.title)
                displayedTitle = snapshot.title
            }
            if displayedAccessibilityIdentifier != snapshot.accessibilityIdentifier {
                button.setAccessibilityIdentifier(snapshot.accessibilityIdentifier)
                displayedAccessibilityIdentifier = snapshot.accessibilityIdentifier
            }
        }

        private func refreshActions(_ values: [ChatActionMenuItem], in menu: NSMenu) {
            let rows = menu === rootMenu ? Array(menu.items.dropFirst()) : menu.items
            for (value, item) in zip(values, rows) {
                if let children = value.children, let submenu = item.submenu {
                    refreshActions(children, in: submenu)
                } else if let action = value.action {
                    displayedActions[ObjectIdentifier(item)] = DisplayedAction(item: item, enabled: item.isEnabled, action: action)
                }
            }
        }

        private func append(_ items: [ChatActionMenuItem], to menu: NSMenu, parentEnabled: Bool) {
            for value in items {
                if value.isSeparator { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: value.title, action: nil, keyEquivalent: "")
                item.representedObject = value.id
                item.isEnabled = parentEnabled && value.enabled
                item.state = value.selected ? .on : .off
                if let children = value.children {
                    let submenu = NSMenu(title: value.title)
                    submenu.autoenablesItems = false
                    append(children, to: submenu, parentEnabled: item.isEnabled)
                    item.submenu = submenu
                } else if let action = value.action {
                    item.target = self
                    item.action = #selector(selectItem(_:))
                    displayedActions[ObjectIdentifier(item)] = DisplayedAction(item: item, enabled: item.isEnabled, action: action)
                }
                menu.addItem(item)
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard !dismantled, menu === rootMenu else { return }
            // AppKit can reopen before the deferred drain. The next safe menu
            // update may install the pending rows; this callback only records
            // the new tracking cycle.
            refreshOnNeedsUpdate = cycleStarted && !isTracking && pendingSnapshot != nil
            endedCycleActions.removeAll()
            cycleStarted = true
            menuClosed = false
            trackingEnded = false
            selectionCaptured = false
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !dismantled, menu === rootMenu, let button else { return }
            if cycleStarted && !isTracking {
                // An ended cycle may still have a scheduled drain. Apply its
                // prepared snapshot here, but leave parent actions deferred.
                endedCycleActions = selectionCaptured ? [:] : displayedActions
                cycleStarted = false
            } else if !refreshOnNeedsUpdate {
                return
            }
            refreshOnNeedsUpdate = false
            if let pendingSnapshot {
                self.pendingSnapshot = nil
                apply(pendingSnapshot, to: button, renewRows: true)
            }
        }

        func menuDidClose(_ menu: NSMenu) {
            guard !dismantled, menu === rootMenu else { return }
            menuClosed = true
            // Even a selected cycle can deliver a duplicate sender after the
            // drain. The next update rotates rows once, then stays idle-stable.
            rowsNeedRenewal = true
            scheduleDrainIfFinished()
        }

        @objc private func menuDidEndTracking(_ notification: Notification) {
            guard !dismantled, let menu = notification.object as? NSMenu,
                  menu === rootMenu else { return }
            trackingEnded = true
            scheduleDrainIfFinished()
        }

        @objc func selectItem(_ sender: NSMenuItem) {
            guard !dismantled, !selectionCaptured, button?.isEnabled == true, sender.isEnabled,
                  let displayed = (cycleStarted ? displayedActions : endedCycleActions)[ObjectIdentifier(sender)],
                  displayed.item === sender, displayed.enabled else { return }
            selectionCaptured = true
            endedCycleActions.removeAll()
            if cycleStarted {
                queuedActions.append(displayed.action)
                scheduleDrainIfFinished()
            } else {
                displayed.action()
            }
        }

        @objc private func selectButton(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }
            selectItem(item)
        }

        private func scheduleDrainIfFinished() {
            guard !dismantled, cycleStarted, !isTracking, !drainScheduled else { return }
            drainScheduled = true
            // A menu delegate callback is still inside AppKit's tracking stack.
            // The next main-actor turn applies values and invokes parent actions.
            Task { @MainActor [weak self] in self?.drainAfterTracking() }
        }

        /// The same drain is called by the deferred native path and lifecycle tests.
        func drainAfterTracking() {
            guard !dismantled else { return }
            drainScheduled = false
            guard !isTracking else { return }
            if cycleStarted {
                endedCycleActions = selectionCaptured ? [:] : displayedActions
                if let pendingSnapshot, let button {
                    self.pendingSnapshot = nil
                    apply(pendingSnapshot, to: button, renewRows: true)
                }
                cycleStarted = false
            }
            let actions = queuedActions
            queuedActions.removeAll()
            actions.forEach { $0() }
        }

        func dismantle(_ button: NSPopUpButton) {
            guard !dismantled else { return }
            dismantled = true
            pendingSnapshot = nil
            refreshOnNeedsUpdate = false
            queuedActions.removeAll()
            displayedActions.removeAll()
            endedCycleActions.removeAll()
            if let menu = rootMenu {
                menu.cancelTracking()
                NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: menu)
                menu.delegate = nil
            }
            button.menu = nil
            button.target = nil
            button.action = nil
            rootMenu = nil
            self.button = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

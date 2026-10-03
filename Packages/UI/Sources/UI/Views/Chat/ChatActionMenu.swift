import AppKit
import SwiftUI

/// A value captured by the caller for one menu update. IDs identify actions to
/// callers; the coordinator dispatches the exact closure of the displayed row.
struct ChatActionMenuItem: Identifiable {
    let id: String
    let title: String
    let enabled: Bool
    let selected: Bool
    let children: [ChatActionMenuItem]?
    let action: (@MainActor () -> Void)?

    init(id: String, title: String, enabled: Bool = true, selected: Bool = false,
         children: [ChatActionMenuItem]? = nil, action: (@MainActor () -> Void)? = nil) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.selected = selected
        self.children = children
        self.action = action
    }
}

/// AppKit owns the visible menu while it tracks; SwiftUI updates only replace a
/// pending snapshot until native tracking has fully ended.
@MainActor
struct ChatActionMenu: NSViewRepresentable {
    let title: String
    let accessibilityIdentifier: String
    let items: [ChatActionMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = false
        button.autoenablesItems = false
        context.coordinator.install(on: button)
        context.coordinator.update(button, title: title,
                                   accessibilityIdentifier: accessibilityIdentifier, items: items)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.update(button, title: title,
                                   accessibilityIdentifier: accessibilityIdentifier, items: items)
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

        private struct DisplayedAction {
            let enabled: Bool
            let action: @MainActor () -> Void
        }

        private weak var button: NSPopUpButton?
        private var rootMenu: NSMenu?
        private var displayedActions: [ObjectIdentifier: DisplayedAction] = [:]
        private var pendingSnapshot: Snapshot?
        private var queuedActions: [@MainActor () -> Void] = []
        private var cycleStarted = false
        private var menuClosed = false
        private var trackingEnded = false
        private var selectionCaptured = false
        private var drainScheduled = false
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
                    accessibilityIdentifier: String, items: [ChatActionMenuItem]) {
            guard !dismantled, button === self.button else { return }
            let snapshot = Snapshot(title: title, accessibilityIdentifier: accessibilityIdentifier, items: items)
            if cycleStarted {
                pendingSnapshot = snapshot
            } else {
                apply(snapshot, to: button)
            }
        }

        private func apply(_ snapshot: Snapshot, to button: NSPopUpButton) {
            guard let menu = rootMenu else { return }
            displayedActions.removeAll()
            menu.removeAllItems()
            append(snapshot.items, to: menu, parentEnabled: true)
            button.title = snapshot.title
            button.setAccessibilityLabel(snapshot.title)
            button.setAccessibilityIdentifier(snapshot.accessibilityIdentifier)
            button.isEnabled = !snapshot.items.isEmpty
        }

        private func append(_ items: [ChatActionMenuItem], to menu: NSMenu, parentEnabled: Bool) {
            for value in items {
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
                    displayedActions[ObjectIdentifier(item)] = DisplayedAction(enabled: item.isEnabled, action: action)
                }
                menu.addItem(item)
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard !dismantled, menu === rootMenu else { return }
            cycleStarted = true
            menuClosed = false
            trackingEnded = false
            selectionCaptured = false
        }

        func menuDidClose(_ menu: NSMenu) {
            guard !dismantled, menu === rootMenu else { return }
            menuClosed = true
            scheduleDrainIfFinished()
        }

        @objc private func menuDidEndTracking(_ notification: Notification) {
            guard !dismantled, let menu = notification.object as? NSMenu,
                  menu === rootMenu else { return }
            trackingEnded = true
            scheduleDrainIfFinished()
        }

        @objc func selectItem(_ sender: NSMenuItem) {
            guard !dismantled, cycleStarted, !selectionCaptured,
                  sender.isEnabled, let displayed = displayedActions[ObjectIdentifier(sender)],
                  displayed.enabled else { return }
            selectionCaptured = true
            queuedActions.append(displayed.action)
            scheduleDrainIfFinished()
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
            guard !dismantled, cycleStarted, !isTracking else { return }
            drainScheduled = false
            if let pendingSnapshot, let button {
                self.pendingSnapshot = nil
                apply(pendingSnapshot, to: button)
            }
            let actions = queuedActions
            queuedActions.removeAll()
            cycleStarted = false
            actions.forEach { $0() }
        }

        func dismantle(_ button: NSPopUpButton) {
            guard !dismantled else { return }
            dismantled = true
            pendingSnapshot = nil
            queuedActions.removeAll()
            displayedActions.removeAll()
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

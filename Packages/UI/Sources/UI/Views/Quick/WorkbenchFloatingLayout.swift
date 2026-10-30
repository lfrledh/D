import SwiftUI

struct WorkbenchShellLayout: Equatable {
    let viewport: CGSize
    let navigationTop: CGFloat
    let modeWidth: CGFloat
    let widths: WorkbenchPanelWidths
    let leading: Bool
    let trailing: Bool
    init(viewport: CGSize, navigationTop: CGFloat, modeWidth: CGFloat = 232,
         requested: WorkbenchPanelWidths, leading: Bool, trailing: Bool) {
        self.viewport = viewport; self.navigationTop = navigationTop; self.modeWidth = modeWidth
        self.leading = leading; self.trailing = trailing
        let maximum = max(260, (viewport.width - 32 - 24 - 360) / 2)
        widths = .init(leading: min(requested.leading, maximum), trailing: min(requested.trailing, maximum))
    }
    var panelTop: CGFloat { navigationTop + 40 + 12 }
    var panelHeight: CGFloat { max(1, viewport.height - panelTop - 16) }
    func panel(leading: Bool) -> CGRect {
        let width = leading ? widths.leading : widths.trailing
        return .init(x: leading ? 16 : viewport.width - 16 - width, y: panelTop, width: width, height: panelHeight)
    }
    var center: CGRect {
        let left = 16 + (leading ? widths.leading : 48) + 12
        let right = viewport.width - 16 - (trailing ? widths.trailing : 48) - 12
        return .init(x: left, y: panelTop, width: max(1, right - left), height: panelHeight)
    }
    var navigationWidth: CGFloat { max(264, min(600, viewport.width - 2 * (16 + modeWidth + 12))) }
}
private struct WorkbenchNavigationTopKey: EnvironmentKey { static let defaultValue: CGFloat = 48 }
private struct WorkbenchNavigationModeWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 232 }
extension EnvironmentValues {
    var workbenchNavigationTop: CGFloat { get { self[WorkbenchNavigationTopKey.self] } set { self[WorkbenchNavigationTopKey.self] = newValue } }
    var workbenchNavigationModeWidth: CGFloat { get { self[WorkbenchNavigationModeWidthKey.self] } set { self[WorkbenchNavigationModeWidthKey.self] = newValue } }
}

/// Controls belong to the central operation area, never the full window corner.
enum WorkbenchFloatingLayout {
    static func runPanelHeight(available: CGFloat) -> CGFloat { min(420, max(120, available - 152)) }
    static func canvasTools(center: CGRect, runPanelHeight: CGFloat = 0) -> CGRect {
        let dockWidth = WorkflowDockLayout.width(available: center.width)
        let dock = CGRect(x: center.midX - dockWidth / 2,
            y: center.maxY - 48 - (runPanelHeight > 0 ? runPanelHeight + 8 : 0),
            width: dockWidth, height: 48 + (runPanelHeight > 0 ? runPanelHeight + 8 : 0))
        var result = CGRect(x: center.maxX - 88, y: center.maxY - 40, width: 88, height: 40)
        if result.intersects(dock.insetBy(dx: -12, dy: -12)) { result.origin.y = max(center.minY, dock.minY - 52) }
        return result
    }
}

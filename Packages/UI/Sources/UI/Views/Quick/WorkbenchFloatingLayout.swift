import SwiftUI

private struct WorkbenchModeSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 232, height: 52)
}
extension EnvironmentValues {
    var workbenchModeSize: CGSize {
        get { self[WorkbenchModeSizeKey.self] }
        set { self[WorkbenchModeSizeKey.self] = newValue }
    }
}
/// Floating controls only. This geometry never changes the graph or camera.
enum WorkbenchFloatingLayout {
    static func runPanelHeight(available: CGFloat) -> CGFloat { min(420, max(120, available - 152)) }
    static func canvasTools(viewport: CGSize, rightPanelWidth: CGFloat?, mode: CGSize, runPanelHeight: CGFloat = 0) -> CGRect {
        let modeRect = CGRect(x: viewport.width - 16 - mode.width, y: viewport.height - 16 - mode.height,
                              width: mode.width, height: mode.height)
        let right = rightPanelWidth.map { viewport.width - 16 - $0 - 12 } ?? (modeRect.minX - 12)
        var result = CGRect(x: max(16, right - 88), y: viewport.height - 56, width: 88, height: 40)
        let dockWidth = WorkflowDockLayout.width(available: viewport.width)
        let occupiedHeight = 48 + (runPanelHeight > 0 ? runPanelHeight + 8 : 0)
        let dock = CGRect(x: (viewport.width - dockWidth) / 2, y: viewport.height - 16 - occupiedHeight,
                          width: dockWidth, height: occupiedHeight)
        if result.intersects(dock.insetBy(dx: -12, dy: -12)) || result.intersects(modeRect.insetBy(dx: -12, dy: -12)) {
            result.origin.y = max(16, min(dock.minY, modeRect.minY) - 52)
        }
        return result
    }
    static func composerTrailingInset(visibleRightPanel: CGFloat, mode: CGSize) -> CGFloat {
        max(0, mode.width + 28 - visibleRightPanel)
    }
}

import AppKit
import SwiftUI

/// A drag owns a local candidate. Keyboard changes commit once per key action;
/// Escape and dismantling discard a drag without writing preferences.
struct WorkbenchValueSlider: NSViewRepresentable {
    let value: Double
    let label: String
    let preview: (Double?) -> Void
    let commit: (Double) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> WorkbenchValueSliderView {
        let slider = WorkbenchValueSliderView()
        slider.minValue = 0; slider.maxValue = 1; slider.target = slider; slider.action = #selector(WorkbenchValueSliderView.changed)
        return slider
    }
    func updateNSView(_ slider: WorkbenchValueSliderView, context: Context) {
        slider.preview = preview; slider.commit = commit; slider.isEnabled = enabled
        slider.setAccessibilityLabel(label)
        if !slider.tracking { slider.doubleValue = value }
    }
    static func dismantleNSView(_ slider: WorkbenchValueSliderView, coordinator: ()) { slider.cancelCandidate() }
}
final class WorkbenchValueSliderView: NSSlider {
    var preview: ((Double?) -> Void)?
    var commit: ((Double) -> Void)?
    private(set) var tracking = false
    private var original = 0.0
    private var cancelled = false
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        original = doubleValue; tracking = true; cancelled = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.tracking else { return event }
            self.cancelCandidate(); return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            tracking = false
            let candidate = doubleValue
            preview?(nil)
            if cancelled { doubleValue = original }
            else if candidate != original { commit?(candidate) }
        }
        super.mouseDown(with: event)
    }
    @objc func changed() {
        if tracking { if !cancelled { preview?(doubleValue) } }
        else { commit?(doubleValue) }
    }
    func cancelCandidate() { if tracking { cancelled = true; doubleValue = original }; preview?(nil) }
}

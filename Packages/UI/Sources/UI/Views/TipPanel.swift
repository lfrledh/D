import AppKit
import SwiftUI

private struct TipStoreKey: EnvironmentKey { static let defaultValue: TipStore? = nil }
public extension EnvironmentValues {
    var workbenchTips: TipStore? { get { self[TipStoreKey.self] } set { self[TipStoreKey.self] = newValue } }
}
public struct TipPresenter: ViewModifier {
    let owner: TipStore?
    @Environment(\.dLanguageStore) private var language
    public init(owner: TipStore?) { self.owner = owner }
    public func body(content: Content) -> some View {
        content.environment(\.workbenchTips, owner)
            .workbenchSheet(isPresented: Binding(get: { owner?.presented == true }, set: { owner?.presented = $0 }),
                title: workflowText(language, "tips.title"), size: .init(width: 460, height: 440)) {
                    if let owner { TipPanel(owner: owner) }
                }
    }
}
struct TipPanel: View {
    let owner: TipStore
    @Environment(\.dLanguageStore) private var language
    @State private var window: NSWindow?
    private func text(_ key: String) -> String { workflowText(language, "tips." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text("body")).fixedSize(horizontal: false, vertical: true)
            if owner.localTest { Text(text("localTest")).font(.caption).foregroundStyle(.secondary) }
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !owner.products.isEmpty { Text(text("choose")).font(.headline) }
                    ForEach(owner.products, id: \.id) { product in
                        Button { owner.selectedID = product.id } label: {
                            HStack {
                                Image(systemName: owner.selectedID == product.id ? "checkmark.circle.fill" : "circle")
                                Text(product.displayName); Spacer(); Text(product.displayPrice)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(WorkbenchRowButtonStyle(cornerRadius: 10))
                            .accessibilityIdentifier("tip-product-" + product.id)
                            .accessibilityAddTraits(owner.selectedID == product.id ? .isSelected : [])
                    }
                }
            }
            if owner.status != .idle { Text(text(owner.status.rawValue)).font(.callout).accessibilityIdentifier("tip-status") }
            if let diagnostic = owner.diagnostic {
                DisclosureGroup(text("details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button(text("reload")) { Task { await owner.loadProducts() } }
                    .disabled(owner.status == .loading || owner.status == .purchasing)
                    .accessibilityIdentifier("tip-reload")
                Spacer()
                if let product = owner.selectedProduct {
                    Button(text("purchase").replacingOccurrences(of: "{price}", with: product.displayPrice)) {
                        guard let window else { return }
                        Task { await owner.purchase(confirmIn: window) }
                    }.disabled(!owner.canPurchase || window == nil).accessibilityIdentifier("tip-purchase")
                }
            }.buttonStyle(WorkbenchGlassButtonStyle())
            WorkbenchRequestCloseButton(title: text("close"), fallback: { owner.presented = false })
        }.padding(20).background(TipWindowReader { window = $0 }).task { await owner.loadProducts() }
    }
}
private struct TipWindowReader: NSViewRepresentable {
    let update: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.update = update; return view }
    func updateNSView(_ view: Marker, context: Context) { view.update = update }
    final class Marker: NSView {
        var update: ((NSWindow?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.update?(self?.window) } }
    }
}

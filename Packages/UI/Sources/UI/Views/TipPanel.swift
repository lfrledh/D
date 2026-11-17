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
                title: workflowText(language, "tips.title"), size: .init(width: 460, height: 520)) {
                    if let owner { TipPanel(owner: owner) }
                }
    }
}
struct TipPanel: View {
    let owner: TipStore
    @Environment(\.dLanguageStore) private var language
    @State private var window: NSWindow?
    @State private var additionalConfirmation: TipStore.AdditionalConfirmation?
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
            if ![.idle, .available].contains(owner.catalogStatus) {
                Text(text(owner.catalogStatus.rawValue)).font(.callout).accessibilityIdentifier("tip-catalog-status")
            }
            if owner.capacityLimitReached { Text(text("records.capacity")).font(.callout) }
            if owner.status != .idle && !(owner.canCreateRequest && [.pending, .uncertain].contains(owner.status)) {
                Text(text(owner.status.rawValue)).font(.callout).accessibilityIdentifier("tip-status")
            }
            if owner.hasConfirmedLatestPurchase && owner.status != .thanked { Text(text("thanked")).font(.callout) }
            if owner.needsAdditionalConfirmation {
                Text(text("additional.unconfirmed")).font(.callout).accessibilityIdentifier("tip-unconfirmed")
            }
            if owner.recoveryStatus == .loading {
                Text(text("records.loading")).font(.caption).accessibilityIdentifier("tip-record-sync")
            } else if owner.recoveryStatus == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text("records.failed"))
                    if let failure = owner.recoveryFailure { Text(text("records." + failure.rawValue)) }
                }.font(.caption).accessibilityIdentifier("tip-record-sync")
            }
            if let diagnostic = owner.diagnostic {
                DisclosureGroup(text("details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
            if let diagnostic = owner.catalogDiagnostic {
                DisclosureGroup(text("details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
            if let diagnostic = owner.recoveryDiagnostic {
                DisclosureGroup(text("details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button(text("reload")) { Task { await owner.loadProducts() } }
                    .disabled(owner.catalogStatus == .loading || owner.status == .purchasing)
                    .accessibilityIdentifier("tip-reload")
                if owner.needsRetrySave {
                    Button(workflowText(language, "chat.retrySave")) { owner.retrySave() }
                        .disabled(!owner.canRetrySave).accessibilityIdentifier("tip-retry-save")
                }
                Spacer()
                if let product = owner.selectedProduct {
                    Button(owner.needsAdditionalConfirmation ? text("additional.entry") : text("purchase").replacingOccurrences(of: "{price}", with: product.displayPrice)) {
                        guard let window else { return }
                        if owner.needsAdditionalConfirmation { additionalConfirmation = owner.additionalPurchaseConfirmation() }
                        else { Task { await owner.purchase(confirmIn: window) } }
                    }.disabled(!owner.canPurchase || window == nil).accessibilityIdentifier("tip-purchase")
                }
            }.buttonStyle(WorkbenchGlassButtonStyle())
            WorkbenchRequestCloseButton(title: text("close"), fallback: { owner.presented = false })
        }.padding(20).background(TipWindowReader { window = $0 }).task { await owner.loadProducts() }
            .workbenchSheet(isPresented: Binding(get: { additionalConfirmation != nil }, set: { shown in
                if !shown, let value = additionalConfirmation { owner.cancelAdditionalConfirmation(value); additionalConfirmation = nil }
            }), title: text("additional.title"), size: .init(width: 440, height: 240)) {
                if let value = additionalConfirmation {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(text("additional.body").replacingOccurrences(of: "{price}", with: value.displayPrice))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(text("additional.cancel")) {
                                owner.cancelAdditionalConfirmation(value); additionalConfirmation = nil
                            }.accessibilityIdentifier("tip-additional-cancel")
                            Spacer()
                            Button(text("additional.confirm").replacingOccurrences(of: "{price}", with: value.displayPrice)) {
                                guard let window else { return }
                                additionalConfirmation = nil
                                Task { await owner.purchase(confirmIn: window, confirmation: value) }
                            }.disabled(!owner.canConfirmAdditionalPurchase(value) || window == nil).accessibilityIdentifier("tip-additional-confirm")
                        }.buttonStyle(WorkbenchGlassButtonStyle())
                    }.padding(20)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await owner.recoverHistory(recheckAccount: true) }
            }
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

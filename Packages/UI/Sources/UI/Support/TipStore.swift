import AppKit
import Foundation
import Observation
import StoreKit

/// Application-owned StoreKit listener. No project, model or feature entitlement depends on tips.
@MainActor @Observable public final class TipStore {
    public enum Status: String { case idle, loading, unavailable, purchasing, pending, cancelled, thanked, failed, uncertain }
    public private(set) var products: [Product] = []
    public private(set) var status: Status = .idle
    public private(set) var diagnostic: String?
    public var selectedID: String?
    public var presented = false
    public private(set) var localTest = false
    private let expectsLocalTest: Bool
    private var eventRevision: UInt64 = 0
    private let allowedIDs: Set<String>
    private let bundleID: String
    private let journalURL: URL
    private var journal: [String: TipReceipt] = [:]
    private var journalIssue: String?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var purchasing = false
    // Only in-flight verified handlers own entries; defer removes them after finish.
    @ObservationIgnored private var pendingAcknowledgments: Set<String> = []
    /// Formal product identifiers remain undecided. The ordinary app supplies an empty allowlist.
    public init(productIDs: Set<String>, bundleID: String, journalURL: URL, localTest: Bool = false) {
        allowedIDs = productIDs; self.bundleID = bundleID; self.journalURL = journalURL; self.expectsLocalTest = localTest
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let data = try Data(contentsOf: journalURL)
                guard data.count <= 2_097_152 else { throw TipIssue.journalTooLarge }
                journal = try JSONDecoder().decode([String: TipReceipt].self, from: data)
                guard journal.allSatisfy({ $0.key == $0.value.transactionID && $0.value.bundleID == bundleID }) else { throw TipIssue.invalidJournal }
            }
        } catch { journalIssue = String(describing: error); diagnostic = journalIssue; status = .uncertain }
    }
    deinit { listener?.cancel(); recovery?.cancel() }
    public func start() {
        guard listener == nil, !allowedIDs.isEmpty else { return }
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }; await self?.receive(result)
            }
        }
        recovery = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }; await self?.receive(result)
            }
        }
    }
    public func loadProducts() async {
        guard !loading, !purchasing else { return }
        guard journalIssue == nil else { status = .uncertain; return }
        guard !allowedIDs.isEmpty else { products = []; status = .unavailable; return }
        loading = true; defer { loading = false }
        let revision = eventRevision, previous = status
        if ![.pending, .uncertain, .thanked].contains(status) { status = .loading; diagnostic = nil }
        do {
            if expectsLocalTest {
                // A launch flag is intent, not proof. Do not offer a test purchase
                // or claim no charge until StoreKit confirms this exact app's environment.
                guard case .verified(let app) = try await AppTransaction.shared,
                      app.environment == .xcode, app.bundleID == bundleID else { throw TipIssue.invalidTransaction }
                localTest = true
            }
            for await result in Transaction.unfinished { await receive(result) }
            let loaded = try await Product.products(for: allowedIDs)
            products = loaded.filter { allowedIDs.contains($0.id) && $0.type == .consumable }.sorted { $0.price < $1.price }
            if let selectedID, !products.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            if eventRevision == revision {
                status = products.isEmpty ? .unavailable : [.pending, .uncertain, .thanked].contains(previous) ? previous : .idle
            }
        } catch {
            products = []
            if eventRevision == revision { diagnostic = String(describing: error); status = .unavailable }
        }
    }
    public var selectedProduct: Product? { products.first { $0.id == selectedID } }
    public var canPurchase: Bool { selectedProduct != nil && !purchasing && !loading && journalIssue == nil && status != .uncertain && (!expectsLocalTest || localTest) }
    public func purchase(confirmIn window: NSWindow) async {
        guard canPurchase, let product = selectedProduct else { return }
        purchasing = true; status = .purchasing; diagnostic = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase(confirmIn: window) {
            case .success(let result): await receive(result)
            case .userCancelled: status = .cancelled
            case .pending: status = .pending
            @unknown default: status = .uncertain
            }
        } catch StoreKitError.userCancelled { status = .cancelled }
        catch { diagnostic = String(describing: error); status = .failed }
    }
    private func receive(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified(_, let error): markUnverified(String(describing: error))
        case .verified(let transaction):
            let fact = TipReceipt(transactionID: String(transaction.id), productID: transaction.productID,
                bundleID: transaction.appBundleID, environment: transaction.environment.rawValue,
                revoked: transaction.revocationDate != nil)
            do {
                guard transaction.productType == .consumable else { throw TipIssue.invalidTransaction }
                await acceptVerified(fact) { await transaction.finish() }
            } catch { markUnverified(String(describing: error)) }
        }
    }
    func acceptVerified(_ fact: TipReceipt, finish: () async -> Void) async {
        do {
            let fresh = try recordVerified(fact), revision = eventRevision
            if fresh { pendingAcknowledgments.insert(fact.transactionID) }
            defer { if fresh { pendingAcknowledgments.remove(fact.transactionID) } }
            // No acknowledgment before persistence; callbacks can reenter while finishing.
            await finish()
            guard eventRevision == revision, journal[fact.transactionID]?.revoked == fact.revoked else { return }
            if fresh && !fact.revoked {
                eventRevision &+= 1; diagnostic = nil; status = .thanked
            } else if fact.revoked || (status == .uncertain && !pendingAcknowledgments.contains(fact.transactionID)) {
                eventRevision &+= 1; diagnostic = nil; status = .idle
            }
        } catch { markUnverified(String(describing: error)) }
    }
    func markUnverified(_ reason: String) { eventRevision &+= 1; diagnostic = reason; status = .uncertain }
    /// Called only after StoreKit verification; fact injection is restricted to @testable tests.
    func recordVerified(_ fact: TipReceipt) throws -> Bool {
        guard journalIssue == nil else { throw TipIssue.invalidJournal }
        guard allowedIDs.contains(fact.productID), fact.bundleID == bundleID,
              !fact.transactionID.isEmpty,
              expectsLocalTest ? fact.environment == AppStore.Environment.xcode.rawValue : fact.environment != AppStore.Environment.xcode.rawValue
        else { throw TipIssue.invalidTransaction }
        if let old = journal[fact.transactionID] {
            guard old.productID == fact.productID, old.bundleID == fact.bundleID, old.environment == fact.environment else { throw TipIssue.invalidTransaction }
            if old.revoked || !fact.revoked { return false }
        }
        var next = journal; let fresh = next[fact.transactionID] == nil; next[fact.transactionID] = fact
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2_097_152 else { throw TipIssue.journalTooLarge }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: journalURL, options: .atomic)
        journal = next
        return fresh
    }
}
struct TipReceipt: Codable, Equatable {
    let transactionID: String
    let productID: String
    let bundleID: String
    let environment: String
    let revoked: Bool
}
private enum TipIssue: Error { case invalidTransaction, invalidJournal, journalTooLarge }

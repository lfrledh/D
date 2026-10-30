import Foundation
import StoreKit
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct TipStoreTests {
    private func owner(_ url: URL, ids: Set<String> = ["d.localtest.tip.small"]) -> TipStore {
        TipStore(productIDs: ids, bundleID: "D.fixture", journalURL: url, localTest: true)
    }
    private func fact(_ id: String, revoked: Bool = false) -> TipReceipt {
        .init(transactionID:id,productID:"d.localtest.tip.small",bundleID:"D.fixture",environment:AppStore.Environment.xcode.rawValue,revoked:revoked)
    }
    @Test func verifiedJournalIsIdempotentDurableAndRefundNeverChangesFeatures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("journal.json"), first = owner(root.appendingPathComponent("journal.json"))
        #expect(try first.recordVerified(fact("one")))
        #expect(try !first.recordVerified(fact("one")))
        let cold = owner(url)
        #expect(try !cold.recordVerified(fact("one")))
        #expect(try cold.recordVerified(fact("two")))
        #expect(try !cold.recordVerified(fact("one",revoked:true)))
        #expect(try !cold.recordVerified(fact("one")))
        #expect(throws:(any Error).self) { try cold.recordVerified(.init(transactionID:"bad",productID:"unapproved",bundleID:"D.fixture",environment:AppStore.Environment.xcode.rawValue,revoked:false)) }
        #expect(throws:(any Error).self) { try cold.recordVerified(.init(transactionID:"bad",productID:"d.localtest.tip.small",bundleID:"Other",environment:AppStore.Environment.xcode.rawValue,revoked:false)) }
    }
    @Test func failedJournalWriteNeverAcknowledgesAndCanRetrySameTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-block-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("keep".utf8).write(to:root)
        let value = owner(root.appendingPathComponent("journal.json"))
        #expect(throws:(any Error).self) { try value.recordVerified(fact("one")) }
        #expect(try Data(contentsOf:root) == Data("keep".utf8))
        try FileManager.default.removeItem(at:root)
        #expect(try value.recordVerified(fact("one")))
    }
    @Test func ordinaryConfigurationHasNoInventedProductOrPurchase() async {
        let value = owner(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),ids:[])
        await value.loadProducts()
        #expect(value.products.isEmpty && value.status == .unavailable && !value.canPurchase)
    }
    @Test(arguments: [false, true]) func duplicateDeliveryCannotEraseTheFirstSuccessfulAcknowledgment(uncertain: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-duplicate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        if uncertain { value.markUnverified("controlled earlier verification issue") }
        var suspended: CheckedContinuation<Void, Never>?
        let original = Task { await value.acceptVerified(fact("one")) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        await value.acceptVerified(fact("one")) { }
        suspended?.resume(); await original.value
        #expect(value.status == .thanked)
        let saved = try JSONDecoder().decode([String: TipReceipt].self, from: Data(contentsOf: root.appendingPathComponent("journal.json")))
        #expect(saved.count == 1)
    }
    @Test func failedWriteDoesNotFinishAndRefundWinsSuspendedFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-finish-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("keep".utf8).write(to:root)
        let value = owner(root.appendingPathComponent("journal.json"))
        var finishes = 0
        await value.acceptVerified(fact("one")) { finishes += 1 }
        #expect(finishes == 0 && value.status == .uncertain)
        try FileManager.default.removeItem(at:root)
        var suspended: CheckedContinuation<Void, Never>?
        let original = Task { await value.acceptVerified(fact("one")) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        await value.acceptVerified(fact("one",revoked:true)) { finishes += 1 }
        suspended?.resume(); await original.value
        #expect(finishes == 1 && value.status == .idle)
        value.markUnverified("controlled signature failure")
        #expect(value.status == .uncertain && value.diagnostic == "controlled signature failure" && !value.canPurchase)
    }

}

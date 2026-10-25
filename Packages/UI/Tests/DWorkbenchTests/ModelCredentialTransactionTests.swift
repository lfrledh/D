import Foundation
import Synchronization
import Testing
@testable import DWorkbench

@Suite(.serialized) struct ModelCredentialTransactionTests {
    private final class Vault: Sendable {
        struct State { var items: [String:String] = [:]; var denyRemoval: String?; var denyAllRemoval = false; var failPoint: String?; var denyCleanupOnFault = false }
        let state = Mutex(State())
        var services: ModelCredentialServices { .init(validate: { _ in }, insert: { [self] token, account in
            try state.withLock { state in
                guard state.items[account] == nil else { throw ModelLibraryError.storage("duplicate credential slot") }
                state.items[account] = token
            }
        }, read: { [self] account in try state.withLock { state in
            guard let token = state.items[account] else { throw ModelLibraryError.accessDenied("missing controlled token") }; return token
        } }, remove: { [self] account in try state.withLock { state in
            if state.denyRemoval == account || state.denyAllRemoval { throw ModelLibraryError.accessDenied("controlled cleanup failure") }
            state.items[account] = nil
        } }) }
        func checkpoint(_ point: String) throws {
            if state.withLock({ state in
                guard state.failPoint == point else { return false }
                if state.denyCleanupOnFault { state.denyAllRemoval = true }
                return true
            }) { throw ModelLibraryError.storage("controlled " + point) }
        }
    }
    private func index(_ root: URL) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [String:Any])
    }
    private func make(_ root: URL, _ vault: Vault) async throws -> ModelLibrary {
        try await ModelLibrary(stateDirectory: root, catalog: [ModelCatalog.flux2()], credentialServices: vault.services, checkpoint: vault.checkpoint)
    }
    @Test(arguments: [false, true]) func failedPublishPreservesOldTokenAndColdRetryCleansOnlyKnownSlots(cleanupFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(); var owner: ModelLibrary? = try await make(root, vault)
        do {
            let library = try #require(owner)
            try await library.connectDownloadToken("hf_controlled_old", saveToKeychain: true)
            let old = try #require(index(root)["downloadCredentialAccount"] as? String)
            let revision = try index(root)["revision"] as? Int
            vault.state.withLock { $0.failPoint = "state.beforeWrite"; $0.denyCleanupOnFault = cleanupFails }
            do { try await library.connectDownloadToken("hf_controlled_new", saveToKeychain: true); Issue.record("Expected controlled save failure") }
            catch {
                #expect(error.localizedDescription.contains("controlled state.beforeWrite"))
                if cleanupFails { #expect(error.localizedDescription.contains("controlled cleanup failure")) }
            }
            #expect(try index(root)["downloadCredentialAccount"] as? String == old)
            #expect(try index(root)["revision"] as? Int == revision)
            #expect(vault.state.withLock { $0.items[old] } == "hf_controlled_old")
            #expect(vault.state.withLock { $0.items.count } == (cleanupFails ? 2 : 1))
            #expect(!(try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8)).contains("hf_controlled_"))
            vault.state.withLock { $0.failPoint = nil; $0.denyAllRemoval = false; $0.denyCleanupOnFault = false }
        }
        owner = nil
        let cold = try await make(root, vault)
        #expect(await cold.snapshot().downloadCredentialConnected)
        try await cold.disconnectDownloadCredential()
        #expect(vault.state.withLock { $0.items.isEmpty })
        try await cold.shutdown()
    }
    @Test func publishedUnsyncedRetainsNewTokenAcrossColdRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(); var owner: ModelLibrary? = try await make(root, vault)
        var published = ""
        do {
            let library = try #require(owner)
            try await library.connectDownloadToken("hf_controlled_old", saveToKeychain: true)
            vault.state.withLock { $0.failPoint = "state.afterRename" }
            await #expect(throws: ModelAtomicWriteError.self) { try await library.connectDownloadToken("hf_controlled_new", saveToKeychain: true) }
            published = try #require(index(root)["downloadCredentialAccount"] as? String)
            #expect(try vault.services.read(published) == "hf_controlled_new")
            #expect(await library.snapshot().downloadCredentialConnected)
            vault.state.withLock { $0.failPoint = nil }
        }
        owner = nil
        let cold = try await make(root, vault)
        #expect(try index(root)["downloadCredentialAccount"] as? String == published)
        try await cold.disconnectDownloadCredential()
        #expect(vault.state.withLock { $0.items.isEmpty })
        try await cold.shutdown()
    }
    @Test func disconnectCleanupFailureDoesNotReconnectAndRetryRemainsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(); let library = try await make(root, vault)
        try await library.connectDownloadToken("hf_controlled_old", saveToKeychain: true)
        let account = try #require(index(root)["downloadCredentialAccount"] as? String)
        vault.state.withLock { $0.denyRemoval = account }
        await #expect(throws: ModelLibraryError.self) { try await library.disconnectDownloadCredential() }
        #expect(!(await library.snapshot()).downloadCredentialConnected)
        #expect(try index(root)["downloadCredentialAccount"] == nil)
        #expect(vault.state.withLock { $0.items.count } == 1)
        vault.state.withLock { $0.denyRemoval = nil; $0.denyAllRemoval = true }
        await #expect(throws: ModelLibraryError.self) { try await library.connectDownloadToken("hf_other", saveToKeychain: true) }
        #expect(vault.state.withLock { $0.items.count } == 1)
        vault.state.withLock { $0.denyAllRemoval = false }
        try await library.disconnectDownloadCredential()
        #expect(vault.state.withLock { $0.items.isEmpty })
        try await library.shutdown()
    }
}

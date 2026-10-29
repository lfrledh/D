import DWorkbench
import Foundation
import Darwin

/// Presentation for the existing project-file commands, never a persisted identity.
enum ProjectFileOperation { case general, verify, relink, collect, move, backup, restore }
@MainActor
struct ProjectFilesMessage {
    let key: String
    var arguments: [String: String] = [:]
    var diagnostic: String? = nil
    static func key(_ key: String) -> Self { .init(key: key) }
    func text(_ language: UILanguageStore?) -> String { workflowText(language, key, arguments: arguments) }

    static func failure(_ error: Error, operation: ProjectFileOperation = .general) -> Self {
        let diagnostic = String(reflecting: error) + "\n" + error.localizedDescription
        if let error = error as? AssetFileOperationFailure {
            let key: String
            switch error.stage {
            case .writtenVerification: key = "files.error.writtenVerification"
            case .writtenCommit: key = "files.error.copyCommit"
            case .writtenSync: key = "files.error.writtenSync"
            case .notPublished: key = error.issue == .contentMismatch && operation == .relink ? "files.error.relinkMismatch" : "files.issue." + error.issue.rawValue
            }
            return .init(key: key, diagnostic: diagnostic + (error.destination.map { "\n" + $0.path } ?? ""))
        }
        if let error = error as? ProjectBackupError {
            let key: String
            switch error {
            case .incompleteRequiresConfirmation: key = operation == .restore ? "files.restoreIncomplete" : "files.incomplete"
            case .unsafePath: key = "files.issue.unsafeFile"
            case .alreadyExists: key = "files.exists"
            case .invalidPackage: key = operation == .backup ? "files.error.invalidBackupInput" : "files.error.invalidBackup"
            case .integrity: key = "files.error.backupIntegrity"
            case .publishedIntegrity: key = "files.error.writtenVerification"
            case .insufficientSpace: key = operation == .restore ? "files.error.restoreSpace" : "files.error.backupSpace"
            case .posix(let failure):
                if failure.existingBackup { key = "files.error.existingBackup" }
                else if failure.published { key = "files.error.writtenSync" }
                else if failure.code == ENOSPC { key = operation == .restore ? "files.error.restoreSpace" : "files.error.backupSpace" }
                else if failure.code == EPERM || failure.code == EACCES { key = "files.issue.authorization" }
                else { key = operation == .restore ? "files.error.restore" : "files.error.backup" }
            case .foundation(let failure):
                if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError) ||
                    (failure.underlyingDomain == NSPOSIXErrorDomain && failure.underlyingCode == Int(ENOSPC)) {
                    key = operation == .restore ? "files.error.restoreSpace" : "files.error.backupSpace"
                } else { key = operation == .restore ? "files.error.restore" : "files.error.backup" }
            case .io: key = operation == .restore ? "files.error.restore" : "files.error.backup"
            }
            return .init(key: key, diagnostic: diagnostic)
        }
        if let error = error as? ProjectFilesViewError {
            return .init(key: error.key, diagnostic: diagnostic)
        }
        if let error = error as? ProjectStoreError {
            switch error {
            case .externalModification: return .init(key: "files.error.projectChanged", diagnostic: diagnostic)
            case .alreadyExists: return .init(key: "files.exists", diagnostic: diagnostic)
            default: break
            }
        }
        let issue = AssetFileOperationFailure.classify(error)
        return .init(key: "files.issue." + issue.rawValue, diagnostic: diagnostic)
    }

    static func result(_ value: AssetRelocationResult) -> Self {
        switch value.outcome {
        case .relocated: return .key("files.result.relinked")
        case .collected: return .key("files.collected")
        case .noMatch: return .key("files.result.noMatch")
        case .ambiguous: return .key("files.result.ambiguous")
        case .cancelled: return .key("files.result.cancelled")
        case .notProcessed: return .key("files.result.notProcessed")
        case .failed:
            if let failure = value.failure { return .failure(failure) }
            return .init(key: "files.issue.checkFailed", diagnostic: value.message)
        }
    }

    static func useTitle(_ value: AssetKnownUse, language: UILanguageStore?) -> String {
        value.displayName ?? value.title
    }
    static func useSummary(_ value: AssetKnownUse, language: UILanguageStore?) -> String {
        let key = switch value.kind {
        case .graph: value.toolVersion == nil ? "files.use.graph" : "files.use.tool"
        case .run: "files.use.run"
        case .derivedAsset: "files.use.derived"
        }
        var parts = [workflowText(language, key)]
        if let date = value.createdAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        parts += value.path.map { part in
            switch part {
            case .graph(let name, _), .node(let name, _): return name
            case .branchTrue: return workflowText(language, "files.use.branchTrue")
            case .branchFalse: return workflowText(language, "files.use.branchFalse")
            case .mapBody: return workflowText(language, "files.use.mapBody")
            case .loopBody: return workflowText(language, "files.use.loopBody")
            }
        }
        if value.additionalNodeCount > 0 {
            parts.append(workflowText(language, "files.use.additional", arguments: ["count": String(value.additionalNodeCount)]))
        }
        return parts.joined(separator: " / ")
    }
}

enum ProjectFilesViewError: Error {
    case staleProject, authorization, reveal
    var key: String {
        switch self {
        case .staleProject: "files.error.staleProject"
        case .authorization: "files.issue.authorization"
        case .reveal: "files.error.reveal"
        }
    }
}

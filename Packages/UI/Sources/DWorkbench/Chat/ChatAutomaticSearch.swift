import Foundation

/// Facts for this exact send. Search snippets remain transient and never become citations.
public struct ChatAutomaticSearch: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case included, failed, noResults }
    public let outcome: Outcome
    public let activityIDs: [UUID]
    public let issue: String?
    public let issueCode: String?
    public var generationStarted: Bool? = nil

    public var noticeKey: String? {
        switch outcome {
        case .included: nil
        case .failed: generationStarted == true ? "chat.automaticSearch.failed" : "chat.automaticSearch.failedBeforeGeneration"
        case .noResults: generationStarted == true ? "chat.automaticSearch.noResults" : "chat.automaticSearch.emptyBeforeGeneration"
        }
    }

    /// Request metadata, not UI copy or a replacement for the user's system instructions.
    var requestNotice: String? {
        guard outcome != .included else { return nil }
        return "[D request source status: automatic web search supplied no usable material for this request. Do not claim this request was verified by web search. Other explicitly supplied references are unchanged.]"
    }

    func validate() throws {
        guard activityIDs.count <= 2, Set(activityIDs).count == activityIDs.count,
              (issue?.utf8.count ?? 0) <= 16_384, (issueCode?.utf8.count ?? 0) <= 256 else {
            throw WorkflowIssue("Invalid automatic search receipt.")
        }
    }

    static func permitsFallback(_ error: Error) -> Bool {
        if let error = error as? ChatSearchError { return error != .permissionDenied }
        if let error = error as? ChatWebPageError { return error != .permissionDenied }
        if let error = error as? URLError { return error.code != .cancelled }
        return false // Cancellation, ownership, persistence and validation are not search failures.
    }
}

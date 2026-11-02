import Foundation

/// Stable presentation codes for owned tool failures; raw diagnostics remain separate.
public enum ChatToolIssue {
    public static func code(_ error: Error) -> String? {
        if let value = error as? ChatSearchError {
            switch value {
            case .permissionDenied: return "chat.toolIssue.search.permissionDenied"
            case .unsupportedProvider: return "chat.toolIssue.search.unsupportedProvider"
            case .invalidQuery: return "chat.toolIssue.search.invalidQuery"
            case .invalidCredential: return "chat.toolIssue.search.invalidCredential"
            case .invalidResponse: return "chat.toolIssue.search.invalidResponse"
            case .responseTooLarge: return "chat.toolIssue.search.responseTooLarge"
            case .redirectRejected: return "chat.toolIssue.search.redirectRejected"
            case .unauthorized: return "chat.toolIssue.search.unauthorized"
            case .forbidden: return "chat.toolIssue.search.forbidden"
            case .rateLimited: return "chat.toolIssue.search.rateLimited"
            case .apiCode: return "chat.toolIssue.search.apiCode"
            case .serviceUnavailable: return "chat.toolIssue.search.serviceUnavailable"
            case .httpStatus: return "chat.toolIssue.search.httpStatus"
            case .transportFailure: return "chat.toolIssue.search.transportFailure"
            }
        }
        if let value = error as? ChatWebPageError {
            switch value {
            case .permissionDenied: return "chat.toolIssue.page.permissionDenied"
            case .invalidURL: return "chat.toolIssue.page.invalidURL"
            case .addressUnavailable: return "chat.toolIssue.page.addressUnavailable"
            case .transportFailure: return "chat.toolIssue.page.transportFailure"
            case .timedOut: return "chat.toolIssue.page.timedOut"
            case .redirectRejected: return "chat.toolIssue.page.redirectRejected"
            case .httpStatus: return "chat.toolIssue.page.httpStatus"
            case .unsupportedContentType: return "chat.toolIssue.page.unsupportedContentType"
            case .invalidResponse: return "chat.toolIssue.page.invalidResponse"
            case .responseTooLarge: return "chat.toolIssue.page.responseTooLarge"
            case .sourceTooLarge: return "chat.toolIssue.page.sourceTooLarge"
            case .unsafeHTML: return "chat.toolIssue.page.unsafeHTML"
            case .emptyContent: return "chat.toolIssue.page.emptyContent"
            }
        }
        if let value = error as? ChatMCPError {
            switch value {
            case .permissionDenied: return "chat.toolIssue.mcp.permissionDenied"
            case .invalidEndpoint: return "chat.toolIssue.mcp.invalidEndpoint"
            case .invalidArguments: return "chat.toolIssue.mcp.invalidArguments"
            case .notConnected: return "chat.toolIssue.mcp.notConnected"
            case .busy: return "chat.toolIssue.mcp.busy"
            case .unknownTool: return "chat.toolIssue.mcp.unknownTool"
            case .catalogLimit: return "chat.toolIssue.mcp.catalogLimit"
            case .resultLimit: return "chat.toolIssue.mcp.resultLimit"
            case .timedOut: return "chat.toolIssue.mcp.timedOut"
            case .cancelled: return "chat.toolIssue.mcp.cancelled"
            case .connectionFailed: return "chat.toolIssue.mcp.connectionFailed"
            case .requestFailed: return "chat.toolIssue.mcp.requestFailed"
            }
        }
        if let value = error as? ChatPythonError {
            switch value {
            case .invalidCode: return "chat.toolIssue.python.invalidCode"
            case .invalidInput: return "chat.toolIssue.python.invalidInput"
            case .inputTooLarge: return "chat.toolIssue.python.inputTooLarge"
            case .invalidOutput: return "chat.toolIssue.python.invalidOutput"
            case .outputTooLarge: return "chat.toolIssue.python.outputTooLarge"
            case .unavailable: return "chat.toolIssue.python.unavailable"
            case .setupFailed: return "chat.toolIssue.python.setupFailed"
            case .guestFailed: return "chat.toolIssue.python.guestFailed"
            case .resourceLimit: return "chat.toolIssue.python.resourceLimit"
            case .timedOut: return "chat.toolIssue.python.timedOut"
            case .cancelled: return "chat.toolIssue.python.cancelled"
            case .cleanupFailed: return "chat.toolIssue.python.cleanupFailed"
            case .executionFailed(let reason, _): return code(reason)
            }
        }
        if error is CancellationError { return "chat.toolIssue.mcp.cancelled" }
        return (error as? WorkflowIssue)?.code
    }
}

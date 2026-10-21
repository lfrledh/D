import SwiftUI
import DWorkbench

@MainActor func consistencyText(_ language: UILanguageStore?, _ key: String, arguments: [String: String] = [:]) -> String {
    let store = language ?? ConsistencyLanguageDefaults.english
    let fullKey = "consistency." + key
    return store.text(fullKey, fallback: store.sourceFallback(fullKey, fallback: key), arguments: arguments)
}

@MainActor func workbenchIntegerEditingError(_ raw: String, field: String, language: UILanguageStore?) -> String? {
    if raw.isEmpty { return consistencyText(language, "validation.integerRequired", arguments: ["field": field]) }
    if Int(raw) == nil { return consistencyText(language, "validation.integerInvalid", arguments: ["field": field]) }
    return nil
}

@MainActor private enum ConsistencyLanguageDefaults { static let english = UILanguageStore(preferredLanguages: ["en"]) }

/// Known metadata failures use semantic keys; foreign and historical diagnostics
/// remain verbatim. Neither the localized sentence nor the raw diagnostic is an ID.
@MainActor func sharedLibraryErrorText(_ error: any Error, language: UILanguageStore?) -> String {
    guard let error = error as? SharedLibraryError else { return error.localizedDescription }
    let code: String
    var arguments: [String: String] = [:]
    switch error {
    case .invalidName: code = "invalidName"
    case .duplicateName(let name): code = "duplicateName"; arguments["name"] = name
    case .missingTag: code = "missingTag"
    case .missingFolder: code = "missingFolder"
    case .missingQuery: code = "missingQuery"
    case .invalidKey: code = "invalidKey"
    case .invalidReference: code = "invalidReference"
    case .folderCycle: code = "folderCycle"
    case .folderDepth: code = "folderDepth"
    case .invalidMembership: code = "invalidMembership"
    case .tagInSavedQuery: code = "tagInSavedQuery"
    case .limitExceeded(let detail): code = "limitExceeded"; arguments["detail"] = detail
    case .unsupportedSchema(let version): code = "unsupportedSchema"; arguments["version"] = String(version)
    case .corruptedMetadata(let detail): code = "corruptedMetadata"; arguments["detail"] = detail
    case .invalidFileURL: code = "invalidFileURL"
    case .externalChange: code = "externalChange"
    case .staleTagEdit: code = "staleTagEdit"
    case .staleAnnotation: code = "staleAnnotation"
    case .invalidProperty: code = "invalidProperty"
    }
    return workflowText(language, "metadata.error." + code, arguments: arguments)
}

@MainActor func chatConnectionText(_ status: ChatMCPStatus, language: UILanguageStore?) -> String {
    switch status {
    case .disconnected: workflowText(language, "chat.connection.disconnected")
    case .connecting: workflowText(language, "chat.connection.connecting")
    case .connected(let endpoint): workflowText(language, "chat.connection.connected", arguments: ["endpoint": endpoint])
    case .stopping: workflowText(language, "chat.connection.stopping")
    case .localStoppedServerUnknown: workflowText(language, "chat.connection.localStoppedServerUnknown")
    }
}
@MainActor func chatRecognitionText(_ status: ChatSpeechRecognitionState, language: UILanguageStore?) -> String {
    switch status {
    case .idle: return workflowText(language, "chat.recognition.idle")
    case .recognizing: return workflowText(language, "chat.recognition.recognizing")
    case .stopping(let reason), .stalledDrain(let reason):
        let key: String
        if case .stopping = status { key = "stopping" } else { key = "stalledDrain" }
        let cause: String
        switch reason { case .cancelled: cause = "cancelled"; case .timedOut: cause = "timedOut" }
        return workflowText(language, "chat.recognition." + key, arguments: ["reason": workflowText(language, "chat.recognition." + cause)])
    }
}

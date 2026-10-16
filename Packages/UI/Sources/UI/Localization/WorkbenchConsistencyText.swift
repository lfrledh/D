import SwiftUI

@MainActor func consistencyText(_ language: UILanguageStore?, _ key: String, arguments: [String: String] = [:]) -> String {
    (language ?? ConsistencyLanguageDefaults.english).text("consistency." + key, fallback: key, arguments: arguments)
}

@MainActor func workbenchIntegerEditingError(_ raw: String, field: String, language: UILanguageStore?) -> String? {
    if raw.isEmpty { return consistencyText(language, "validation.integerRequired", arguments: ["field": field]) }
    if Int(raw) == nil { return consistencyText(language, "validation.integerInvalid", arguments: ["field": field]) }
    return nil
}

@MainActor private enum ConsistencyLanguageDefaults { static let english = UILanguageStore(preferredLanguages: ["en"]) }

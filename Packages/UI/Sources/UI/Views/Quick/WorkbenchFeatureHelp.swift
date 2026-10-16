import SwiftUI
import DWorkbench

/// Presentation data only: original commands and admission stay with their owners.
struct WorkbenchFeature: Decodable, Identifiable {
    let id: String
    let name_key: String
    let help_key: String
    let object_key: String
    let conditions_key: String
    let category: String
    let aliases: [String]
    let destructive: Bool
}
@MainActor enum WorkbenchFeatures {
    static let all: [WorkbenchFeature] = {
        guard let url = Bundle.module.url(forResource: "WorkbenchFeatureHelp", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([WorkbenchFeature].self, from: data),
              Set(values.map(\.id)).count == values.count else { return [] }
        return values
    }()
    static func feature(_ id: String) -> WorkbenchFeature? { all.first { $0.id == id } }
    static func text(_ key: String, language: UILanguageStore?) -> String {
        consistencyText(language, String(key.dropFirst("consistency.".count)))
    }
    static func purpose(_ id: String, language: UILanguageStore?) -> String {
        feature(id).map { text($0.help_key, language: language) } ?? ""
    }
}
struct WorkbenchHelpContext: Equatable {
    let featureID: String
    let owner: String
    let unavailableReason: String?
}
struct WorkbenchHelpPresentation: Identifiable {
    let id = UUID()
    let featureID: String?
    let token: UUID?
    let context: WorkbenchHelpContext?
}
@MainActor @Observable final class WorkbenchHelpStore {
    var presentation: WorkbenchHelpPresentation?
    private(set) var contexts: [UUID: WorkbenchHelpContext] = [:]
    func update(_ token: UUID, context: WorkbenchHelpContext) {
        if contexts[token] != context { contexts[token] = context }
    }
    func remove(_ token: UUID) { contexts.removeValue(forKey: token) }
    func pin(_ token: UUID) {
        guard let context = contexts[token] else { return }
        presentation = .init(featureID: context.featureID, token: token, context: context)
    }
    func isCurrent(_ value: WorkbenchHelpPresentation) -> Bool {
        guard let token = value.token, let context = value.context else { return true }
        return contexts[token]?.owner == context.owner && contexts[token]?.featureID == context.featureID
    }
}
private struct WorkbenchHelpStoreKey: EnvironmentKey { static let defaultValue: WorkbenchHelpStore? = nil }
extension EnvironmentValues {
    var workbenchHelpStore: WorkbenchHelpStore? {
        get { self[WorkbenchHelpStoreKey.self] }
        set { self[WorkbenchHelpStoreKey.self] = newValue }
    }
}
private struct WorkbenchFeatureHelpModifier: ViewModifier {
    let id: String
    let reason: String?
    let target: String?
    @Environment(\.dLanguageStore) private var language
    @Environment(\.workbenchMenuContext) private var owner
    @Environment(\.workbenchHelpStore) private var store
    @State private var token = UUID()
    private var context: WorkbenchHelpContext { .init(featureID: id, owner: owner + (target.map { ":" + $0 } ?? ""), unavailableReason: reason) }
    func body(content: Content) -> some View {
        content.help(WorkbenchFeatures.purpose(id, language: language))
            .accessibilityHint(WorkbenchFeatures.purpose(id, language: language))
            .accessibilityAction(named: Text(consistencyText(language, "help.open"))) { store?.pin(token) }
            .onAppear { store?.update(token, context: context) }
            .onChange(of: context) { _, value in store?.update(token, context: value) }
            .onDisappear { store?.remove(token) }
    }
}
extension View {
    @ViewBuilder func workbenchHelp(_ feature: String?, unavailableReason: String? = nil, target: String? = nil) -> some View {
        if let feature { modifier(WorkbenchFeatureHelpModifier(id: feature, reason: unavailableReason, target: target)) } else { self }
    }
}
/// Explicitly opened, stable reading surface. No hover timer, automatic focus or actions.
struct WorkbenchFeatureGuide: View {
    let presentation: WorkbenchHelpPresentation
    let store: WorkbenchHelpStore
    @Environment(\.dLanguageStore) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    private let categories = ["project", "models", "build", "inspect", "organize", "view"]
    private var selectedFeature: WorkbenchFeature? {
        (presentation.featureID ?? selected).flatMap(WorkbenchFeatures.feature)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(consistencyText(language, "help.title")).font(.title2)
                Spacer()
                Button(consistencyText(language, "help.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("feature-guide-close")
            }
            HStack(alignment: .top, spacing: 16) {
                if presentation.featureID == nil {
                    VStack(alignment: .leading) {
                        TextField(consistencyText(language, "help.search"), text: $query)
                        WorkbenchScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(categories, id: \.self) { category in
                                    let entries = WorkbenchFeatures.all.filter { $0.category == category && matches($0) }
                                    if !entries.isEmpty {
                                        Text(consistencyText(language, "help.category." + category)).font(.headline)
                                        ForEach(entries) { feature in
                                            Button(WorkbenchFeatures.text(feature.name_key, language: language)) { selected = feature.id }
                                                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 4)
                                                .help(WorkbenchFeatures.purpose(feature.id, language: language))
                                                .accessibilityIdentifier("feature-guide-" + feature.id)
                                        }
                                    }
                                }
                            }.padding(8)
                        }
                    }.frame(width: 230)
                }
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let feature = selectedFeature {
                            Text(WorkbenchFeatures.text(feature.name_key, language: language)).font(.title3.bold())
                            if !store.isCurrent(presentation) {
                                Text(consistencyText(language, "help.stale")).foregroundStyle(.orange)
                            }
                            section("purpose", feature.help_key)
                            section("object", feature.object_key)
                            section("conditions", feature.conditions_key)
                            if let reason = currentReason {
                                Text(reason).foregroundStyle(.secondary)
                            } else if presentation.token == nil {
                                // Each visible occurrence retains its own captured owner and reason.
                                ForEach(Array(store.contexts.filter { $0.value.featureID == feature.id && $0.value.unavailableReason != nil }.keys), id: \.self) { token in
                                    if let reason = store.contexts[token]?.unavailableReason { Text(reason).foregroundStyle(.secondary) }
                                }
                            }
                        } else {
                            Text(consistencyText(language, "help.choose")).foregroundStyle(.secondary)
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
        }.padding(20).frame(minWidth: 640, idealWidth: 780, minHeight: 440, idealHeight: 580)
            .workbenchPresentation()
    }
    private var currentReason: String? {
        if store.isCurrent(presentation), let token = presentation.token { return store.contexts[token]?.unavailableReason }
        return presentation.context?.unavailableReason
    }
    private func section(_ heading: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(consistencyText(language, "help." + heading)).font(.headline)
            Text(WorkbenchFeatures.text(key, language: language)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func matches(_ feature: WorkbenchFeature) -> Bool {
        query.isEmpty || (feature.aliases + [WorkbenchFeatures.text(feature.name_key, language: language), WorkbenchFeatures.text(feature.help_key, language: language)])
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Reads the same existing gates; it never changes command admission.
@MainActor func canvasHelpReason(_ controller: WorkflowController, readOnly: Bool = false, language: UILanguageStore?) -> String? {
    if let reason = controller.readOnlyReason { return reason }
    if !controller.canReadLibraryMetadata { return consistencyText(language, "help.reason.closed") }
    if controller.externalOperationBusy() { return consistencyText(language, "help.reason.busy") }
    if readOnly || (controller.isRunning && !controller.canEditCanvas) { return consistencyText(language, "help.reason.running") }
    if !controller.graphs.isEmpty && controller.graph == nil { return consistencyText(language, "help.reason.graph") }
    return nil
}

struct WorkbenchFeatureGuideButton: View {
    let store: WorkbenchHelpStore
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        Button { store.presentation = .init(featureID: nil, token: nil, context: nil) } label: {
            Image(systemName: "questionmark.circle")
        }.help(consistencyText(language, "help.open"))
            .accessibilityLabel(consistencyText(language, "help.title"))
    }
}

import DWorkbench
import SwiftUI

/// Facts from the exact selected configuration and registered operation. Merely
/// reading this card cannot prepare a model, acquire a lease or start a request.
struct WorkbenchModelCard: View {
    let definition: WorkflowOperationDefinition
    let modelID: String?
    let choices: [WorkflowModelChoice]
    let status: String
    var change: (() -> Void)? = nil
    var canChange = true
    var changeUnavailableReason: String? = nil
    var usingDefault = false
    @Environment(\.dLanguageStore) private var language
    @State private var details = false
    @Environment(\.workbenchMenuContext) private var helpOwner
    private var choice: WorkflowModelChoice? {
        choices.first { $0.id == modelID && $0.kind == definition.modelKind }
            ?? modelID.flatMap { WorkflowModelRoutes.draftChoice(operationID: definition.id, modelID: $0) }
    }
    private var descriptor: ModelNodeDescriptor? { choice.flatMap(SharedLibraryProjection.descriptor(for:)).map { ModelNodeUILocalization.display($0, language: language) } }
    private var name: String {
        guard definition.modelKind != nil else { return consistencyText(language, "copy.noModelNeeded") }
        return descriptor?.title ?? choice?.displayName ?? consistencyText(language, modelID?.isEmpty == false ? "copy.boundModelUnavailable" : "copy.noModel")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).workbenchHelp("MODEL-CARD").font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if definition.modelKind != nil { ModelSpecificationSummary(descriptor: descriptor) }
            Text(WorkflowCanvasPresentation.operationDetail(definition, language: language)).workbenchHelp("MODEL-PURPOSE")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(definition.inputs) { port in
                    Text(consistencyText(language, "copy.input") + " · " + WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: port, input: true, language: language)
                        + (port.required ? baselineText(language, "required") : baselineText(language, "optional")))
                }
                ForEach(definition.outputs) { port in
                    Text(consistencyText(language, "copy.output") + " · " + WorkflowCanvasPresentation.portTitle(operationID: definition.id, port: port, input: false, language: language))
                }
            }.workbenchHelp("MODEL-IO").font(.caption).fixedSize(horizontal: false, vertical: true)
            if usingDefault && definition.modelKind != nil { Text(consistencyText(language, "copy.usingDefault")).font(.caption) }
            if definition.modelKind != nil { Text(status).workbenchHelp("MODEL-STATUS").font(.callout).foregroundStyle(.secondary) }
            HStack {
                if let change { Button(consistencyText(language, "MODEL-CHANGE"), action: change).workbenchHelp("MODEL-CHANGE", unavailableReason: canChange ? nil : changeUnavailableReason).disabled(!canChange) }
                Button(consistencyText(language, "MODEL-DETAILS")) { details = true }.workbenchHelp("MODEL-DETAILS")
            }
        }.environment(\.workbenchMenuContext, "\(helpOwner):model:\(definition.id):\(modelID ?? "none")")
        .sheet(isPresented: $details) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(consistencyText(language, "MODEL-DETAILS")).font(.headline); Spacer(); Button(workflowText(language, "common.done")) { details = false }.keyboardShortcut(.cancelAction) }
                    Text(name).font(.title3).textSelection(.enabled)
                    Text(WorkflowCanvasPresentation.operationDetail(definition, language: language)).textSelection(.enabled)
                    if let descriptor {
                        Text(descriptor.engine).textSelection(.enabled)
                        Text(descriptor.precision).textSelection(.enabled)
                    }
                    DisclosureGroup(consistencyText(language, "copy.technical")) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let modelID { Text(modelID).textSelection(.enabled) }
                            if let descriptor { Text(descriptor.modelIdentity).textSelection(.enabled); Text(descriptor.revision).textSelection(.enabled) }
                            Text(definition.id).textSelection(.enabled)
                        }.font(.caption.monospaced())
                    }
                }.padding(20)
            }.frame(minWidth: 480, idealWidth: 580, minHeight: 360).workbenchPresentation()
        }
    }
}

private struct WorkbenchModelReadinessKey: EnvironmentKey {
    static let defaultValue: [String: SharedLibraryReadiness] = [:]
}
extension EnvironmentValues {
    var workbenchModelReadiness: [String: SharedLibraryReadiness] {
        get { self[WorkbenchModelReadinessKey.self] }
        set { self[WorkbenchModelReadinessKey.self] = newValue }
    }
}
@MainActor func workbenchModelReadinessText(_ readiness: SharedLibraryReadiness, language: UILanguageStore?) -> String {
    switch readiness {
    case .available: baselineText(language, "readiness.ready")
    case .unprepared: baselineText(language, "readiness.unprepared")
    case .unavailable: baselineText(language, "readiness.unavailable")
    case .unsupported: baselineText(language, "readiness.unsupported")
    case .unknown: baselineText(language, "readiness.unknown")
    }
}

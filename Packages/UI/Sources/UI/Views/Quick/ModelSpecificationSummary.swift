import DWorkbench
import SwiftUI

struct ModelSpecificationSummary: View {
    let descriptor: ModelNodeDescriptor
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scale = descriptor.parameterScale {
                let scope: String = switch scale.scope {
                case .total: workspaceText(language, "totalParameters")
                case .languageModel: workspaceText(language, "languageParameters")
                case .officialPublished: workspaceText(language, "officialParameters")
                case .vocoder: workspaceText(language, "vocoderParameters")
                case .transformer: workspaceText(language, "transformerParameters")
                }
                Text("\(scale.publishedBillions)B · \(scope)").font(.headline)
            } else { Text(workspaceText(language, "scaleUnrecorded")).font(.caption).foregroundStyle(.secondary) }
            if let precision = descriptor.weightSummary {
                Text(precision.hasPrefix("model.spec.") ? workflowText(language, precision) : precision).font(.headline)
            }
            DisclosureGroup(workspaceText(language, "modelSpecification")) {
                Text(ModelNodeUILocalization.owned(descriptor.precision, language: language)).font(.caption).textSelection(.enabled)
                if descriptor.modelIdentity == "black-forest-labs/FLUX.2-dev" && descriptor.revision == "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c" { Text(workflowText(language, "model.spec.guidanceDistillation")).font(.caption) }
                if let reason = descriptor.unrecordedScaleReasonKey { Text(workflowText(language, reason)).font(.caption) }
                if let scale = descriptor.parameterScale {
                    if let note = scale.noteKey { Text(workflowText(language, note)).font(.caption).textSelection(.enabled) }
                    Text(workspaceText(language, "activeUnknown")).font(.caption)
                    ForEach(scale.sourceURLs, id: \.self) { source in
                        if let url = URL(string: source) { Link(workspaceText(language, "scaleSource"), destination: url).font(.caption) }
                    }
                }
            }
        }
    }
}

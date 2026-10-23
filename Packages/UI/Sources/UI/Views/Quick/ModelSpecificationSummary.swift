import DWorkbench
import SwiftUI

/// Display-only facts for both the canvas and model library. Missing exact
/// metadata stays explicit; names, revisions and file sizes are never parsed.
@MainActor struct ModelSpecificationPresentation {
    let parameterLabel: String
    let parameterValue: String
    let precisionLabel: String
    let precisionValue: String

    init(descriptor: ModelNodeDescriptor?, language: UILanguageStore?) {
        parameterLabel = workflowText(language, "model.spec.parameterCount")
        precisionLabel = workflowText(language, "model.spec.quantizationPrecision")
        let unknown = workflowText(language, "model.spec.unrecorded")
        if let scale = descriptor?.parameterScale {
            let scope: String = switch scale.scope {
            case .total: workspaceText(language, "totalParameters")
            case .languageModel: workspaceText(language, "languageParameters")
            case .officialPublished: workspaceText(language, "officialParameters")
            case .vocoder: workspaceText(language, "vocoderParameters")
            case .transformer: workspaceText(language, "transformerParameters")
            }
            parameterValue = workflowText(language, "model.spec.parameterValue",
                arguments: ["count": scale.publishedBillions, "scope": scope])
        } else { parameterValue = unknown }
        if let precision = descriptor?.weightSummary, !precision.isEmpty {
            precisionValue = precision.hasPrefix("model.spec.") ? workflowText(language, precision) : precision
        } else { precisionValue = unknown }
    }
}

struct ModelSpecificationFields: View {
    let descriptor: ModelNodeDescriptor?
    var font: Font = .callout
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        let values = ModelSpecificationPresentation(descriptor: descriptor, language: language)
        VStack(alignment: .leading, spacing: 4) {
            field(values.parameterLabel, values.parameterValue, id: "parameter-count")
            field(values.precisionLabel, values.precisionValue, id: "quantization-precision")
        }.font(font)
    }
    private func field(_ label: String, _ value: String, id: String) -> some View {
        (Text(label + ": ").fontWeight(.semibold) + Text(value))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("model-specification-" + id)
    }
}

struct ModelSpecificationSummary: View {
    let descriptor: ModelNodeDescriptor?
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ModelSpecificationFields(descriptor: descriptor)
            if let descriptor {
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
}

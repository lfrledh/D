import DWorkbench
import SwiftUI

struct ModelSpecificationSummary: View {
    let descriptor: ModelNodeDescriptor
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scale = descriptor.parameterScale {
                let scope: String = switch scale.scope {
                case .total: workspaceText(language, "totalParameters", "总参数", "Total parameters")
                case .languageModel: workspaceText(language, "languageParameters", "语言组件", "Language component")
                case .officialPublished: workspaceText(language, "officialParameters", "官方公布规模", "Official published scale")
                case .vocoder: workspaceText(language, "vocoderParameters", "声码器", "Vocoder")
                case .transformer: workspaceText(language, "transformerParameters", "生成主干", "Transformer component")
                }
                Text("\(scale.publishedBillions)B · \(scope)").font(.headline)
            } else { Text(workspaceText(language, "scaleUnrecorded", "参数规模未记录", "Parameter scale unrecorded")).font(.caption).foregroundStyle(.secondary) }
            if let precision = descriptor.weightSummary {
                Text(precision).font(.headline)
            }
            DisclosureGroup(workspaceText(language, "modelSpecification", "精度、组件与来源", "Precision, components & sources")) {
                Text(descriptor.precision).font(.caption).textSelection(.enabled)
                if descriptor.modelIdentity == "black-forest-labs/FLUX.2-dev" && descriptor.revision == "26afe3a78bb242c0a8bb181dcc8937bb16e5c66c" { Text("Guidance distillation · 引导蒸馏").font(.caption) }
                if let reason = descriptor.unrecordedScaleReason { Text(reason).font(.caption) }
                if let scale = descriptor.parameterScale {
                    if let note = scale.note { Text(note).font(.caption).textSelection(.enabled) }
                    Text(workspaceText(language, "activeUnknown", "激活参数未记录；组件数量不代表整套管线总量。", "Active parameters not recorded; component counts are not pipeline totals.")).font(.caption)
                    ForEach(scale.sourceURLs, id: \.self) { source in
                        if let url = URL(string: source) { Link(workspaceText(language, "scaleSource", "参数规模来源", "Parameter source"), destination: url).font(.caption) }
                    }
                }
            }
        }
    }
}

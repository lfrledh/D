import DWorkbench
import Foundation
import SwiftUI

/// OutlineGroup is hosted in our scroll surface, not a system outline List.
/// Indent the complete child group, including its disclosure arrow and leaf card.
struct WorkflowOperationTreeDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.dLanguageStore) private var language
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded
                ? workspaceText(language, "treeExpanded", "已展开", "Expanded")
                : workspaceText(language, "treeCollapsed", "已收起", "Collapsed"))
            if configuration.isExpanded {
                configuration.content
                    .disclosureGroupStyle(WorkflowOperationTreeDisclosureStyle())
                    .padding(.leading, 12)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presentation groups only. Executable leaves retain the original entry and
/// its registered handler; descriptive adapter operations never become fake nodes.
struct WorkflowOperationTree: Identifiable {
    let id:String
    let title:String
    let entry:SharedLibraryBrowserEntry?
    var children:[WorkflowOperationTree]?
    @MainActor static func make(_ entries:[SharedLibraryBrowserEntry],models:Bool,language:UILanguageStore?) -> [Self] {
        func path(_ entry:SharedLibraryBrowserEntry)->[String] {
            if models {
                guard let descriptor=ModelNodeCatalog.entries.first(where:{$0.id == entry.item.key}) else {
                    return [workspaceText(language,"otherModel","其他已登记模型","Other registered models"),entry.item.title]
                }
                let modality: String = switch descriptor.modality {
                case .text: workspaceText(language,"text","文字","Text")
                case .image: workspaceText(language,"image","图像","Images")
                case .video: workspaceText(language,"video","视频","Video")
                case .audio: workspaceText(language,"audio","音频","Audio")
                }
                let names=["Qwen3.5","Qwen3","Qwen2.5","FLUX.2","Stable Audio","Magenta Realtime","ACE-Step","Wan","LTX","SwiftF0","绮萱"]
                let family=names.first { descriptor.title.localizedCaseInsensitiveContains($0) } ?? descriptor.title
                let model=descriptor.title.components(separatedBy:" · ").first ?? descriptor.title
                return [modality,family,model,descriptor.precision.isEmpty ? workspaceText(language,"variantUnknown","变体未记录","Variant unrecorded") : descriptor.precision]
            }
            if entry.item.kind == .tool { return [workspaceText(language,"custom","自定义","Custom")] }
            guard case .operation(let id,_)=entry.selection,let definition=WorkflowRegistry.standard.operation(id)?.definition else { return [workspaceText(language,"otherProgram","其他程序","Other programs")] }
            if definition.interaction != .none || id == "d.control.human" { return [workspaceText(language,"humanPrograms","人工检查","Human review")] }
            if id.hasPrefix("d.control.") { return [workspaceText(language,"controlPrograms","流程控制","Flow control")] }
            if definition.inputs.isEmpty || definition.outputs.isEmpty || id.hasPrefix("d.input.") || id.hasPrefix("d.export.") {
                return [workspaceText(language,"ioPrograms","输入与输出","Inputs & outputs")]
            }
            return [workspaceText(language,"conversionPrograms","转换与处理","Transform & process")]
        }
        func build(_ values:[(SharedLibraryBrowserEntry,[String])],prefix:String)->[Self] {
            var result:[Self]=[]
            let groups=Dictionary(grouping:values,by:{$0.1.first ?? ""})
            for title in groups.keys.sorted(by:{$0.localizedStandardCompare($1) == .orderedAscending}) {
                let items=groups[title]!
                if title.isEmpty {
                    result += items.map { .init(id:$0.0.id,title:$0.0.item.detail,entry:$0.0,children:nil) }
                } else {
                    let id=prefix+"/"+title
                    result.append(.init(id:id,title:title,entry:nil,children:build(items.map { ($0.0,Array($0.1.dropFirst())) },prefix:id)))
                }
            }
            return result
        }
        return build(entries.map { ($0,path($0)) },prefix:models ? "models":"programs")
    }
}

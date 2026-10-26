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
                ? workspaceText(language, "treeExpanded")
                : workspaceText(language, "treeCollapsed"))
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
        typealias Segment = (id: String, title: String)
        func path(_ entry: SharedLibraryBrowserEntry) -> [Segment] {
            if models {
                guard let descriptor = ModelNodeCatalog.entries.first(where: { $0.id == entry.item.key }) else {
                    return [("other-model", workspaceText(language, "otherModel"))]
                }
                let mode: String = switch descriptor.modality {
                case .text: workspaceText(language, "text")
                case .image: workspaceText(language, "image")
                case .video: workspaceText(language, "video")
                case .audio: workspaceText(language, "audio")
                }
                // These are explicitly registered engines, not guesses from a localized title.
                let engine = descriptor.engine.components(separatedBy: " · ").first ?? descriptor.engine
                let registeredFamilies = ["Qwen/Qwen3.5-9B":"Qwen3.5", "mlx-community/Qwen3.5-9B-4bit":"Qwen3.5",
                    "Qwen/Qwen3.8-27B":"Qwen3.8", "mlx-community/Qwen3.8-27B-4bit":"Qwen3.8"]
                let families = ["mlx.text":"Qwen2.5",
                    "mlx.image.flux2-klein":"FLUX.2 Klein", "mlx.image.flux2-dev":"FLUX.2 Dev",
                    "mlx.audio.sa3":"Stable Audio 3", "mlx.audio.mrt2":"Magenta Realtime",
                    "cpu.pitch.swift-f0":"SwiftF0", "audio.singing.qixuan":"Qixuan",
                    "mlx.video.wan21":"Wan 2.1", "mlx.audio.ace-step-1.5-xl-sft":"ACE-Step 1.5"]
                let family = registeredFamilies[descriptor.id] ?? families[engine] ?? engine
                return [("mode:" + descriptor.modality.rawValue, mode), ("family:" + family, family)]
            }
            if entry.item.kind == .tool { return [("custom", workspaceText(language, "custom"))] }
            guard case .operation(let id,_) = entry.selection, let definition = WorkflowRegistry.standard.operation(id)?.definition else {
                return [("other-program", workspaceText(language, "otherProgram"))]
            }
            if WorkflowAssetContainer.isContainer(id) { return [("io", workspaceText(language, "ioPrograms"))] }
            if definition.interaction != .none || id == "d.control.human" { return [("human", workspaceText(language, "humanPrograms"))] }
            if id.hasPrefix("d.control.") { return [("control", workspaceText(language, "controlPrograms"))] }
            if definition.inputs.isEmpty || definition.outputs.isEmpty || id.hasPrefix("d.input.") || id.hasPrefix("d.export.") {
                return [("io", workspaceText(language, "ioPrograms"))]
            }
            return [("transform", workspaceText(language, "conversionPrograms"))]
        }

        func build(_ values:[(SharedLibraryBrowserEntry,[Segment])],prefix:String)->[Self] {
            var result:[Self]=[]
            let groups=Dictionary(grouping:values,by:{$0.1.first?.id ?? ""})
            for title in groups.keys.sorted(by:{$0.localizedStandardCompare($1) == .orderedAscending}) {
                let items=groups[title]!
                if title.isEmpty {
                    result += items.map { .init(id:$0.0.id,title:$0.0.item.detail,entry:$0.0,children:nil) }
                } else {
                    let id=prefix+"/"+title
                    result.append(.init(id:id,title:items[0].1[0].title,entry:nil,children:build(items.map { ($0.0,Array($0.1.dropFirst())) },prefix:id)))
                }
            }
            return result
        }
        return build(entries.map { ($0,path($0)) },prefix:models ? "models":"programs")
    }
}

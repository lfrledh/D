import DWorkbench
import SwiftUI

/// A modality-scoped, descriptive catalog. Selecting a row only reports its stable ID.
@MainActor
public struct ModelNodeList: View {
    private let entries: [ModelNodeDescriptor]
    private let selectedID: String?
    private let onSelect: (String) -> Void
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(entries: [ModelNodeDescriptor], selectedID: String?, onSelect: @escaping (String) -> Void) {
        self.entries = entries
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    /// Internal rendered-geometry observation for native hosting tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    ContentUnavailableView("这个模态还没有可说明的模型节点",
                                           systemImage: "cube.transparent",
                                           description: Text("查看模型节点不会下载、安装或创建任务。"))
                        .accessibilityIdentifier("model-node-list-empty")
                        .padding(.vertical, 28)
                } else {
                    ForEach(entries) { entry in
                        Button { onSelect(entry.id) } label: {
                            ModelNodeListRow(node: entry, isSelected: entry.id == selectedID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("model-node-list-\(entry.id)")
                        .accessibilityLabel("\(entry.title)，\(entry.availability.title)")
                        .accessibilityAddTraits(entry.id == selectedID ? .isSelected : [])
                        .modelNodeMeasured("model-node-list-\(entry.id)", probe: layoutProbe)
                    }
                }
            }
            .padding(10)
        }
        .accessibilityIdentifier("model-node-list")
        .coordinateSpace(name: ModelNodeLayoutSpace.name)
        .modelNodeMeasured("model-node-list", probe: layoutProbe)
    }
}

@MainActor
public struct ModelNodeDetail: View {
    public let node: ModelNodeDescriptor
    private let initialTags: [String]
    private let onTagsChange: ([String]) -> String?
    @State private var tagEditor: ModelNodeTagEditorState
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(node: ModelNodeDescriptor, tags: [String], onTagsChange: @escaping ([String]) -> String?) {
        self.node = node
        self.initialTags = tags
        self.onTagsChange = onTagsChange
        _tagEditor = State(initialValue: ModelNodeTagEditorState(tags: tags))
    }

    /// Internal rendered-geometry observation for native hosting tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityAndExecution
                tagsSection
                operationsSection
                parametersSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .modelNodeMeasured("model-node-detail-content-\(node.id)", probe: layoutProbe)
        }
        .accessibilityIdentifier("model-node-detail-\(node.id)")
        .coordinateSpace(name: ModelNodeLayoutSpace.name)
        .modelNodeMeasured("model-node-detail-\(node.id)", probe: layoutProbe)
        .onChange(of: node.id) { _, _ in
            tagEditor = ModelNodeTagEditorState(tags: initialTags)
        }
    }

    private var identityAndExecution: some View {
        ModelNodeSection("身份与执行", identifier: "identity") {
            Text(node.title).font(.title2.weight(.semibold))
            Text(node.summary).foregroundStyle(.secondary)
            ModelNodeMetadataRow("模型 ID", value: node.modelIdentity)
            ModelNodeMetadataRow("版本", value: node.revision)
            ModelNodeMetadataRow("引擎", value: node.engine)
            ModelNodeMetadataRow("设备", value: node.device)
            ModelNodeMetadataRow("精度", value: node.precision)
            ModelNodeMetadataRow("可用范围", value: node.availability.title)
            ModelNodeMetadataRow("部署与验证边界", value: node.deploymentNote)
            if !node.notes.isEmpty {
                ModelNodeMetadataRow("限制与说明", value: node.notes.joined(separator: "\n"))
            }
            if !node.evidencePaths.isEmpty {
                ModelNodeMetadataRow("证据", value: node.evidencePaths.joined(separator: "\n"))
            }
        }
    }

    private var tagsSection: some View {
        ModelNodeSection("用户标签", identifier: "tags") {
            Text("标签只保存在本机，用于整理；不会改变模型能力、许可或生成设置。")
                .font(.caption).foregroundStyle(.secondary)
            if tagEditor.tags.isEmpty {
                Text("尚无标签").foregroundStyle(.secondary)
                    .accessibilityIdentifier("model-node-tags-empty")
                    .modelNodeMeasured("model-node-tags-empty-\(node.id)", probe: layoutProbe)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tagEditor.tags, id: \.self) { tag in
                        HStack(spacing: 8) {
                            Text(tag).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("移除 \(tag)", systemImage: "xmark") { remove(tag) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("model-node-tag-remove-\(node.id)-\(tag)")
                                .modelNodeMeasured("model-node-tag-remove-\(node.id)-\(tag)", probe: layoutProbe)
                        }
                        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .accessibilityIdentifier("model-node-tags")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("添加标签", text: $tagEditor.draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model-node-tag-draft-\(node.id)")
                    .onSubmit(addDraft)
                    .modelNodeMeasured("model-node-tag-draft-\(node.id)", probe: layoutProbe)
                Button("添加", action: addDraft)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("model-node-tag-add-\(node.id)")
                    .modelNodeMeasured("model-node-tag-add-\(node.id)", probe: layoutProbe)
            }
            if let error = tagEditor.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("model-node-tag-error-\(node.id)")
            }
        }
    }

    private var operationsSection: some View {
        ModelNodeSection("操作与端口", identifier: "operations") {
            if node.operations.isEmpty {
                Text("没有记录操作说明。").foregroundStyle(.secondary)
            }
            ForEach(node.operations) { operation in
                VStack(alignment: .leading, spacing: 10) {
                    Text(operation.title).font(.headline)
                    Text(operation.summary).foregroundStyle(.secondary)
                    ModelNodePortGroup(title: "输入", direction: "输入", ports: operation.inputs,
                                       emptyText: "此操作没有输入端口。")
                        .modelNodeMeasured("model-node-ports-\(node.id)-\(operation.id)-inputs", probe: layoutProbe)
                    ModelNodePortGroup(title: "输出", direction: "输出", ports: operation.outputs,
                                       emptyText: "此操作没有输出端口。")
                        .modelNodeMeasured("model-node-ports-\(node.id)-\(operation.id)-outputs", probe: layoutProbe)
                    Text("输出描述的是成功执行后必有或可能产生的结果，不是可勾选的输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("model-node-operation-\(node.id)-\(operation.id)")
            }
        }
    }

    private var parametersSection: some View {
        ModelNodeSection("参数", identifier: "parameters") {
            Text("参数是可检查的后端规格，不是可执行的生成设置。")
                .font(.caption).foregroundStyle(.secondary)
            let parameters = node.operations.flatMap(\.parameters)
            if parameters.isEmpty {
                Text("没有记录参数说明。").foregroundStyle(.secondary)
            }
            ForEach(node.operations) { operation in
                if !operation.parameters.isEmpty {
                    Text(operation.title).font(.headline).padding(.top, 4)
                    ForEach(operation.parameters) { parameter in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(parameter.title).font(.callout.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(parameter.isAdjustable ? "后端可调" : "固定")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ModelNodeMetadataRow("默认", value: parameter.defaultValue)
                            ModelNodeMetadataRow("可接受值／约束", value: parameter.acceptedValues)
                            ModelNodeMetadataRow("说明", value: parameter.detail)
                        }
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("model-node-parameter-\(node.id)-\(operation.id)-\(parameter.id)")
                        .modelNodeMeasured("model-node-parameter-\(node.id)-\(operation.id)-\(parameter.id)", probe: layoutProbe)
                    }
                }
            }
        }
    }

    private func addDraft() {
        switch tagEditor.proposedAddition() {
        case .failure(let message): tagEditor.reject(message)
        case .success(let proposed):
            if let error = onTagsChange(proposed) { tagEditor.reject(error) }
            else { tagEditor.accept(tags: proposed) }
        }
    }

    private func remove(_ tag: String) {
        let proposed = tagEditor.tags.filter { $0 != tag }
        if let error = onTagsChange(proposed) { tagEditor.reject(error) }
        else { tagEditor.accept(tags: proposed) }
    }
}

enum ModelNodeTagProposal: Equatable {
    case success([String])
    case failure(String)
}

struct ModelNodeTagEditorState: Equatable {
    var tags: [String]
    var draft = ""
    var errorMessage: String?

    init(tags: [String]) { self.tags = tags }

    mutating func accept(tags: [String]) {
        self.tags = tags
        draft = ""
        errorMessage = nil
    }

    mutating func reject(_ error: String) {
        errorMessage = error
    }

    func proposedAddition() -> ModelNodeTagProposal {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .failure("请输入标签内容。") }
        guard !tags.contains(candidate) else { return .failure("这个标签已经存在。") }
        return .success(tags + [candidate])
    }
}

private struct ModelNodeListRow: View {
    let node: ModelNodeDescriptor
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(node.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(node.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(node.availability.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ModelNodeSection<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder let content: Content

    init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("model-node-section-\(identifier)")
    }
}

private struct ModelNodeMetadataRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) { self.title = title; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelNodePortGroup: View {
    let title: String
    let direction: String
    let ports: [ModelNodePort]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: direction == "输入" ? "arrow.down.circle" : "arrow.up.circle")
                .font(.subheadline.weight(.semibold))
            if ports.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ports) { port in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(port.title).font(.callout.weight(.medium))
                        Text("\(direction) · \(port.dataType)").font(.caption).foregroundStyle(.secondary)
                        Text(port.detail).font(.caption).foregroundStyle(.secondary)
                        if let condition = port.requirement.condition {
                            Text(condition).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(port.requirement.title).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(requirementColor(port.requirement).opacity(0.14), in: Capsule())
                        .foregroundStyle(requirementColor(port.requirement))
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func requirementColor(_ requirement: ModelNodePortRequirement) -> Color {
        switch requirement {
        case .required: .red
        case .optional: .secondary
        case .conditional: .orange
        }
    }
}

private enum ModelNodeLayoutSpace {
    static let name = "model-node-layout"
}

private extension View {
    func modelNodeMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(ModelNodeLayoutSpace.name))
        } action: { rectangle in
            probe?(id, rectangle)
        }
    }
}

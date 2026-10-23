import DWorkbench
import SwiftUI

/// A modality-scoped, descriptive catalog. Selecting a row only reports its stable ID.
@MainActor
public struct ModelNodeList: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

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
                    ContentUnavailableView(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.147"),
                                           systemImage: "cube.transparent",
                                           description: Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.148")))
                        .accessibilityIdentifier("model-node-list-empty")
                        .padding(.vertical, 28)
                } else {
                    ForEach(entries) { entry in
                        Button { onSelect(entry.id) } label: {
                            ModelNodeListRow(node: entry, isSelected: entry.id == selectedID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("model-node-list-\(entry.id)")
                        .accessibilityLabel(ModelNodeUILocalization.display(entry, language: legacyLanguage).title + ", " + ModelNodeUILocalization.availability(entry.availability, language: legacyLanguage))
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
    @Environment(\.dLanguageStore) private var legacyLanguage

    public let node: ModelNodeDescriptor
    private var displayNode: ModelNodeDescriptor { ModelNodeUILocalization.display(node, language: legacyLanguage) }
    private let tagState: ModelNodeTagReadState
    private let onTagsChange: ([String]) -> String?
    private let organizationTags: AnyView?
    @State private var tagEditor: ModelNodeTagEditorState
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(
        node: ModelNodeDescriptor,
        tagState: ModelNodeTagReadState,
        onTagsChange: @escaping ([String]) -> String?, organizationTags: AnyView? = nil
    ) {
        self.node = node
        self.tagState = tagState
        self.onTagsChange = onTagsChange
        self.organizationTags = organizationTags
        _tagEditor = State(initialValue: ModelNodeTagEditorState(tagState: tagState))
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
                if let organizationTags { organizationTags } else { tagsSection }
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
            tagEditor = ModelNodeTagEditorState(tagState: tagState)
        }
        .onChange(of: tagState) { _, newState in
            tagEditor.applyIncomingReadState(newState)
        }
    }

    private var identityAndExecution: some View {
        ModelNodeSection(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.149"), identifier: "identity") {
            Text(displayNode.title).font(.title2.weight(.semibold))
            Text(displayNode.summary).foregroundStyle(.secondary)
            ModelSpecificationFields(descriptor: node)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.150"), value: node.modelIdentity)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.151"), value: node.revision)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.152"), value: displayNode.engine)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.153"), value: displayNode.device)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.154"), value: displayNode.precision)
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.155"), value: ModelNodeUILocalization.availability(node.availability, language: legacyLanguage))
            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.156"), value: displayNode.deploymentNote)
            if !displayNode.notes.isEmpty {
                ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.157"), value: displayNode.notes.joined(separator: "\n"))
            }
            if !node.evidencePaths.isEmpty {
                ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.158"), value: node.evidencePaths.joined(separator: "\n"))
            }
        }
    }

    private var tagsSection: some View {
        ModelNodeSection(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.159"), identifier: "tags") {
            Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.160"))
                .font(.caption).foregroundStyle(.secondary)
            if !tagEditor.isEditable {
                Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.161"))
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("model-node-tags-corrupt-\(node.id)")
                    .modelNodeMeasured("model-node-tags-corrupt-\(node.id)", probe: layoutProbe)
            } else if tagEditor.tags.isEmpty {
                Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.162")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("model-node-tags-empty")
                    .modelNodeMeasured("model-node-tags-empty-\(node.id)", probe: layoutProbe)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tagEditor.tags, id: \.self) { tag in
                        HStack(spacing: 8) {
                            Text(tag).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(workflowText(legacyLanguage, "consistency.copy.removeNamed", arguments: ["name": tag]), systemImage: "xmark") { remove(tag) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
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
                TextField(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.163"), text: $tagEditor.draft)
                    .textFieldStyle(WorkbenchGlassTextFieldStyle())
                    .disabled(!tagEditor.isEditable)
                    .accessibilityIdentifier("model-node-tag-draft-\(node.id)")
                    .onSubmit(addDraft)
                    .modelNodeMeasured("model-node-tag-draft-\(node.id)", probe: layoutProbe)
                Button(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.164"), action: addDraft)
                    .buttonStyle(WorkbenchGlassButtonStyle())
                    .disabled(!tagEditor.isEditable)
                    .accessibilityIdentifier("model-node-tag-add-\(node.id)")
                    .modelNodeMeasured("model-node-tag-add-\(node.id)", probe: layoutProbe)
            }
            if let error = tagEditor.errorMessage {
                WorkbenchIssueText(raw: error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("model-node-tag-error-\(node.id)")
            }
        }
    }

    private var operationsSection: some View {
        ModelNodeSection(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.165"), identifier: "operations") {
            if displayNode.operations.isEmpty {
                Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.166")).foregroundStyle(.secondary)
            }
            ForEach(displayNode.operations) { operation in
                VStack(alignment: .leading, spacing: 10) {
                    Text(operation.title).font(.headline)
                    Text(operation.summary).foregroundStyle(.secondary)
                    ModelNodePortGroup(title: consistencyText(legacyLanguage, "copy.input"), isInput: true, ports: operation.inputs,
                                       emptyText: workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.167"))
                        .modelNodeMeasured("model-node-ports-\(node.id)-\(operation.id)-inputs", probe: layoutProbe)
                    ModelNodePortGroup(title: consistencyText(legacyLanguage, "copy.output"), isInput: false, ports: operation.outputs,
                                       emptyText: workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.168"))
                        .modelNodeMeasured("model-node-ports-\(node.id)-\(operation.id)-outputs", probe: layoutProbe)
                    Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.169"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("model-node-operation-\(node.id)-\(operation.id)")
            }
        }
    }

    private var parametersSection: some View {
        ModelNodeSection(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.170"), identifier: "parameters") {
            Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.171"))
                .font(.caption).foregroundStyle(.secondary)
            let parameters = displayNode.operations.flatMap(\.parameters)
            if parameters.isEmpty {
                Text(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.172")).foregroundStyle(.secondary)
            }
            ForEach(displayNode.operations) { operation in
                if !operation.parameters.isEmpty {
                    Text(operation.title).font(.headline).padding(.top, 4)
                    ForEach(operation.parameters) { parameter in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(parameter.title).font(.callout.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(ModelNodeUILocalization.usesRegistry(node) ? ModelNodeUILocalization.owned("请求参数", language: legacyLanguage) : parameter.isAdjustable ? workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.173") : workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.174"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.175"), value: parameter.defaultValue)
                            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.176"), value: parameter.acceptedValues)
                            ModelNodeMetadataRow(workflowText(legacyLanguage, "consistency.legacy.ModelNodeViews.177"), value: parameter.detail)
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
        tagEditor.addDraft(using: onTagsChange)
    }

    private func remove(_ tag: String) {
        tagEditor.remove(tag, using: onTagsChange)
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
    var isEditable: Bool

    init(tagState: ModelNodeTagReadState) {
        switch tagState {
        case .missing:
            tags = []
            isEditable = true
        case .valid(let tags):
            self.tags = tags
            isEditable = true
        case .corrupt:
            tags = []
            isEditable = false
        }
    }

    mutating func acceptAddition(tags: [String]) {
        self.tags = tags
        draft = ""
        errorMessage = nil
    }

    mutating func acceptRemoval(tags: [String]) {
        self.tags = tags
        errorMessage = nil
    }

    mutating func reject(_ error: String) {
        errorMessage = error
    }

    mutating func applyIncomingReadState(_ state: ModelNodeTagReadState) {
        guard state == .corrupt else { return }
        isEditable = false
    }

    func proposedAddition() -> ModelNodeTagProposal {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .failure("请输入标签内容。") }
        guard !tags.contains(candidate) else { return .failure("这个标签已经存在。") }
        return .success(tags + [candidate])
    }

    mutating func addDraft(using persist: ([String]) -> String?) {
        guard isEditable else { return }
        switch proposedAddition() {
        case .failure(let message):
            reject(message)
        case .success(let proposed):
            if let error = persist(proposed) {
                reject(error)
            } else {
                acceptAddition(tags: proposed)
            }
        }
    }

    mutating func remove(_ tag: String, using persist: ([String]) -> String?) {
        guard isEditable else { return }
        let proposed = tags.filter { $0 != tag }
        if let error = persist(proposed) {
            reject(error)
        } else {
            acceptRemoval(tags: proposed)
        }
    }
}

private struct ModelNodeListRow: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

    let node: ModelNodeDescriptor
    private var displayNode: ModelNodeDescriptor { ModelNodeUILocalization.display(node, language: legacyLanguage) }
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(displayNode.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(displayNode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ModelSpecificationFields(descriptor: node, font: .caption)
            Text(ModelNodeUILocalization.availability(node.availability, language: legacyLanguage)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
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
    @Environment(\.dLanguageStore) private var legacyLanguage

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
        .workbenchPanel(cornerRadius: 14)
        .accessibilityIdentifier("model-node-section-\(identifier)")
    }
}

private struct ModelNodeMetadataRow: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

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
    @Environment(\.dLanguageStore) private var legacyLanguage

    let title: String
    let isInput: Bool
    private var direction: String { consistencyText(legacyLanguage, isInput ? "copy.input" : "copy.output") }
    let ports: [ModelNodePort]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: isInput ? "arrow.down.circle" : "arrow.up.circle")
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
                    Text(ModelNodeUILocalization.requirement(port.requirement, language: legacyLanguage)).font(.caption2.weight(.semibold))
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

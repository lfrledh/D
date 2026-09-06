import DWorkbench
import SwiftUI

/// Installation is a library operation, separate from a project's inference queue.
public struct ModelLibraryView: View {
    @Bindable private var model: ModelLibraryModel
    private let selectedModelID: ModelID?
    private let canSelect: Bool
    private let onSelect: @MainActor (ModelID) async -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismiss) private var dismiss

    public init(model: ModelLibraryModel, selectedModelID: ModelID? = nil,
                canSelect: Bool = false,
                onSelect: @escaping @MainActor (ModelID) async -> Void = { _ in }) {
        self.model = model
        self.selectedModelID = selectedModelID
        self.canSelect = canSelect
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    storageLocation
                    if let operation = model.globalOperation {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(operation.title).font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if model.snapshot == nil {
                        ProgressView("正在读取模型库…")
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        installedModels
                        catalog
                    }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.hasActiveWork ? "arrow.down.circle" : "checkmark.shield")
                Text(model.hasActiveWork ? "关闭此窗口后，下载和校验仍会继续。" : "只有校验完成且位置可访问的模型才能用于生成。")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 700, idealWidth: 790, maxWidth: 980,
               minHeight: 560, idealHeight: 700, maxHeight: 900)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isChoosingLocation)
        .interactiveDismissDisabled(model.isChoosingLocation)
        .task { await model.refresh() }
        .alert("模型操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("模型库").font(.title2.weight(.semibold))
                Text("安装一次，在你的项目中重复使用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.registerExisting() }
            } label: {
                Label("登记已有模型…", systemImage: "folder.badge.plus")
            }
            .disabled(model.isChoosingLocation || model.globalOperation != nil || model.hasActiveWork)
            .accessibilityIdentifier("model-register-existing")
            .help(model.hasActiveWork ? "请先暂停当前下载或校验，再登记其他模型" : "校验并登记完整的本地模型文件夹")
            doneButton
        }
        .padding(24)
    }

    @ViewBuilder private var doneButton: some View {
        if reduceTransparency {
            closeAction.buttonStyle(.bordered)
        } else {
            closeAction.buttonStyle(.glass)
        }
    }

    private var closeAction: some View {
        Button("完成") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isChoosingLocation)
            .accessibilityIdentifier("model-library-done")
    }

    private var storageLocation: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.title2).foregroundStyle(.secondary).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Text("模型库位置").font(.callout.weight(.semibold))
                if let root = model.rootURL {
                    Text(root.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                } else {
                    Text("先选择存放位置。建议使用空间充足的外置 SSD。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("已有模型可以保留原位置；模型文件不会复制进项目。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.records.contains(where: { $0.storage == .managed }) {
                    Text("可重新定位在同一磁盘卷内移动的原模型库；跨盘搬迁尚未支持。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.canChooseRoot, model.hasActiveWork {
                    Text("暂停下载并等待校验结束后，可以更换模型库位置。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.isInUse {
                    Text("项目中的任务正在使用模型，结束后可以更换模型库位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(model.rootURL == nil ? "选择位置…" : "更换或重新授权…") {
                Task { await model.chooseRoot() }
            }
            .disabled(!model.canChooseRoot)
            .accessibilityIdentifier("model-library-location")
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var installedModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的模型").font(.headline)
                Text("\(model.records.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.activityCount > 0 {
                    Text("\(model.activityCount) 项安装操作进行中")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.records.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "cube.transparent").font(.title2).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("还没有登记或安装的模型").font(.callout)
                        Text("从下面的已验证模型开始，或登记你已下载的文件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(model.records) { record in
                    ModelInstallationRow(model: model, record: record,
                        selected: record.id == selectedModelID, canSelect: canSelect,
                        onSelect: onSelect)
                }
            }
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已验证的模型").font(.headline)
            ForEach(model.catalog) { entry in
                ModelCatalogCard(model: model, entry: entry)
            }
        }
    }
}

private struct ModelInstallationRow: View {
    @Bindable var model: ModelLibraryModel
    let record: ModelRecord
    let selected: Bool
    let canSelect: Bool
    let onSelect: @MainActor (ModelID) async -> Void

    private var isWorking: Bool {
        switch record.state {
        case .queued, .downloading, .pausing, .verifying, .publishing: true
        default: false
        }
    }

    private var canChangeLocation: Bool {
        canModifyRecord && (record.storage == .external || model.canChooseRoot)
    }

    private var canModifyRecord: Bool {
        !model.hasActiveWork && record.activeLeaseCount == 0 && model.pendingActions[record.id] == nil
            && model.globalOperation == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.availability == .available ? "cube" : "externaldrive.badge.exclamationmark")
                    .font(.title2).foregroundStyle(.secondary)
                    .frame(width: 30).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.entry(for: record)?.title ?? record.catalogID)
                            .font(.callout.weight(.semibold)).lineLimit(1)
                        if selected {
                            Label("当前项目", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.tint)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(model.status(for: record))
                            .foregroundStyle(record.state == .failed || record.availability != .available ? .orange : .secondary)
                            .accessibilityIdentifier("model-status-\(record.id)")
                        Text("·")
                        Text(record.storage == .managed ? "D 管理" : "保留原位置")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                rowActions
            }
            transferProgress
            if record.activeLeaseCount > 0 {
                Label("正在被 \(record.activeLeaseCount) 个任务使用；结束前不能移除或重新定位。", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = record.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let directory = record.directory, record.storage == .external || record.state == .installed {
                Text(directory.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var transferProgress: some View {
        switch record.state {
        case .downloading, .paused, .pausing, .queued:
            if record.storage == .external {
                Text("本地文件保持原位；继续后会重新检查完整性。")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(Double(record.downloadedBytes), Double(record.totalBytes)),
                                 total: max(Double(record.totalBytes), 1))
                        .accessibilityLabel("模型下载进度")
                        .accessibilityIdentifier("model-download-progress-\(record.id)")
                    Text("\(ModelLibraryModel.formatBytes(record.downloadedBytes)) / \(ModelLibraryModel.formatBytes(record.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .verifying, .publishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(record.state == .verifying ? "检查每个文件的完整性，完成后才可用于生成。" : "正在安全保存安装结果…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var rowActions: some View {
        HStack(spacing: 10) {
            primaryAction
            Menu {
                if record.storage == .managed, record.state == .paused || record.state == .failed {
                    Button("从头重新下载…") { Task { await model.restart(record.id) } }
                        .disabled(!canModifyRecord)
                }
                Button(record.storage == .managed ? "重新定位模型库…" : "重新定位或授权…") {
                    Task { await model.relink(record.id) }
                }
                    .disabled(!canChangeLocation)
                    .accessibilityIdentifier("model-relink-\(record.id)")
                Divider()
                Button(record.storage == .managed ? "移除模型或下载文件…" : "取消登记…", role: .destructive) {
                    Task { await model.remove(record.id) }
                }
                .disabled(!canModifyRecord)
                .accessibilityIdentifier("model-remove-\(record.id)")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("模型操作")
            .accessibilityIdentifier("model-actions-\(record.id)")
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if model.pendingActions[record.id] != nil {
            ProgressView().controlSize(.small)
        } else if record.availability != .available, !isWorking {
            Button(record.storage == .managed ? "连接模型库…" : "重新定位…") { Task { await model.relink(record.id) } }
                .disabled(!canChangeLocation)
                .accessibilityIdentifier("model-reconnect-\(record.id)")
        } else {
            switch record.state {
            case .queued, .downloading, .verifying:
                Button(record.state == .verifying ? "暂停校验" : "暂停") { Task { await model.pause(record.id) } }
                    .accessibilityIdentifier("model-pause-\(record.id)")
            case .paused:
                Button(record.storage == .external ? "继续校验" : "继续下载") { Task { await model.resume(record.id) } }
                    .disabled(model.hasActiveWork || model.globalOperation != nil)
                    .accessibilityIdentifier("model-resume-\(record.id)")
            case .failed:
                if record.storage == .managed {
                    Button("重试") { Task { await model.retry(record.id) } }
                        .disabled(model.hasActiveWork || model.globalOperation != nil)
                        .accessibilityIdentifier("model-retry-\(record.id)")
                } else {
                    Button("重新校验") { Task { await model.retry(record.id) } }
                        .disabled(model.hasActiveWork || model.globalOperation != nil)
                        .accessibilityIdentifier("model-retry-\(record.id)")
                }
            case .installed:
                if canSelect {
                    Button(selected ? "已选用" : "用于当前项目") {
                        Task { await onSelect(record.id) }
                    }
                    .disabled(selected || !model.canUse(record))
                    .accessibilityIdentifier("model-use-\(record.id)")
                }
            case .registered, .pausing, .publishing:
                EmptyView()
            }
        }
    }
}

private struct ModelCatalogCard: View {
    @Bindable var model: ModelLibraryModel
    let entry: ModelCatalogEntry
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var alreadyManaged: Bool {
        model.records.contains { $0.catalogID == entry.id && $0.storage == .managed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title).font(.headline)
                    Text(entry.modelSpec).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if reduceTransparency {
                    installButton.buttonStyle(.borderedProminent)
                } else {
                    installButton.buttonStyle(.glassProminent)
                }
            }
            HStack(spacing: 22) {
                specification("下载", value: ModelLibraryModel.formatBytes(entry.totalBytes))
                specification("尺寸", value: "\(entry.imageProfile.width) × \(entry.imageProfile.height)")
                specification("步数", value: "\(entry.imageProfile.steps)")
                specification("Guidance", value: entry.imageProfile.guidanceScale.formatted())
                Spacer()
            }
            Text(entry.memoryGuidance).font(.caption).foregroundStyle(.secondary)
            if model.rootURL == nil {
                Text("选择模型库位置后即可安装，也可以直接登记已有模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("来源与版本") {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = URL(string: "https://huggingface.co/\(entry.repository)/tree/\(entry.revision)") {
                        Link(entry.repository, destination: url).font(.caption)
                    }
                    Text("固定版本：\(entry.revision)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(entry.files.count) 个文件；下载完成后逐个校验，再登记为可用模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }
            .font(.caption)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var installButton: some View {
        Button {
            Task { await model.install(catalogID: entry.id) }
        } label: {
            Label(alreadyManaged ? "已加入模型库" : "安装", systemImage: alreadyManaged ? "checkmark" : "arrow.down")
                .padding(.horizontal, 6)
        }
        .disabled(alreadyManaged || model.rootURL == nil || model.globalOperation != nil || model.hasActiveWork || model.pendingCatalogIDs.contains(entry.id))
        .accessibilityIdentifier("model-install-\(entry.id)")
    }

    private func specification(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

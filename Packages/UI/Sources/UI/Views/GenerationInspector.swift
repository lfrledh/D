import DInference
import DWorkbench
import SwiftUI

struct GenerationInspector: View {
    @Bindable var model: WorkbenchModel
    var library: ModelLibraryModel? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var promptFocused: Bool

    private var selectedLibraryRecord: ModelRecord? {
        guard let id = model.selectedModelID else { return nil }
        return library?.records.first { $0.id == id }
    }

    private var displayedModelStatus: String {
        guard let library else { return model.modelStatus }
        if let record = selectedLibraryRecord { return library.status(for: record) }
        if model.selectedModelID != nil, library.snapshot != nil {
            return "这份模型已不在库中，请重新选择。作品和生成记录会保留。"
        }
        return "从模型库中选择已完成校验的模型。"
    }

    private var hasAvailableSelection: Bool {
        guard let library else { return true }
        guard let record = selectedLibraryRecord else { return false }
        return library.canUse(record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("创作").font(.title2.weight(.semibold))
                    Text("让你的想法成形")
                        .font(.callout).foregroundStyle(.secondary)
                }

                modelSection
                Divider()
                promptSection
                seedSection
                fixedSettings

                if let job = model.selectedJob, case .image(let image) = job.request.input {
                    Divider()
                    savedConditions(job: job, image: image)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generateButton
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(.background)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("模型", systemImage: "cube.transparent")
            if let name = model.modelName {
                Text(name).font(.callout.weight(.medium)).textSelection(.enabled)
            } else {
                Text("选择已安装的模型").font(.callout.weight(.medium))
            }
            Text(displayedModelStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-status")
            Button {
                if let library { library.isPresented = true }
                else { Task { await model.registerModel() } }
            } label: {
                Label(library != nil ? "从模型库选择…" : (model.modelName == nil ? "选择模型文件夹…" : "更换或重新授权…"),
                      systemImage: library != nil ? "cube.transparent" : "folder.badge.plus")
            }
            .accessibilityIdentifier(library != nil ? "choose-project-model" : "register-model")
            .disabled(library == nil && model.isBusy)
            .help(library != nil ? "安装、登记并选择当前项目使用的模型" : "选择本地 FLUX.2 Klein 4B q8 模型文件夹")
            if let library, library.hasActiveWork {
                Label("模型库中有 \(library.activityCount) 项安装操作进行中", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let library, library.failedCount > 0 {
                Label("模型库中有未完成的操作，请打开检查。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("画面描述", systemImage: "text.alignleft")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 145)
                    .focused($promptFocused)
                    .accessibilityLabel("画面描述")
                    .accessibilityIdentifier("prompt-editor")
                if model.prompt.isEmpty {
                    Text("描述主体、环境、光线与风格…")
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.top, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(promptFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            Text("编辑草稿不会改变已经排队的任务。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("随机种子", systemImage: "dice")
                Spacer()
                Toggle("随机", isOn: $model.randomSeed)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("random-seed")
            }
            if model.randomSeed {
                Text("每次生成使用新的 seed，并随作品保存。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("0", text: $model.seedText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .accessibilityLabel("固定 seed")
                    .accessibilityIdentifier("seed-field")
                Text("使用相同 seed 和生成条件可以再次生成。0 也是有效值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fixedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("生成规格", systemImage: "slider.horizontal.3")
            HStack(spacing: 0) {
                settingValue("尺寸", value: "\(model.imageProfile.width) × \(model.imageProfile.height)")
                Spacer()
                settingValue("步数", value: "\(model.imageProfile.steps)")
                Spacer()
                settingValue("Guidance", value: model.imageProfile.guidanceScale.formatted())
            }
            Text("当前模型使用这一组已验证的固定规格。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var generateButton: some View {
        if reduceTransparency {
            generateAction.buttonStyle(.borderedProminent)
        } else {
            generateAction.buttonStyle(.glassProminent)
        }
    }

    private var generateAction: some View {
        Button {
            Task { await model.generate() }
        } label: {
            Label(model.isBusy ? "加入生成队列" : "生成图片", systemImage: "sparkles")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .controlSize(.large)
        .disabled(!model.canGenerate || !hasAvailableSelection)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("generate")
        .help("生成并自动保存作品（⌘ Return）")
    }

    private func savedConditions(job: ProjectJob, image: ImageRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("所选作品", systemImage: "info.circle")
            Text(image.prompt).font(.caption).lineLimit(5).textSelection(.enabled)
            LabeledContent("Seed", value: String(image.seed))
                .font(.caption).monospacedDigit().textSelection(.enabled)
            LabeledContent("生成时间", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            Button {
                Task { await model.copySettings(from: job.id) }
            } label: {
                Label("使用这些生成条件", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("copy-settings-inspector")
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleOnly)
    }

    private func settingValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

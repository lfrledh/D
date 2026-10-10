import DWorkbench
import SwiftUI

struct ChatToolsPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let chooseSearchCredential: (ChatSearchProvider) -> Void
    let openArtifact: (ChatArtifactContent) -> Void
    let wording: (String, String) -> String
    @State private var tool = "web"
    @State private var showAllHistory = false
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var left = "0"
    @State private var right = "0"
    @State private var arithmetic = ChatDeterministicTools.ArithmeticOperator.add
    @State private var from = ChatDeterministicTools.UnitChoice.meters
    @State private var to = ChatDeterministicTools.UnitChoice.centimeters
    @State private var instant = "2026-01-01T00:00:00Z"
    @State private var zone = "Asia/Tokyo"
    @State private var columns = ""
    @State private var csvID: UUID?
    @State private var issue: String?
    @State private var pythonInputs: Set<UUID> = []
    @State private var pythonCode = """
    import statistics
    from d_result import publish
    values = [10, 20, 30]
    print("Mean:", statistics.mean(values))
    publish("summary.csv", "csv", "count,mean\\n3,20\\n")
    publish("chart.svg", "svg", '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect x="20" y="20" width="40" height="80" fill="steelblue"/><rect x="80" y="40" width="40" height="60" fill="orange"/></svg>')
    """

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Picker(wording("Task", "要做什么"), selection: $tool) {
                    Text(wording("Web search", "联网搜索")).tag("web")
                    Text(wording("Calculator", "计算器")).tag("calculator")
                    Text(wording("Units", "单位换算")).tag("units")
                    Text(wording("Time zones", "时区换算")).tag("time")
                    Text(wording("CSV statistics", "CSV统计")).tag("csv")
                    Text(wording("Python analysis", "Python 分析")).tag("python")
                    Text(wording("External tools (MCP)", "外部工具连接（MCP）")).tag("mcp")
                }.pickerStyle(.menu).accessibilityIdentifier("chat-tool-kind")
                if tool != "mcp" { toolInput }
                RetainedContentHost(content: ScrollView {
                    ChatMCPPanel(chat: chat, session: session, wording: wording).padding(.vertical, 4)
                }.environment(\.dLanguageStore, language).environment(\.chatDisplayPreferences, preferences)
                    .preferredColorScheme(colorScheme)
                    .foregroundStyle(preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor, preferences.resolvedAppearance.palette(for: colorScheme).secondaryColor)
                    .tint(preferences.resolvedAppearance.palette(for: colorScheme).accentColor).disabled(tool != "mcp"),
                    visible: tool == "mcp", identifier: "chat-mcp-task")
                    .frame(height: tool == "mcp" ? 440 : 0).clipped()
                    .allowsHitTesting(tool == "mcp").accessibilityHidden(tool != "mcp")
                Divider()
                Text(wording("Task status and results", "任务状态与结果")).font(.headline)
                Toggle(wording("Show history for all tasks", "查看所有工具记录"), isOn: $showAllHistory)
                if (session.toolActivities ?? []).filter({ showAllHistory || family($0.request) == tool }).isEmpty {
                    Text(wording("No records for this task.", "这项任务暂无记录。")).font(.caption).foregroundStyle(.secondary)
                }
                if chat.isToolRunning {
                    Button(wording("Stop tool", "停止工具")) { Task { await chat.cancelTool() } }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.toolActivities ?? []).filter { showAllHistory || family($0.request) == tool }.reversed()) { activity in
                    DisclosureGroup(taskTitle(activity.request) + " · " + status(activity.status)) {
                        DisclosureGroup(wording("Inputs and technical details", "输入与技术详情")) {
                            Text(activity.request.identifier).font(.caption.monospaced()).textSelection(.enabled)
                            Text(requestText(activity.request)).font(.caption).textSelection(.enabled)
                        }
                        if activity.request.hasTransientResult, activity.status == .completed {
                            if let preview = chat.searchResponse(activityID: activity.id, sessionID: session.id) {
                                Text(wording("Search summaries only. Read a page to obtain source text.", "以下是搜索摘要；读取网页后才获得正文。"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if preview.rejectedCount > 0 {
                                    Text(wording("Skipped \(preview.rejectedCount) invalid or unsafe results.", "已拒绝 \(preview.rejectedCount) 条格式错误或不安全的结果。"))
                                }
                                if preview.results.isEmpty {
                                    Text(preview.allRejected
                                         ? wording("All returned results were rejected.", "返回结果全部被拒绝。")
                                         : wording("No results.", "没有结果。"))
                                }
                                ForEach(Array(preview.results.enumerated()), id: \.offset) { _, result in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.subheadline).textSelection(.enabled)
                                        Text(result.url.absoluteString).font(.caption).textSelection(.enabled)
                                        Text(result.snippet).font(.caption).textSelection(.enabled)
                                        let unavailable = pageReadIssue(result.url)
                                        Button(wording("Read page", "读取网页正文")) { run(.pageRead(result.url)) }
                                            .disabled(chat.isToolRunning || session.webOptions?.allowed != true || unavailable != nil)
                                        if let unavailable {
                                            Text(unavailable).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } else {
                                Text(wording("Temporary search summaries are no longer available. Search again explicitly if needed.", "临时搜索摘要已不可用；需要时请重新搜索，不会自动重试。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let json = activity.resultJSON {
                            if case .python = activity.request, activity.status == .completed,
                               let result = try? JSONDecoder().decode(ChatPythonResult.self, from: Data(json.utf8)) {
                                ForEach(Array(result.outputs.enumerated()), id: \.offset) { index, output in
                                    Button(wording("Open artifact: ", "打开成果：") + output.name) {
                                        Task { @MainActor in
                                            do {
                                                let content = try await chat.artifactFromPython(activity.id, outputIndex: index, sessionID: session.id)
                                                guard chat.state.selectedSessionID == session.id else { return }
                                                openArtifact(content); issue = nil
                                            } catch { issue = error.localizedDescription }
                                        }
                                    }
                                }
                            }
                            if case .webSearch = activity.request, let hits = try? JSONDecoder().decode([ChatWebSearchHit].self, from: Data(json.utf8)) {
                                ForEach(hits, id: \.pageID) { hit in
                                    Button(hit.title + " · " + wording("Read page", "读取正文")) { run(.webRead(hit)) }
                                        .disabled(chat.isToolRunning || session.webOptions?.allowed != true)
                                }
                            } else {
                                Text(String(json.prefix(8_192))).font(.caption.monospaced()).textSelection(.enabled)
                                if json.count > 8_192 {
                                    Text(wording("Preview shows the first 8,192 characters. The complete saved result is used when adopted.", "预览显示前8,192字符；采用时使用完整已保存结果。")).font(.caption).foregroundStyle(.secondary)
                                }
                                Button(wording("Add full result to next message", "将完整结果加入下条消息")) {
                                    Task { do { try await chat.attachToolResult(activity.id, sessionID: session.id); issue = nil } catch { issue = error.localizedDescription } }
                                }
                            }
                        }
                        if let failure = activity.issue { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
            }.padding(.top, 6)
        }
    }
    private func family(_ request: ChatToolRequest) -> String {
        switch request {
        case .calculator: "calculator"; case .units: "units"; case .time: "time"; case .csv: "csv"
        case .python: "python"; case .mcp: "mcp"
        case .webSearch, .webRead, .providerSearch, .pageRead: "web"
        }
    }
    private func taskTitle(_ request: ChatToolRequest) -> String {
        switch request {
        case .calculator: wording("Calculation", "计算")
        case .units: wording("Unit conversion", "单位换算")
        case .time: wording("Time conversion", "时区换算")
        case .csv: wording("CSV statistics", "CSV 统计")
        case .python: wording("Python analysis", "Python 分析")
        case .mcp(_, let name, _): wording("External tool: ", "外部工具：") + name
        case .webSearch, .providerSearch: wording("Web search", "联网搜索")
        case .webRead, .pageRead: wording("Read web page", "读取网页")
        }
    }
    @ViewBuilder private var toolInput: some View {
        switch tool {
        case "mcp": EmptyView()
        case "python":
            Text(wording("Runs only in bundled CPython/WASI. No network, host files, credentials, pip or native extensions. Selected text/CSV files are copied read-only. 30s guest time, 256 MiB linear memory; results are saved only when you choose.",
                         "仅在内置 CPython/WASI 中执行，不能访问网络、宿主文件或凭据，不支持 pip 和原生扩展。选中的文字/CSV以只读副本提供；guest 时限30秒、线性内存256 MiB。成果由您决定是否保存。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(session.attachments.filter { $0.reference.kind == .text }) { item in
                Toggle(item.name, isOn: Binding(get: { pythonInputs.contains(item.id) }, set: { selected in
                    if selected { pythonInputs.insert(item.id) } else { pythonInputs.remove(item.id) }
                })).toggleStyle(.checkbox)
            }
            ForEach(Array(selectedPythonInputs.enumerated()), id: \.element.id) { index, item in
                Text("/inputs/input-\(index + 1).csv ← \(item.name)").font(.caption.monospaced()).textSelection(.enabled)
            }
            TextSourcesQuestionEditor(value: pythonCode, editEpoch: 0, isEditable: !chat.isToolRunning,
                accessibilityIdentifier: "chat-python-code", onEdit: { pythonCode = $0 }).frame(height: 180)
            Text(wording("Use csv/statistics from Python’s standard library. d_result.publish(name, kind, text) offers a .txt/.csv/.svg artifact; it never writes to your project by itself.",
                         "可使用标准库 csv/statistics。d_result.publish(name, kind, text) 提交 .txt/.csv/.svg 成果，不会自行写入项目。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(wording("Run selected code", "运行这段代码")) {
                run(.python(code: pythonCode, inputs: selectedPythonInputs.map(\.reference)))
            }.disabled(chat.isToolRunning).accessibilityIdentifier("chat-python-run")
        case "web":
            Picker(wording("Search service", "搜索服务"), selection: Binding(get: { session.webOptions?.provider }, set: { value in
                updateWeb { $0.provider = value; $0.allowed = false; $0.automaticSearch = false }
            })) {
                Text(wording("Choose a service", "选择服务")).tag(nil as ChatSearchProvider?)
                Text("Brave Search").tag(Optional(ChatSearchProvider.brave))
                Text(wording("Bocha Web Search", "博查 Web Search")).tag(Optional(ChatSearchProvider.bocha))
            }
            if let provider = session.webOptions?.provider {
                Text(chat.configuredSearchProviders.contains(provider)
                    ? wording("Local credential connected", "已关联本地凭据")
                    : wording("Credential not configured", "尚未配置凭据")).font(.caption).foregroundStyle(.secondary)
                Button(wording("Manage credentials in Settings…", "前往设置管理凭据…")) { chooseSearchCredential(provider) }
            }

            Toggle(wording("Allow this conversation to search online", "允许本会话联网搜索"), isOn: Binding(get: { session.webOptions?.allowed == true }, set: { value in
                updateWeb { $0.allowed = value; if !value { $0.automaticSearch = false } }
            })).disabled(session.webOptions?.provider == nil && session.webOptions?.allowed != true)
            Toggle(wording("Before sending, search the visible question and read the first result", "发送前搜索当前问题并读取首项正文"), isOn: Binding(get: { session.webOptions?.automaticSearch == true }, set: { value in updateWeb { $0.automaticSearch = value } }))
                .disabled(session.webOptions?.allowed != true || session.webOptions?.provider == nil)
            Text(wording("Only the visible query goes to the selected search service. Reading a result contacts that website without your API key. History and attachments are not uploaded. Search summaries stay temporarily in memory; adopted page text is saved separately and the final answer uses your local model.", "仅将可见搜索词发送给所选服务；读取结果时另行访问该网站，不携带 API 密钥。不上传历史与附件。搜索摘要仅临时驻留内存；采用的网页正文独立保存，最终回答仍由本地模型生成。"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(wording("Search query", "搜索词"), text: $query)
            Button(wording("Search", "搜索")) {
                if let provider = session.webOptions?.provider { run(.providerSearch(query: query, provider: provider)) }
            }.disabled(chat.isToolRunning || session.webOptions?.allowed != true || query.isEmpty || session.webOptions?.provider == nil)
        case "calculator":
            HStack {
                TextField(wording("Left number", "左数"), text: $left)
                Picker(wording("Operation", "运算"), selection: $arithmetic) {
                    Text("+").tag(ChatDeterministicTools.ArithmeticOperator.add)
                    Text("−").tag(ChatDeterministicTools.ArithmeticOperator.subtract)
                    Text("×").tag(ChatDeterministicTools.ArithmeticOperator.multiply)
                    Text("÷").tag(ChatDeterministicTools.ArithmeticOperator.divide)
                }
                TextField(wording("Right number", "右数"), text: $right)
            }
            Text(wording("Division can be rounded; the result records this explicitly.", "除法可能舍入，结果会明确记录。" )).font(.caption)
            Button(wording("Calculate", "计算")) { run(.calculator(.init(arithmetic, left: left, right: right))) }.disabled(chat.isToolRunning)
        case "units":
            TextField(wording("Value", "数值"), text: $left)
            HStack {
                Picker(wording("From", "从"), selection: $from) { ForEach(units, id: \.rawValue) { Text($0.rawValue).tag($0) } }
                Picker(wording("To", "到"), selection: $to) { ForEach(units.filter { $0.family == from.family }, id: \.rawValue) { Text($0.rawValue).tag($0) } }
            }
            Button(wording("Convert", "换算")) {
                guard let number = Double(left) else { issue = wording("Enter a number.", "请输入数值。"); return }
                run(.units(.init(value: number, from: from, to: to)))
            }.disabled(chat.isToolRunning)
        case "time":
            TextField("ISO 8601 · 2026-01-01T00:00:00Z", text: $instant)
            TextField("IANA · Asia/Tokyo", text: $zone)
            Button(wording("Convert from UTC", "从UTC换算")) { run(.time(.init(instant: instant, sourceTimeZone: "UTC", targetTimeZone: zone))) }.disabled(chat.isToolRunning)
        default:
            Picker(wording("Selected text attachment (CSV)", "选择文字附件（CSV）"), selection: $csvID) {
                Text(wording("Select", "请选择")).tag(nil as UUID?)
                ForEach(session.attachments.filter { $0.reference.kind == .text }) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField(wording("Numeric columns, comma separated", "数值列名，用逗号分隔"), text: $columns)
            Button(wording("Analyze full CSV", "统计完整CSV")) {
                guard let item = session.attachments.first(where: { $0.id == csvID }) else { return }
                run(.csv(item.reference, columns: columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
            }.disabled(chat.isToolRunning || csvID == nil)
        }
    }
    private var units: [ChatDeterministicTools.UnitChoice] { [.meters, .centimeters, .kilometers, .feet, .miles, .grams, .kilograms, .pounds, .celsius, .fahrenheit, .kelvin, .seconds, .minutes, .hours] }
    private var selectedPythonInputs: [ChatAttachment] {
        session.attachments.filter { $0.reference.kind == .text && pythonInputs.contains($0.id) }
    }
    private func run(_ request: ChatToolRequest) {
        Task { do { try await chat.executeTool(request, sessionID: session.id); issue = nil } catch { issue = error.localizedDescription } }
    }
    private func updateWeb(_ update: (inout ChatWebOptions) -> Void) {
        do { var options = session.webOptions ?? .init(); update(&options); try chat.setWebOptions(options, sessionID: session.id); issue = nil } catch { issue = error.localizedDescription }
    }
    private func requestText(_ value: ChatToolRequest) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private func status(_ value: ChatToolActivity.Status) -> String {
        switch value { case .running: wording("Running", "运行中"); case .completed: wording("Completed", "已完成"); case .failed: wording("Failed", "失败"); case .cancelled: wording("Stopped", "已停止"); case .interrupted: wording("Interrupted", "已中断") }
    }
    private func pageReadIssue(_ url: URL) -> String? {
        do { try ChatWebPageClient.validateReadURL(url); return nil }
        catch { return ChatErrorText.display(error.localizedDescription, language: language) }
    }

}

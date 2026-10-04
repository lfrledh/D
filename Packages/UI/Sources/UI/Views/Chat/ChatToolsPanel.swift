import DWorkbench
import SwiftUI

struct ChatToolsPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let wording: (String, String) -> String
    @State private var tool = "web"
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

    var body: some View {
        DisclosureGroup(wording("Search and tools", "搜索与工具")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(wording("Tool", "工具"), selection: $tool) {
                    Text(wording("Wikipedia", "维基百科搜索")).tag("web")
                    Text(wording("Calculator", "计算器")).tag("calculator")
                    Text(wording("Units", "单位换算")).tag("units")
                    Text(wording("Time zones", "时区换算")).tag("time")
                    Text(wording("CSV statistics", "CSV统计")).tag("csv")
                }.pickerStyle(.segmented)
                toolInput
                if chat.isToolRunning {
                    Button(wording("Stop tool", "停止工具")) { Task { await chat.cancelTool() } }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.toolActivities ?? []).reversed()) { activity in
                    DisclosureGroup(activity.request.identifier + " · " + status(activity.status)) {
                        Text(requestText(activity.request)).font(.caption).textSelection(.enabled)
                        if let json = activity.resultJSON {
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
    @ViewBuilder private var toolInput: some View {
        switch tool {
        case "web":
            Toggle(wording("Allow this conversation to search online", "允许本会话联网搜索"), isOn: Binding(get: { session.webOptions?.allowed == true }, set: { value in
                updateWeb { $0.allowed = value; if !value { $0.automaticSearch = false } }
            }))
            Toggle(wording("Before sending, search the visible question and read the first result", "发送前搜索当前问题并读取首项正文"), isOn: Binding(get: { session.webOptions?.automaticSearch == true }, set: { value in updateWeb { $0.automaticSearch = value } }))
                .disabled(session.webOptions?.allowed != true)
            Text(wording("Only the question or selected page ID is sent to Wikipedia. Previous messages and attachments are not uploaded. Long questions over 512 UTF-8 bytes are rejected without truncation.", "仅向维基百科发送当前问题或所选页面编号，不上传历史与附件。超过512个UTF-8字节的查询会明确拒绝，不截断。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(wording("Search language", "搜索语言"), selection: Binding(get: { session.webOptions?.language ?? .zh }, set: { value in updateWeb { $0.language = value } })) {
                ForEach(ChatWebLanguage.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }
            TextField(wording("Search query", "搜索词"), text: $query)
            Button(wording("Search", "搜索")) { run(.webSearch(query: query, language: session.webOptions?.language ?? .zh)) }
                .disabled(chat.isToolRunning || session.webOptions?.allowed != true || query.isEmpty)
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
}

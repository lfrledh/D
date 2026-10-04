import DWorkbench
import SwiftUI

/// A per-conversation explicit client, not automatic model tool execution.
struct ChatMCPPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let wording: (String, String) -> String
    @State private var endpoint = ""
    @State private var tool = ""
    @State private var arguments = "{}"
    @State private var permission = false
    @State private var issue: String?
    private var ownsConnection: Bool { chat.mcpSessionID == session.id }
    var body: some View {
        DisclosureGroup("MCP") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://…/mcp", text: $endpoint).textFieldStyle(.roundedBorder)
                    .disabled(chat.mcpSessionID != nil)
                Text(wording("Streamable HTTP. HTTPS or local loopback only. No login, credential URLs, subprocesses or automatic reconnect. Server-side actions may continue after local cancellation.",
                             "Streamable HTTP；仅HTTPS或本机回环。不接管登录、凭据网址、子进程，也不自动重连。停止本地请求不保证服务端动作撤回。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(wording("Allow this connection and send the explicitly entered arguments", "允许本次连接和发送明确填写的参数"), isOn: $permission)
                    .onChange(of: permission) { _, value in if !value && ownsConnection { Task { await chat.disconnectMCP() } } }
                HStack {
                    Button(wording("Connect and list tools", "连接并列出工具")) {
                        let captured = endpoint
                        Task { do { try await chat.connectMCP(endpoint: captured, sessionID: session.id, permitted: permission); issue = nil } catch { issue = error.localizedDescription } }
                    }.disabled(!permission || chat.mcpSessionID != nil || chat.isToolRunning)
                    if ownsConnection {
                        Button(wording("Stop / disconnect", "停止／断开")) { Task { await chat.disconnectMCP() } }
                    }
                }
                if let owner = chat.mcpSessionID, owner != session.id {
                    Text(wording("Another conversation owns the connection. Return there to disconnect it.", "连接属于另一个会话，请回到该会话断开。" )).font(.caption)
                }
                if ownsConnection {
                    Text(String(describing: chat.mcpStatus)).font(.caption).textSelection(.enabled)
                    Picker(wording("Tool", "工具"), selection: $tool) {
                        Text(wording("Select a tool", "选择工具")).tag("")
                        ForEach(chat.mcpTools, id: \.name) { Text($0.title ?? $0.name).tag($0.name) }
                    }
                    if let selected = chat.mcpTools.first(where: { $0.name == tool }) {
                        if let description = selected.description { Text(description).font(.caption).textSelection(.enabled) }
                        DisclosureGroup(wording("Declared arguments (untrusted server data)", "参数声明（服务端资料）")) {
                            Text(selected.inputSchemaJSON).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        TextEditor(text: $arguments).font(.body.monospaced()).frame(minHeight: 100, maxHeight: 180)
                            .accessibilityLabel(wording("MCP arguments JSON", "MCP参数JSON"))
                        Button(wording("Send these arguments and call tool", "发送上述参数并调用")) {
                            guard case .connected(let address) = chat.mcpStatus else { return }
                            let request = ChatToolRequest.mcp(endpoint: address, tool: selected.name, argumentsJSON: arguments)
                            Task { do { try await chat.executeTool(request, sessionID: session.id, mcpPermission: permission); issue = nil } catch { issue = error.localizedDescription } }
                        }.disabled(!permission || chat.isToolRunning || chat.isMCPConnecting)
                    }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text(wording("Results appear in Search and tools below; they enter the model context only when explicitly adopted.", "结果记录在下方搜索与工具历史中；只有明确采用后才进入模型上下文。" )).font(.caption)
            }.padding(.top, 6)
        }.onAppear { endpoint = session.mcpEndpoint ?? "" }
    }
}

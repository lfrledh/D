import DWorkbench
import SwiftUI

/// A per-conversation explicit client, not automatic model tool execution.
struct ChatMCPPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    @Environment(\.dLanguageStore) private var copyLanguage
    let wording: (String, String) -> String
    @State private var endpoint = ""
    @State private var tool = ""
    @State private var arguments = "{}"
    @State private var permission = false
    @State private var issue: String?
    private var ownsConnection: Bool { chat.mcpSessionID == session.id }
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(workflowText(copyLanguage, "chat.mCPPanel.externalToolsMCP")).font(.headline)
                TextField("https://…/mcp", text: $endpoint).textFieldStyle(WorkbenchGlassTextFieldStyle())
                    .disabled(chat.mcpSessionID != nil)
                Text(workflowText(copyLanguage, "chat.mCPPanel.streamableHTTPHTTPSOrLocalLoopbackOnlyNoLoginCredential"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(workflowText(copyLanguage, "chat.mCPPanel.allowThisConnectionAndSendTheExplicitlyEnteredArguments"), isOn: $permission)
                    .onChange(of: permission) { _, value in if !value && ownsConnection { Task { await chat.disconnectMCP() } } }
                HStack {
                    Button(workflowText(copyLanguage, "chat.mCPPanel.connectAndListTools")) {
                        let captured = endpoint
                        Task { do { try await chat.connectMCP(endpoint: captured, sessionID: session.id, permitted: permission); issue = nil } catch { issue = error.localizedDescription } }
                    }.disabled(!permission || chat.mcpSessionID != nil || chat.isToolRunning)
                    if ownsConnection {
                        Button(workflowText(copyLanguage, "chat.mCPPanel.stopDisconnect")) { Task { await chat.disconnectMCP() } }
                    }
                }
                if let owner = chat.mcpSessionID, owner != session.id {
                    Text(workflowText(copyLanguage, "chat.MCPPanel.AnotherconversationownstheconnectionReturnthereto")).font(.caption)
                }
                if ownsConnection {
                    Text(chatConnectionText(chat.mcpStatus, language: language)).font(.caption).textSelection(.enabled)
                    WorkbenchPicker(workflowText(copyLanguage, "baseline02.library.kind.tool"), selection: $tool) {
                        WorkbenchChoice(workflowText(copyLanguage, "chat.mCPPanel.selectATool"), value:"")
                        WorkbenchChoiceForEach(chat.mcpTools, id: \.name) { WorkbenchChoice($0.title ?? $0.name, value:$0.name) }
                    }
                    if let selected = chat.mcpTools.first(where: { $0.name == tool }) {
                        if let description = selected.description { Text(description).font(.caption).textSelection(.enabled) }
                        DisclosureGroup(workflowText(copyLanguage, "chat.mCPPanel.declaredArgumentsUntrustedServerData")) {
                            Text(selected.inputSchemaJSON).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        TextEditor(text: $arguments).font(.body.monospaced()).frame(minHeight: 100, maxHeight: 180).workbenchInputSurface()
                            .accessibilityLabel(workflowText(copyLanguage, "chat.mCPPanel.mCPArgumentsJSON"))
                        Button(workflowText(copyLanguage, "chat.mCPPanel.sendTheseArgumentsAndCallTool")) {
                            guard case .connected(let address) = chat.mcpStatus else { return }
                            let request = ChatToolRequest.mcp(endpoint: address, tool: selected.name, argumentsJSON: arguments)
                            Task { do { try await chat.executeTool(request, sessionID: session.id, mcpPermission: permission); issue = nil } catch { issue = error.localizedDescription } }
                        }.disabled(!permission || chat.isToolRunning || chat.isMCPConnecting)
                    }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text(workflowText(copyLanguage, "chat.MCPPanel.Resultsappearintaskresultsbelowtheyenter")).font(.caption)
            }.padding(.top, 6)
        }.onAppear { endpoint = session.mcpEndpoint ?? "" }
    }
}

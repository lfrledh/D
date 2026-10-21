import DWorkbench
import SwiftUI

struct ChatToolsPanel: View {
    @Environment(\.dLanguageStore) private var language
    let chat: ChatController
    let session: ChatSession
    let chooseSearchCredential: (ChatSearchProvider) -> Void
    let openArtifact: (ChatArtifactContent) -> Void
    @Environment(\.dLanguageStore) private var copyLanguage
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
                WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.task"), selection: $tool) {
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.webSearch"), value:"web")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.calculator"), value:"calculator")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.units"), value:"units")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.timeZones"), value:"time")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.cSVStatistics"), value:"csv")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.pythonAnalysis"), value:"python")
                    WorkbenchChoice(workflowText(copyLanguage, "chat.mCPPanel.externalToolsMCP"), value:"mcp")
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
                Text(workflowText(copyLanguage, "chat.toolsPanel.taskStatusAndResults")).font(.headline)
                Toggle(workflowText(copyLanguage, "chat.toolsPanel.showHistoryForAllTasks"), isOn: $showAllHistory)
                if (session.toolActivities ?? []).filter({ showAllHistory || family($0.request) == tool }).isEmpty {
                    Text(workflowText(copyLanguage, "chat.toolsPanel.noRecordsForThisTask")).font(.caption).foregroundStyle(.secondary)
                }
                if chat.isToolRunning {
                    Button(workflowText(copyLanguage, "chat.toolsPanel.stopTool")) { Task { await chat.cancelTool() } }
                }
                if let issue { Text(ChatErrorText.display(issue, language: language)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                ForEach((session.toolActivities ?? []).filter { showAllHistory || family($0.request) == tool }.reversed()) { activity in
                    DisclosureGroup(taskTitle(activity.request) + " · " + status(activity.status)) {
                        DisclosureGroup(workflowText(copyLanguage, "chat.toolsPanel.inputsAndTechnicalDetails")) {
                            Text(activity.request.identifier).font(.caption.monospaced()).textSelection(.enabled)
                            Text(requestText(activity.request)).font(.caption).textSelection(.enabled)
                        }
                        if activity.request.hasTransientResult, activity.status == .completed {
                            if let preview = chat.searchResponse(activityID: activity.id, sessionID: session.id) {
                                Text(workflowText(copyLanguage, "chat.toolsPanel.searchSummariesOnlyReadAPageToObtainSourceText"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if preview.rejectedCount > 0 {
                                    Text(workflowText(copyLanguage, "chat.toolsPanel.skippedUnsafeResults", arguments: ["count": String(preview.rejectedCount)]))
                                }
                                if preview.results.isEmpty {
                                    Text(preview.allRejected
                                         ? workflowText(copyLanguage, "chat.toolsPanel.allReturnedResultsWereRejected")
                                         : workflowText(copyLanguage, "chat.toolsPanel.noResults"))
                                }
                                ForEach(Array(preview.results.enumerated()), id: \.offset) { _, result in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.subheadline).textSelection(.enabled)
                                        Text(result.url.absoluteString).font(.caption).textSelection(.enabled)
                                        Text(result.snippet).font(.caption).textSelection(.enabled)
                                        let unavailable = pageReadIssue(result.url)
                                        Button(workflowText(copyLanguage, "chat.toolsPanel.readPage")) { run(.pageRead(result.url)) }
                                            .disabled(chat.isToolRunning || session.webOptions?.allowed != true || unavailable != nil)
                                        if let unavailable {
                                            Text(unavailable).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } else {
                                Text(workflowText(copyLanguage, "chat.toolsPanel.temporarySearchSummariesAreNoLongerAvailableSearchAgainExplicitly"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let json = activity.resultJSON {
                            if case .python = activity.request, activity.status == .completed,
                               let result = try? JSONDecoder().decode(ChatPythonResult.self, from: Data(json.utf8)) {
                                ForEach(Array(result.outputs.enumerated()), id: \.offset) { index, output in
                                    Button(workflowText(copyLanguage, "chat.toolsPanel.openArtifact") + output.name) {
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
                                    Button(hit.title + " · " + workflowText(copyLanguage, "chat.toolsPanel.readPage2")) { run(.webRead(hit)) }
                                        .disabled(chat.isToolRunning || session.webOptions?.allowed != true)
                                }
                            } else {
                                if case .calculator = activity.request,
                                   let result = try? JSONDecoder().decode(ChatDeterministicTools.ArithmeticResult.self, from: Data(json.utf8)) {
                                    Text(workflowText(copyLanguage, "chat.toolsPanel.result") + result.decimal).font(.headline).textSelection(.enabled)
                                    if result.mayBeRounded { Text(workflowText(copyLanguage, "chat.toolsPanel.thisResultMayBeRounded")).font(.caption) }
                                } else {
                                    Text(workflowText(copyLanguage, "chat.toolsPanel.savedResultExpandToInspectBeforeAdopting")).font(.caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup(workflowText(copyLanguage, "chat.toolsPanel.resultDetailsOriginalData")) {
                                    Text(String(json.prefix(8_192))).font(.caption.monospaced()).textSelection(.enabled)
                                    if json.count > 8_192 {
                                        Text(workflowText(copyLanguage, "chat.toolsPanel.previewShowsTheFirst8192CharactersTheCompleteSaved")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button(workflowText(copyLanguage, "chat.toolsPanel.addFullResultToNextMessage")) {
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
        case .calculator: workflowText(copyLanguage, "chat.toolsPanel.calculation")
        case .units: workflowText(copyLanguage, "chat.toolsPanel.unitConversion")
        case .time: workflowText(copyLanguage, "chat.toolsPanel.timeConversion")
        case .csv: workflowText(copyLanguage, "chat.toolsPanel.cSVStatistics2")
        case .python: workflowText(copyLanguage, "chat.toolsPanel.pythonAnalysis")
        case .mcp(_, let name, _): workflowText(copyLanguage, "chat.toolsPanel.externalTool") + name
        case .webSearch, .providerSearch: workflowText(copyLanguage, "chat.toolsPanel.webSearch")
        case .webRead, .pageRead: workflowText(copyLanguage, "chat.toolsPanel.readWebPage")
        }
    }
    @ViewBuilder private var toolInput: some View {
        switch tool {
        case "mcp": EmptyView()
        case "python":
            Text(workflowText(copyLanguage, "chat.toolsPanel.runsOnlyInBundledCPythonWASINoNetworkHostFiles"))
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
                accessibilityIdentifier: "chat-python-code", onEdit: { pythonCode = $0 }).frame(height: 180).workbenchInputSurface()
            Text(workflowText(copyLanguage, "chat.toolsPanel.useCsvStatisticsFromPythonSStandardLibraryDResult"))
                .font(.caption).foregroundStyle(.secondary)
            Button(workflowText(copyLanguage, "chat.toolsPanel.runSelectedCode")) {
                run(.python(code: pythonCode, inputs: selectedPythonInputs.map(\.reference)))
            }.disabled(chat.isToolRunning).accessibilityIdentifier("chat-python-run")
        case "web":
            WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.searchService"), selection: Binding(get: { session.webOptions?.provider }, set: { value in
                updateWeb { $0.provider = value; $0.allowed = false; $0.automaticSearch = false }
            })) {
                WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.chooseAService"), value:nil as ChatSearchProvider?)
                WorkbenchChoice("Brave Search", value:Optional(ChatSearchProvider.brave))
                WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.bochaWebSearch"), value:Optional(ChatSearchProvider.bocha))
            }
            if let provider = session.webOptions?.provider {
                Text(chat.configuredSearchProviders.contains(provider)
                    ? workflowText(copyLanguage, "chat.organization.credentials.connected")
                    : workflowText(copyLanguage, "chat.toolsPanel.credentialNotConfigured")).font(.caption).foregroundStyle(.secondary)
                Button(workflowText(copyLanguage, "chat.toolsPanel.manageCredentialsInSettings")) { chooseSearchCredential(provider) }
            }

            Toggle(workflowText(copyLanguage, "chat.toolsPanel.allowThisConversationToSearchOnline"), isOn: Binding(get: { session.webOptions?.allowed == true }, set: { value in
                updateWeb { $0.allowed = value; if !value { $0.automaticSearch = false } }
            })).disabled(session.webOptions?.provider == nil && session.webOptions?.allowed != true)
            Toggle(workflowText(copyLanguage, "chat.toolsPanel.beforeSendingSearchTheVisibleQuestionAndReadTheFirst"), isOn: Binding(get: { session.webOptions?.automaticSearch == true }, set: { value in updateWeb { $0.automaticSearch = value } }))
                .disabled(session.webOptions?.allowed != true || session.webOptions?.provider == nil)
            Text(workflowText(copyLanguage, "chat.toolsPanel.onlyTheVisibleQueryGoesToTheSelectedSearchService"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(workflowText(copyLanguage, "chat.toolsPanel.searchQuery"), text: $query)
            Button(workflowText(copyLanguage, "baseline02.library.searchNow")) {
                if let provider = session.webOptions?.provider { run(.providerSearch(query: query, provider: provider)) }
            }.disabled(chat.isToolRunning || session.webOptions?.allowed != true || query.isEmpty || session.webOptions?.provider == nil)
        case "calculator":
            HStack {
                TextField(workflowText(copyLanguage, "chat.toolsPanel.leftNumber"), text: $left)
                WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.operation"), selection: $arithmetic) {
                    WorkbenchChoice("+", value:ChatDeterministicTools.ArithmeticOperator.add)
                    WorkbenchChoice("−", value:ChatDeterministicTools.ArithmeticOperator.subtract)
                    WorkbenchChoice("×", value:ChatDeterministicTools.ArithmeticOperator.multiply)
                    WorkbenchChoice("÷", value:ChatDeterministicTools.ArithmeticOperator.divide)
                }
                TextField(workflowText(copyLanguage, "chat.toolsPanel.rightNumber"), text: $right)
            }
            Text(workflowText(copyLanguage, "chat.ToolsPanel.Divisioncanberoundedtheresultrecordsthis")).font(.caption)
            Button(workflowText(copyLanguage, "chat.toolsPanel.calculate")) { run(.calculator(.init(arithmetic, left: left, right: right))) }.disabled(chat.isToolRunning)
        case "units":
            TextField(workflowText(copyLanguage, "chat.toolsPanel.value"), text: $left)
            HStack {
                WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.from"), selection: $from) { WorkbenchChoiceForEach(units, id: \.rawValue) { WorkbenchChoice($0.rawValue, value:$0) } }
                WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.to"), selection: $to) { WorkbenchChoiceForEach(units.filter { $0.family == from.family }, id: \.rawValue) { WorkbenchChoice($0.rawValue, value:$0) } }
            }
            Button(workflowText(copyLanguage, "chat.toolsPanel.convert")) {
                guard let number = Double(left) else { issue = workflowText(copyLanguage, "chat.toolsPanel.enterANumber"); return }
                run(.units(.init(value: number, from: from, to: to)))
            }.disabled(chat.isToolRunning)
        case "time":
            TextField("ISO 8601 · 2026-01-01T00:00:00Z", text: $instant)
            TextField("IANA · Asia/Tokyo", text: $zone)
            Button(workflowText(copyLanguage, "chat.toolsPanel.convertFromUTC")) { run(.time(.init(instant: instant, sourceTimeZone: "UTC", targetTimeZone: zone))) }.disabled(chat.isToolRunning)
        default:
            WorkbenchPicker(workflowText(copyLanguage, "chat.toolsPanel.selectedTextAttachmentCSV"), selection: $csvID) {
                WorkbenchChoice(workflowText(copyLanguage, "chat.toolsPanel.select"), value:nil as UUID?)
                WorkbenchChoiceForEach(session.attachments.filter { $0.reference.kind == .text }) { WorkbenchChoice($0.name, value:Optional($0.id)) }
            }
            TextField(workflowText(copyLanguage, "chat.toolsPanel.numericColumnsCommaSeparated"), text: $columns)
            Button(workflowText(copyLanguage, "chat.toolsPanel.analyzeFullCSV")) {
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
        switch value { case .running: workflowText(copyLanguage, "workflow.stepStatus.running"); case .completed: workflowText(copyLanguage, "workflow.stepStatus.completed"); case .failed: workflowText(copyLanguage, "workflow.stepStatus.failed"); case .cancelled: workflowText(copyLanguage, "chat.toolsPanel.stopped"); case .interrupted: workflowText(copyLanguage, "workflow.stepStatus.interrupted") }
    }
    private func pageReadIssue(_ url: URL) -> String? {
        do { try ChatWebPageClient.validateReadURL(url); return nil }
        catch { return ChatErrorText.display(error.localizedDescription, language: language) }
    }

}

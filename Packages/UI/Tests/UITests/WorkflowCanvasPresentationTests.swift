import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasPresentationTests {
    @Test
    func publicCanvasTypeIsVisibleWithoutInventingAController() {
        let type: WorkflowCanvasView.Type = WorkflowCanvasView.self
        #expect(String(describing: type) == "WorkflowCanvasView")
    }

    @Test
    func panelPolicyFitsBothLibrariesAtMinimumWindowWithoutOuterScroll() {
        for width: CGFloat in [760, 860, 1_100, 1_420] {
            #expect(!WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: width))
        }
        let widths = WorkbenchSidebarLayout.widths(available: WorkbenchSidebarLayout.minimumWindowWidth)
        #expect(widths.leading + widths.trailing + WorkflowCanvasLayoutPolicy.canvasMinimumWidth + 56 <= WorkbenchSidebarLayout.minimumWindowWidth)
        #expect(WorkflowCanvasLayoutPolicy.visiblePanels(width: 1080, library: true, inspector: true, preferLibrary: false) == (true, true))
    }

    @Test
    func zoomIsBoundedAndFallbackLayoutIsDeterministic() {
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(0.1) == 0.1)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(0) == 0.05)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(1.25) == 1.25)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(4) == 4)

        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 0) == CGPoint(x: 170, y: 130))
        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 3) == CGPoint(x: 1_070, y: 130))
        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 4) == CGPoint(x: 170, y: 380))
    }

    @Test
    func graphGeometryPreservesStoredCoordinatesAndMakesNegativeLayoutsReachable() {
        let first = WorkflowNode(id: UUID(), operationID: "d.text.input", title: "第一")
        let second = WorkflowNode(id: UUID(), operationID: "d.text.confirm", title: "第二")
        let graph = WorkflowGraph(
            nodes: [first, second],
            layout: [
                WorkflowLayout(nodeID: first.id, x: -240, y: -80),
                WorkflowLayout(nodeID: second.id, x: 420, y: 260)
            ]
        )

        let geometry = WorkflowGraphGeometry(graph: graph)
        #expect(geometry.rawPosition(first.id) == CGPoint(x: -240, y: -80))
        #expect(geometry.rawPosition(second.id) == CGPoint(x: 420, y: 260))
        #expect(geometry.displayPosition(first.id).x >= 150)
        #expect(geometry.displayPosition(first.id).y - WorkflowNodePortLayout.titleHeight / 2 >= 24)
        #expect(geometry.displayPosition(second.id).x > geometry.displayPosition(first.id).x)
        #expect(geometry.size.width >= 1_400)
        #expect(geometry.size.height >= 900)
    }

    @Test
    func graphGeometryUsesTheSameRegistryAsTheCards() throws {
        let definition = WorkflowOperationDefinition(id: "fixture.manyPorts", title: "Ports", detail: "",
            inputs: (0..<20).map { .init("i\($0)", "Input \($0)", kinds: [.text]) },
            outputs: [.init("output", "Output", kinds: [.text])])
        let registry = try WorkflowRegistry(operations: [.init(definition: definition,
            execute: { _, _ in throw WorkflowIssue("Geometry must not execute") })])
        let node = definition.makeNode()
        let graph = WorkflowGraph(nodes: [node], layout: [.init(nodeID: node.id, x: 0, y: -20)])
        let geometry = WorkflowGraphGeometry(graph: graph, registry: registry)
        let top = geometry.displayPosition(node.id).y - WorkflowNodePortLayout.titleHeight / 2
        #expect(top >= 24)
        #expect(top + CGFloat(WorkflowLayout.cardHeightBudget(inputs: 20, outputs: 1)) <= geometry.size.height - 24)
        #expect(geometry.rawPosition(node.id) == CGPoint(x: 0, y: -20))
    }

    @Test
    func graphGeometryFallsBackOnlyForNodesWithoutStoredLayout() {
        let laidOut = WorkflowNode(id: UUID(), operationID: "d.text.input", title: "固定")
        let fallback = WorkflowNode(id: UUID(), operationID: "d.text.confirm", title: "回退")
        let graph = WorkflowGraph(
            nodes: [laidOut, fallback],
            layout: [WorkflowLayout(nodeID: laidOut.id, x: 500, y: 600)]
        )

        let geometry = WorkflowGraphGeometry(graph: graph)
        #expect(geometry.rawPosition(laidOut.id) == CGPoint(x: 500, y: 600))
        #expect(geometry.rawPosition(fallback.id)
                == WorkflowCanvasLayoutPolicy.fallbackPosition(index: 1))
    }

    @Test(arguments: ["empty", "small", "negative", "far", "preview", "many-ports"])
    func reframedGraphPreservesRawExtentsAndPositions(kind: String) throws {
        let definition = WorkflowOperationDefinition(id: "fixture.extent", title: "Extent", detail: "",
            inputs: (0..<(kind == "many-ports" ? 20 : 1)).map { .init("i\($0)", "Input", kinds: [.text]) },
            outputs: [.init("output", "Output", kinds: [.text])])
        let registry = try WorkflowRegistry(operations: [.init(definition: definition,
            execute: { _, _ in throw WorkflowIssue("Geometry must not execute") })])
        let first = definition.makeNode(), second = definition.makeNode()
        let graph = kind == "empty" ? WorkflowGraph() : WorkflowGraph(nodes: [first, second], layout: [
            .init(nodeID: first.id, x: kind == "negative" ? -2500 : 0, y: kind == "negative" ? -1800 : 0),
            .init(nodeID: second.id, x: kind == "far" ? 8000 : 300, y: kind == "far" ? 6000 : 200)])
        let preview: [UUID: CGPoint] = kind == "preview" ? [first.id: .init(x: -4000, y: 9000)] : [:]
        let source = WorkflowGraphGeometry(graph: graph, registry: registry, previewPositions: preview)
        for translation in [CGSize.zero, source.translation, CGSize(width: -900, height: -500), CGSize(width: 2400, height: 1700)] {
            for minimum in [CGSize.zero, CGSize(width: 12000, height: 9000)] {
                let actual = source.reframed(translation: translation, minimumSize: minimum)
                let reference = WorkflowGraphGeometry(graph: graph, registry: registry, previewPositions: preview,
                    translation: translation, minimumSize: minimum)
                #expect(actual.size == reference.size && actual.translation == reference.translation)
                #expect(actual.graph == graph)
                for node in graph.nodes {
                    #expect(actual.rawPosition(node.id) == reference.rawPosition(node.id))
                    #expect(actual.displayPosition(node.id) == reference.displayPosition(node.id))
                }
            }
        }
    }

    @Test
    func portDescriptionsExposeKindsAndRequirementWithoutUsingCopyAsSchema() {
        let required = WorkflowPortDefinition("input", "输入", kinds: [.text, .image])
        let optional = WorkflowPortDefinition("reference", "参考", kinds: [.image], required: false)

        #expect(WorkflowCanvasPresentation.portDetail(required) == "文字/图像 · 必选")
        #expect(WorkflowCanvasPresentation.portDetail(optional) == "图像 · 可选")
        #expect(WorkflowCanvasPresentation.kind(.images) == "图像集合")
        #expect(WorkflowCanvasPresentation.kind(.receipt) == "导出回执")
        let universal = WorkflowPortDefinition("input", "材料", kinds: WorkflowDataKind.allCases)
        #expect(WorkflowCanvasPresentation.portSummary(universal, language: nil) == "所有已支持类型 · 必选")
        #expect(WorkflowCanvasPresentation.portDetail(universal).contains("图像集合"))
        let several = WorkflowPortDefinition("input", "材料", kinds: [.text, .image, .video, .audio], required: false)
        #expect(WorkflowCanvasPresentation.portSummary(several, language: nil) == "4 种类型 · 可选")
        #expect(WorkflowCanvasPresentation.portSummary(required, language: nil) == "文字/图像 · 必选")
    }

    @Test(arguments: ["zh-Hans", "en"])
    func connectionLabelsResolvePublishedToolPortNames(locale: String) throws {
        let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
        let body = try WorkflowControlFormSupport.makeBody(name: "工具", inputs: [WorkflowRecordField("input", .text)],
            passthrough: "input", outputName: "output")
        let first = WorkflowToolDefinition(id: UUID(), version: 1, name: "固定工具", graph: body,
            registration: .init(purpose: "Purpose", inputLabels: ["input": "用户提示一"], outputLabels: ["output": "成品一"]))
        var second = first; second.version = 2
        second.registration = .init(purpose: "Purpose", inputLabels: ["input": "用户提示二"], outputLabels: ["output": "成品二"])
        let tools = [second, first]
        for (tool, inputName, outputName, excluded) in [(first, "用户提示一", "成品一", "成品二"), (second, "用户提示二", "成品二", "成品一")] {
            var invoke = try #require(WorkflowRegistry.standard.operation("d.control.invoke")).definition.makeNode()
            let draft = try WorkflowControlFormSupport.selecting(tool: tool, in: .init(node: invoke))
            invoke.control = draft.control; invoke.dataConfiguration = draft.dataConfiguration
            let definition = try #require(WorkflowRegistry.standard.definition(for: invoke, tools: tools))
            #expect(definition.inputs.first?.title == inputName && definition.outputs.first?.title == outputName)
            #expect(WorkflowCanvasPresentation.portTitle(operationID: invoke.operationID, port: definition.inputs[0], input: true, language: language) == inputName)
            #expect(WorkflowCanvasPresentation.portTitle(operationID: invoke.operationID, port: definition.outputs[0], input: false, language: language) == outputName)
            let target = try #require(WorkflowRegistry.standard.operation("d.value.return")).definition.makeNode()
            let graph = WorkflowGraph(nodes: [invoke, target])
            let outgoing = WorkflowConnection(sourceNode: invoke.id, sourcePort: "output", targetNode: target.id, targetPort: "input")
            let incoming = WorkflowConnection(sourceNode: target.id, sourcePort: "output", targetNode: invoke.id, targetPort: "input")
            let outgoingTitle = WorkflowConnectionPresentation.title(outgoing, graph: graph, registry: .standard, tools: tools, language: language)
            let incomingTitle = WorkflowConnectionPresentation.title(incoming, graph: graph, registry: .standard, tools: tools, language: language)
            #expect(outgoingTitle.contains(outputName) && !outgoingTitle.contains(excluded))
            #expect(incomingTitle.contains(inputName))
        }
    }

    @Test
    func controllerPlanStringsRemainOpaqueAndInOrder() {
        let opaque = [
            "执行：节点 A → 不应拆词",
            "reuse??? {\"unknown\":true}",
            "等待确认\n保留换行"
        ]
        let displayed = WorkflowCanvasPresentation.planLines(opaque)
        #expect(displayed == opaque)
    }

    @Test
    func ReadOnlyReasonGatesAllMutationsButDoesNotRepresentPreviewState() {
        #expect(WorkflowCanvasPresentation.allowsMutation(readOnlyReason: nil))
        #expect(!WorkflowCanvasPresentation.allowsMutation(readOnlyReason: "未知版本，仅可查看"))
    }

    @Test(arguments: [
        WorkflowStepStatus.waiting,
        .interrupted,
        .saving,
        .partial,
        .failed
    ])
    func recoverableRunStatesOfferResume(status: WorkflowStepStatus) {
        #expect(WorkflowCanvasPresentation.canResume(status))
    }

    @Test(arguments: [
        WorkflowStepStatus.queued,
        .running,
        .completed,
        .cancelling,
        .cancelled,
        .rejected
    ])
    func terminalOrActiveRunStatesDoNotOfferResume(status: WorkflowStepStatus) {
        #expect(!WorkflowCanvasPresentation.canResume(status))
    }

    @Test func connectionInspectionKeepsConcreteCallsAndNeverInventsCurrentOutput() {
        let source = WorkflowNode(operationID: "d.model.language", title: "model")
        let target = WorkflowNode(operationID: "d.value.return", title: "target")
        let edge = WorkflowConnection(sourceNode: source.id, sourcePort: "output", targetNode: target.id, targetPort: "input")
        let graph = WorkflowGraph(nodes: [source, target], connections: [edge])
        let map = WorkflowNode(operationID: "d.control.map", title: "map")
        let body = WorkflowPlan(graphID: graph.id, graphRevision: graph.revision, steps: [.init(node: target, inputs: [])])
        let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [.init(node: map, inputs: [], kind: .map(body: body, continueOnFailure: true))])
        var run = WorkflowRun(graph: graph, targetNodeID: target.id)
        var first = WorkflowStepRun(node: target, signature: "a"), second = WorkflowStepRun(node: target, signature: "b")
        first.inputs = ["input": .data(.text("first item"))]; second.inputs = ["input": .data(.text("second item"))]
        let records: [WorkflowPlanCallRecord] = [
            .init(address: .init(runID: run.id, path: [.node(map.id), .item("a"), .node(target.id)]), step: first),
            .init(address: .init(runID: run.id, path: [.node(map.id), .item("b"), .node(target.id)]), step: second),
        ]
        run.planCheckpoint = .init(runID: run.id, plan: plan, records: records)
        let values = WorkflowConnectionPresentation.snapshots(edge, graphID: graph.id, runs: [run])
        #expect(values.count == 2)
        #expect(WorkflowConnectionPresentation.snapshots(edge, graphID: UUID(), runs: [run]).isEmpty)
        // Same node IDs in a copied graph are not the original tool body identity.
        var copied = graph; copied.id = UUID()
        #expect(WorkflowConnectionPresentation.snapshots(edge, graphID: copied.id, runs: [run]).isEmpty)
        #expect(values.map(\.value) == [first.inputs["input"]!, second.inputs["input"]!])
        #expect(values.map(\.address) == records.map { $0.address.path })
        #expect(Set(values.map(\.id)).count == 2)
        #expect(WorkflowConnectionPresentation.configuredValue(source: source) == nil)
        var differentPort = edge; differentPort.targetPort = "missing"
        #expect(WorkflowConnectionPresentation.snapshots(differentPort, graphID: graph.id, runs: [run]).isEmpty)
        var literal = WorkflowNode(operationID: "d.value.input", title: "value")
        literal.dataConfiguration = .init(value: .text("new setting"))
        #expect(WorkflowConnectionPresentation.configuredValue(source: literal) == .data(.text("new setting")))
        #expect(values[0].value == .data(.text("first item")))
    }

    @Test
    func connectionIdentityDisplaysOnlyStableSourceInformation() throws {
        let source = try #require(UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))
        let connection = WorkflowConnection(sourceNode: source, sourcePort: "output",
                                            targetNode: UUID(), targetPort: "input")
        #expect(WorkflowCanvasPresentation.connectionIdentity(connection) == "12345678.output")
    }
}

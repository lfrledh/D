import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasDragTests {
    @Test
    func dragMathUsesScreenScaleAndPreservesNegativeStoredCoordinates() {
        let original = CGPoint(x: -240, y: -80)
        for zoom: CGFloat in [0.5, 1, 1.8] {
            let point = WorkflowCanvasDragGeometry.rawPosition(
                original: original,
                screenTranslation: CGSize(width: 90 * zoom, height: -40 * zoom),
                zoom: zoom
            )
            #expect(point == CGPoint(x: -150, y: -120))
        }
    }

    @Test
    func transientPreviewMovesCardAndConnectedEndpointWithoutChangingGraph() {
        let source = WorkflowNode(operationID: "d.text.input", title: "source")
        let target = WorkflowNode(operationID: "d.text.confirm", title: "target")
        let edge = WorkflowConnection(sourceNode: source.id, targetNode: target.id)
        let graph = WorkflowGraph(
            nodes: [source, target],
            connections: [edge],
            layout: [
                .init(nodeID: source.id, x: -240, y: -80),
                .init(nodeID: target.id, x: 420, y: 260),
            ]
        )
        let unchanged = graph
        let base = WorkflowGraphGeometry(graph: graph)
        let previewPosition = CGPoint(x: -100, y: 40)
        let preview = WorkflowGraphGeometry(
            graph: graph,
            previewPositions: [source.id: previewPosition],
            translation: base.translation
        )
        let before = WorkflowConnectionGeometry.endpoints(
            for: edge, geometry: base, portCenters: [:]
        )
        let during = WorkflowConnectionGeometry.endpoints(
            for: edge, geometry: preview, portCenters: [:]
        )

        #expect(graph == unchanged)
        #expect(preview.rawPosition(source.id) == previewPosition)
        #expect(during.start.x - before.start.x == 140)
        #expect(during.start.y - before.start.y == 120)
        #expect(during.end == before.end)
        #expect(preview.translation == base.translation)
    }

    @Test
    func idleOriginRaisesForSameGraphExpansionAndNeverShrinksAfterDrag() {
        let node = WorkflowNode(operationID: "d.model.language", title: "model")
        let graphID = UUID(), revision = UUID()
        let collapsed = WorkflowGraph(
            id: graphID,
            revision: revision,
            nodes: [node],
            layout: [.init(nodeID: node.id, x: 0, y: 0, collapsed: true)]
        )
        var expanded = collapsed
        expanded.layout[0].collapsed = false
        let retainedAfterDrag = WorkflowGraphGeometry(graph: collapsed).translation
        let expandedNatural = WorkflowGraphGeometry(graph: expanded).translation

        let active = WorkflowCanvasOriginPolicy.resolved(
            natural: expandedNatural,
            retained: retainedAfterDrag,
            active: retainedAfterDrag
        )
        #expect(active == retainedAfterDrag)

        let reachableIdle = WorkflowCanvasOriginPolicy.resolved(
            natural: expandedNatural,
            retained: retainedAfterDrag,
            active: nil
        )
        #expect(reachableIdle.height >= expandedNatural.height)
        #expect(reachableIdle.height > retainedAfterDrag.height)

        let collapsedAgain = WorkflowCanvasOriginPolicy.resolved(
            natural: WorkflowGraphGeometry(graph: collapsed).translation,
            retained: reachableIdle,
            active: nil
        )
        #expect(collapsedAgain == reachableIdle)
        #expect(collapsed.id == expanded.id && collapsed.revision == expanded.revision)
    }

    @Test
    func measuredPortCentersAttachDifferentPortsToTheirActualDots() {
        let source = WorkflowNode(operationID: "d.model.language", title: "source")
        let target = WorkflowNode(operationID: "d.image.generate", title: "target")
        let edge = WorkflowConnection(
            sourceNode: source.id,
            sourcePort: "raw",
            targetNode: target.id,
            targetPort: "prompt"
        )
        let graph = WorkflowGraph(nodes: [source, target], connections: [edge])
        let geometry = WorkflowGraphGeometry(graph: graph)
        let expectedStart = CGPoint(x: 311, y: 207)
        let expectedEnd = CGPoint(x: 519, y: 333)
        let centers = [
            WorkflowPortIdentity(nodeID: source.id, port: "output", input: false): CGPoint(x: 310, y: 150),
            WorkflowPortIdentity(nodeID: source.id, port: "raw", input: false): expectedStart,
            WorkflowPortIdentity(nodeID: target.id, port: "ref", input: true): CGPoint(x: 520, y: 280),
            WorkflowPortIdentity(nodeID: target.id, port: "prompt", input: true): expectedEnd,
        ]

        let endpoints = WorkflowConnectionGeometry.endpoints(
            for: edge, geometry: geometry, portCenters: centers
        )
        #expect(endpoints.start == expectedStart)
        #expect(endpoints.end == expectedEnd)
    }

    @Test
    func dragScopeRejectsRevisionGraphNodeReadOnlyAndRunTransitions() {
        let node = WorkflowNode(operationID: "d.text.input", title: "node")
        let graph = WorkflowGraph(
            nodes: [node],
            layout: [.init(nodeID: node.id, x: 10, y: 20)]
        )
        let scope = WorkflowCanvasScope(
            rootGraphID: graph.id,
            rootRevision: graph.revision,
            graphID: graph.id,
            bodyPath: []
        )
        let sessionID = UUID()
        var drag = WorkflowCanvasNodeDragState(
            sessionID: sessionID,
            scope: scope,
            nodeID: node.id,
            originalPosition: CGPoint(x: 10, y: 20),
            origin: .zero
        )
        drag.update(screenTranslation: CGSize(width: 30, height: 40), zoom: 1)

        #expect(drag.canCommit(
            currentScope: scope,
            graph: graph,
            currentPosition: CGPoint(x: 10, y: 20),
            readOnly: false,
            isRunning: false
        ))
        var stale = scope
        stale = WorkflowCanvasScope(
            rootGraphID: stale.rootGraphID,
            rootRevision: UUID(),
            graphID: stale.graphID,
            bodyPath: stale.bodyPath
        )
        #expect(!drag.canCommit(currentScope: stale, graph: graph,
            currentPosition: CGPoint(x: 10, y: 20), readOnly: false, isRunning: false))
        #expect(!drag.canCommit(currentScope: scope, graph: WorkflowGraph(),
            currentPosition: CGPoint(x: 10, y: 20), readOnly: false, isRunning: false))
        #expect(!drag.canCommit(currentScope: scope, graph: graph,
            currentPosition: CGPoint(x: 10, y: 20), readOnly: true, isRunning: false))
        #expect(!drag.canCommit(currentScope: scope, graph: graph,
            currentPosition: CGPoint(x: 10, y: 20), readOnly: false, isRunning: true))
        #expect(!drag.canCommit(currentScope: scope, graph: graph,
            currentPosition: CGPoint(x: 11, y: 20), readOnly: false, isRunning: false))

        var active: WorkflowCanvasNodeDragState? = drag
        active = nil
        #expect(active == nil)
        #expect(graph.layout.first?.x == 10)
    }

    @Test
    func invalidatedGestureSessionCannotReanimateAndNextGestureCompletesOnce() throws {
        let node = WorkflowNode(operationID: "d.text.input", title: "node")
        let graph = WorkflowGraph(
            nodes: [node],
            layout: [.init(nodeID: node.id, x: 10, y: 20)]
        )
        let firstScope = WorkflowCanvasScope(
            rootGraphID: graph.id,
            rootRevision: graph.revision,
            graphID: graph.id,
            bodyPath: []
        )
        let changedScope = WorkflowCanvasScope(
            rootGraphID: UUID(),
            rootRevision: UUID(),
            graphID: UUID(),
            bodyPath: []
        )
        var gesture = WorkflowCanvasGestureSessionState()
        var coordinator = WorkflowCanvasNodeDragCoordinator()

        guard case .began(let staleSessionID) = gesture.change() else {
            Issue.record("First callback must begin a gesture session")
            return
        }
        let began1 = coordinator.begin(
            WorkflowCanvasNodeDragState(
                sessionID: staleSessionID,
                scope: firstScope,
                nodeID: node.id,
                originalPosition: CGPoint(x: 10, y: 20),
                origin: .zero
            ),
            screenTranslation: CGSize(width: 5, height: 6),
            zoom: 1
        )
        #expect(began1)

        coordinator.invalidate()
        guard case .changed(let remainingSessionID) = gesture.change() else {
            Issue.record("Remaining callbacks must retain the invalidated session identity")
            return
        }
        #expect(remainingSessionID == staleSessionID)
        let staleUpdated = coordinator.update(
            sessionID: remainingSessionID,
            nodeID: node.id,
            scope: changedScope,
            screenTranslation: CGSize(width: 30, height: 40),
            zoom: 1
        )
        #expect(!staleUpdated)
        let staleEnd = gesture.end()
        let staleEndID = try #require(staleEnd)
        #expect(staleEndID == staleSessionID)
        #expect(coordinator.finish(
            sessionID: staleEndID,
            nodeID: node.id,
            scope: changedScope,
            screenTranslation: CGSize(width: 30, height: 40),
            zoom: 1
        ) == nil)
        #expect(coordinator.active == nil)

        guard case .began(let nextSessionID) = gesture.change() else {
            Issue.record("A true next gesture must begin a new session")
            return
        }
        #expect(nextSessionID != staleSessionID)
        let began2 = coordinator.begin(
            WorkflowCanvasNodeDragState(
                sessionID: nextSessionID,
                scope: changedScope,
                nodeID: node.id,
                originalPosition: CGPoint(x: 10, y: 20),
                origin: .zero
            ),
            screenTranslation: CGSize(width: 1, height: 2),
            zoom: 1
        )
        #expect(began2)
        let nextEnd = gesture.end()
        let nextEndID = try #require(nextEnd)
        let completed = coordinator.finish(
            sessionID: nextEndID,
            nodeID: node.id,
            scope: changedScope,
            screenTranslation: CGSize(width: 50, height: 60),
            zoom: 1
        )
        #expect(completed?.sessionID == nextSessionID)
        #expect(completed?.previewPosition == CGPoint(x: 60, y: 80))
        #expect(coordinator.active == nil)
        #expect(coordinator.finish(
            sessionID: nextEndID,
            nodeID: node.id,
            scope: changedScope,
            screenTranslation: CGSize(width: 50, height: 60),
            zoom: 1
        ) == nil)
    }

    @Test
    func canvasTransferRoundTripsAndRejectsMalformedOrUnboundedStrings() throws {
        let rootGraphID = UUID(), graphID = UUID(), revision = UUID(), nodeID = UUID()
        let values: [WorkflowCanvasTransfer] = [
            .operation(id: "d.image.generate", modelID: nil),
            .operation(id: "d.model.language", modelID: "org/model"),
            .asset(projectID: UUID(), assetID: UUID()),
            .output(rootGraphID: rootGraphID, bodyPath: [], graphID: graphID,
                    revision: revision, nodeID: nodeID, port: "output"),
        ]
        for value in values {
            #expect(try WorkflowCanvasTransfer.decode(value.encoded()) == value)
        }
        #expect(throws: (any Error).self) {
            try WorkflowCanvasTransfer.output(
                rootGraphID: rootGraphID, bodyPath: [], graphID: graphID,
                revision: revision, nodeID: nodeID, port: ""
            ).encoded()
        }
        #expect(throws: (any Error).self) {
            try WorkflowCanvasTransfer.operation(
                id: String(repeating: "x", count: 257), modelID: nil
            ).encoded()
        }
        #expect(throws: (any Error).self) {
            try WorkflowCanvasTransfer.output(
                rootGraphID: rootGraphID,
                bodyPath: Array(
                    repeating: WorkflowCanvasBodyLocation(nodeID: UUID(), slot: "body"),
                    count: 17
                ),
                graphID: graphID,
                revision: revision,
                nodeID: nodeID,
                port: "output"
            ).encoded()
        }
        #expect(throws: (any Error).self) {
            try WorkflowCanvasTransfer.decode(Data(repeating: 0, count: 8 * 1_024 + 1))
        }
        #expect(throws: (any Error).self) {
            try WorkflowCanvasTransfer.decode(Data("not-json".utf8))
        }
    }

    @Test
    func outputTransferRequiresFullBodyScopeAndAcceptsOrdinaryGraphScope() {
        let rootGraphID = UUID(), graphID = UUID(), revision = UUID(), nodeID = UUID()
        let ownerNodeID = UUID()
        let firstPath = [WorkflowBodyLocation(nodeID: ownerNodeID, slot: "then")]
        let clonedPath = [WorkflowBodyLocation(nodeID: ownerNodeID, slot: "otherwise")]
        let firstScope = WorkflowCanvasScope(
            rootGraphID: rootGraphID,
            rootRevision: revision,
            graphID: graphID,
            bodyPath: firstPath
        )
        let clonedScope = WorkflowCanvasScope(
            rootGraphID: rootGraphID,
            rootRevision: revision,
            graphID: graphID,
            bodyPath: clonedPath
        )
        let nested = WorkflowCanvasTransfer.output(
            rootGraphID: rootGraphID,
            bodyPath: firstPath.map(WorkflowCanvasBodyLocation.init),
            graphID: graphID,
            revision: revision,
            nodeID: nodeID,
            port: "output"
        )

        #expect(nested.matchesOutputScope(firstScope))
        #expect(!nested.matchesOutputScope(clonedScope))
        #expect(firstScope.matches(rootGraphID: rootGraphID, rootRevision: revision,
            graphID: graphID, bodyPath: firstPath))
        #expect(!firstScope.matches(rootGraphID: rootGraphID, rootRevision: revision,
            graphID: graphID, bodyPath: clonedPath))

        let ordinaryScope = WorkflowCanvasScope(
            rootGraphID: rootGraphID,
            rootRevision: revision,
            graphID: rootGraphID,
            bodyPath: []
        )
        let ordinary = WorkflowCanvasTransfer.output(
            rootGraphID: rootGraphID,
            bodyPath: [],
            graphID: rootGraphID,
            revision: revision,
            nodeID: nodeID,
            port: "output"
        )
        #expect(ordinary.matchesOutputScope(ordinaryScope))
    }

    @Test
    func connectionPolicyUsesRegistryPortsTypesAndCardinality() throws {
        let sourceDefinition = WorkflowOperationDefinition(
            id: "fixture.source",
            title: "source",
            detail: "",
            inputs: [.init("textIn", "text", kinds: [.text])],
            outputs: [
                .init("text", "text", kinds: [.text]),
                .init("image", "image", kinds: [.image]),
            ]
        )
        let targetDefinition = WorkflowOperationDefinition(
            id: "fixture.target",
            title: "target",
            detail: "",
            inputs: [
                .init("text", "text", kinds: [.text]),
                .init("image", "image", kinds: [.image]),
            ],
            outputs: [.init("textOut", "text", kinds: [.text])]
        )
        let registry = try WorkflowRegistry(operations: [
            .init(definition: sourceDefinition, execute: { _, _ in
                throw WorkflowIssue("must not execute")
            }),
            .init(definition: targetDefinition, execute: { _, _ in
                throw WorkflowIssue("must not execute")
            }),
        ])
        let source = sourceDefinition.makeNode()
        let target = targetDefinition.makeNode()
        var graph = WorkflowGraph(nodes: [source, target])

        #expect(WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "text",
            targetNodeID: target.id, targetPort: "text"
        ))
        #expect(!WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "image",
            targetNodeID: target.id, targetPort: "text"
        ))
        #expect(!WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "missing",
            targetNodeID: target.id, targetPort: "text"
        ))
        #expect(!WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "text",
            targetNodeID: source.id, targetPort: "text"
        ))

        graph.connections = [.init(
            sourceNode: source.id, sourcePort: "text",
            targetNode: target.id, targetPort: "text"
        )]
        #expect(!WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "text",
            targetNodeID: target.id, targetPort: "text"
        ))

        graph.connections = [.init(
            sourceNode: target.id, sourcePort: "textOut",
            targetNode: source.id, targetPort: "textIn"
        )]
        #expect(!WorkflowCanvasConnectionPolicy.canConnect(
            graph: graph, registry: registry, tools: [],
            sourceNodeID: source.id, sourcePort: "text",
            targetNodeID: target.id, targetPort: "text"
        ))
    }
}

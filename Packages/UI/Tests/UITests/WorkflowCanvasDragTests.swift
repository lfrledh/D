import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasDragTests {
    @Test(arguments: [CGFloat(0.02), 0.65, 1, 1.8])
    func wireDrawingBackingIsViewportBoundAndKeepsFarTopology(zoom: CGFloat) throws {
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 640,height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0,y: 0,width: 640,height: 480))
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let document = WireTestDocument(frame: .init(x: 0,y: 0,width: 200_000 * zoom,height: 160_000 * zoom))
        document.bounds = .init(x: 0,y: 0,width: 200_000,height: 160_000)
        scroll.documentView = document
        let wrapper = WorkflowConnectionDrawingView(frame: document.bounds)
        document.addSubview(wrapper)
        let paths = [
            WorkflowConnectionGeometry.curve(from: .init(x: 120,y: 180), to: .init(x: 500,y: 260)),
            WorkflowConnectionGeometry.curve(from: .init(x: 180_000,y: 120_000), to: .init(x: 170_000,y: 121_000))
        ]
        let origin = CGPoint(x: -200,y: -140)
        let strokes = paths.enumerated().map { WorkflowConnectionDrawing.Stroke(path: $0.element, color: .red, selected: $0.offset == 0) }
        wrapper.update(strokes: strokes, origin: origin)
        window.contentView?.layoutSubtreeIfNeeded()
        func verify() throws {
            wrapper.updateViewport()
            let drawer = wrapper.drawing
            try #require(!drawer.isHidden && !drawer.bounds.isEmpty)
            #expect(drawer.bounds.width <= scroll.contentView.bounds.width + 0.01)
            #expect(drawer.bounds.height <= scroll.contentView.bounds.height + 0.01)
            let backing = drawer.convertToBacking(drawer.bounds)
            #expect(backing.width <= scroll.contentView.bounds.width * window.backingScaleFactor + 1)
            #expect(backing.height <= scroll.contentView.bounds.height * window.backingScaleFactor + 1)
            #expect(wrapper.hitTest(.zero) == nil && drawer.hitTest(.zero) == nil)
            #expect(drawer.strokes == strokes && drawer.origin == origin)
            // Paint the actual viewport child and an independent full-path oracle
            // into equally sized contexts. No giant bitmap is created by either.
            let width = Int(ceil(drawer.bounds.width * 2)), height = Int(ceil(drawer.bounds.height * 2))
            let actual = try #require(WorkbenchLocalRenderer.bitmap(width: width,height: height))
            let expected = try #require(WorkbenchLocalRenderer.bitmap(width: width,height: height))
            actual.scaleBy(x: 2,y: 2); expected.scaleBy(x: 2,y: 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: actual, flipped: true)
            drawer.draw(drawer.bounds)
            NSGraphicsContext.restoreGraphicsState()
            expected.clip(to: drawer.bounds)
            expected.scaleBy(x: drawer.bounds.width / drawer.sourceRect.width,
                y: drawer.bounds.height / drawer.sourceRect.height)
            expected.translateBy(x: -drawer.sourceRect.minX-origin.x,y: -drawer.sourceRect.minY-origin.y)
            for stroke in strokes {
                if stroke.selected {
                    expected.addPath(stroke.path.cgPath); expected.setLineWidth(6)
                    expected.setStrokeColor(NSColor(Color.primary.opacity(0.75)).cgColor); expected.strokePath()
                }
                expected.addPath(stroke.path.cgPath); expected.setLineWidth(2.5)
                expected.setStrokeColor(NSColor(stroke.color).cgColor); expected.strokePath()
            }
            let length = actual.bytesPerRow * actual.height
            let a = try #require(actual.data).assumingMemoryBound(to: UInt8.self)
            let b = try #require(expected.data).assumingMemoryBound(to: UInt8.self)
            #expect(UnsafeBufferPointer(start: a,count: length).elementsEqual(UnsafeBufferPointer(start: b,count: length)))
            #expect((0..<length).contains { a[$0] != 0 }, "The comparison must include a visible wire")
        }
        scroll.contentView.scroll(to: .init(x: 200 * zoom,y: 200 * zoom))
        try verify()
        // Move to the distant curve using only native scroll geometry.
        scroll.contentView.scroll(to: .init(x: 179_900 * zoom,y: 119_900 * zoom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try verify()
        wrapper.isHidden = true
        scroll.contentView.scroll(to: .init(x: 179_890 * zoom,y: 119_890 * zoom))
        #expect(wrapper.drawing.isHidden)
        wrapper.isHidden = false
        #expect(!wrapper.drawing.isHidden && !wrapper.drawing.frame.isEmpty)
        try verify()
        wrapper.update(strokes: [], origin: origin)
        #expect(wrapper.drawing.isHidden && wrapper.drawing.frame == .zero)
        wrapper.update(strokes: strokes, origin: origin)
        try verify()
        wrapper.removeFromSuperview()
        #expect(wrapper.drawing.isHidden && wrapper.drawing.frame == .zero)
    }

    @Test func draggedReverseCurveStaysInsideDrawingBounds() {
        let size = CGSize(width: 2400, height: 900)
        let paths = [
            WorkflowConnectionGeometry.curve(from: CGPoint(x: 2000,y: 300), to: CGPoint(x: -1800,y: 500)),
            WorkflowConnectionGeometry.curve(from: CGPoint(x: 4000,y: 1100), to: CGPoint(x: 200,y: -300))
        ]
        let bounds = WorkflowConnectionGeometry.drawingBounds(size: size, paths: paths)
        #expect(bounds.contains(CGRect(origin: .zero, size: size)))
        for path in paths {
            #expect(bounds.contains(path.boundingRect.insetBy(dx: -3, dy: -3)))
        }
        #expect(bounds.minX < -2000 && bounds.maxX > 4000)
        #expect(bounds.minY <= -303 && bounds.maxY >= 1103)
    }

    @Test func isolatedPreviewKeepsGroupZoomCancellationAndCollapsedWireEnds() throws {
        let a = WorkflowNode(operationID: "d.text.input", title: "a")
        let b = WorkflowNode(operationID: "d.text.confirm", title: "b")
        let connection = WorkflowConnection(sourceNode: a.id, sourcePort: "output", targetNode: b.id, targetPort: "input")
        let graph = WorkflowGraph(nodes: [a,b], connections: [connection], layout: [
            .init(nodeID: a.id, x: -30, y: -40), .init(nodeID: b.id, x: 500, y: 80)])
        let scope = WorkflowCanvasScope(rootGraphID: graph.id, rootRevision: graph.revision,
            graphID: graph.id, bodyPath: [], projectID: UUID(), instanceID: UUID())
        let presentation = WorkflowCanvasNodeDragPresentation()
        let id = UUID()
        let initial = [a.id: CGPoint(x: -30,y: -40), b.id: CGPoint(x: 500,y: 80)]
        let drag = WorkflowCanvasNodeDragState(sessionID: id, scope: scope, nodeID: a.id,
            originalPosition: initial[a.id]!, origin: CGSize(width: 180,height: 200),
            originalPositions: initial,
            originalLayouts: Dictionary(uniqueKeysWithValues: graph.layout.map { ($0.nodeID,$0) }))
        #expect(presentation.begin(drag, screenTranslation: .zero, zoom: 0.025))
        #expect(presentation.update(sessionID: id, nodeID: a.id, scope: scope,
            screenTranslation: CGSize(width: -5,height: 10), zoom: 2))
        #expect(presentation.offset == CGSize(width: -200,height: 400), "Use begin zoom even if later presentation zoom changed")
        #expect(presentation.movingNodeIDs == Set([a.id,b.id]))
        let geometry = WorkflowGraphGeometry(graph: graph)
        let originalEnds = WorkflowConnectionGeometry.endpoints(for: connection, geometry: geometry, portCenters: [:])
        let measuredSource = WorkflowPortIdentity(nodeID: a.id, port: "output", input: false)
        let measured = [measuredSource: CGPoint(x: 72,y: 91)]
        let centers = WorkflowConnectionGeometry.movingFallbackCenters(graph: graph, geometry: geometry,
            measured: measured, moving: presentation.movingNodeIDs, offset: presentation.offset)
        let movedEnds = WorkflowConnectionGeometry.endpoints(for: connection, geometry: geometry, portCenters: centers)
        #expect(movedEnds.start == measured[measuredSource], "Real anchors already include the node transform")
        #expect(movedEnds.end == CGPoint(x: originalEnds.end.x - 200,y: originalEnds.end.y + 400), "Collapsed input fallback follows the same delta")
        // Repeated last offset is still a valid final commit, not a dedup failure.
        let finished = try #require(presentation.finish(sessionID: id, nodeID: a.id, scope: scope,
            screenTranslation: CGSize(width: -5,height: 10), zoom: 2))
        #expect(finished.previewPositions[b.id] == CGPoint(x: 300,y: 480))
        #expect(finished.previewPositions[a.id] == CGPoint(x: -230,y: 360))
        #expect(presentation.active == nil && presentation.movingNodeIDs.isEmpty && presentation.offset == .zero)
        #expect(presentation.finish(sessionID: id,nodeID: a.id,scope: scope,screenTranslation: .zero,zoom: 1) == nil)
        #expect(presentation.begin(drag,screenTranslation: CGSize(width: 3,height: 2),zoom: 1))
        presentation.cancel(sessionID: UUID())
        #expect(presentation.active != nil)
        presentation.invalidate()
        #expect(presentation.active == nil && presentation.movingNodeIDs.isEmpty && presentation.offset == .zero)
        #expect(!presentation.update(sessionID: id,nodeID: a.id,scope: scope,screenTranslation: .zero,zoom: 1))
    }

    @Test
    func cardAndBlankAssetDropsKeepInstanceIdentityAndRejectAmbiguousLegacyPayload() throws {
        let project = UUID(), instance = UUID(), otherInstance = UUID(), asset = UUID()
        let explicit = try WorkflowCanvasTransfer.assetInstance(projectID: project,
            instanceID: instance, assetID: asset).validated()
        let card = try #require(WorkflowCanvasAssetIdentity.payload(explicit))
        let blank = try #require(WorkflowCanvasAssetIdentity.payload(
            WorkflowCanvasTransfer.decode(explicit.encoded())))
        #expect(card.project == project && card.instance == instance && card.asset == asset)
        #expect(blank.project == card.project && blank.instance == card.instance && blank.asset == card.asset)
        #expect(WorkflowCanvasAssetIdentity.acceptsOwnProject(projectID: card.project,
            instanceID: card.instance, assetID: card.asset, currentProjectID: project,
            currentInstanceID: instance, acceptsLegacyAsset: nil))
        #expect(!WorkflowCanvasAssetIdentity.acceptsOwnProject(projectID: card.project,
            instanceID: card.instance, assetID: card.asset, currentProjectID: project,
            currentInstanceID: otherInstance, acceptsLegacyAsset: nil))
        let legacy = try #require(WorkflowCanvasAssetIdentity.payload(
            .asset(projectID: project, assetID: asset)))
        #expect(!WorkflowCanvasAssetIdentity.acceptsOwnProject(projectID: legacy.project,
            instanceID: legacy.instance, assetID: legacy.asset, currentProjectID: project,
            currentInstanceID: instance, acceptsLegacyAsset: { _, _ in false }))
    }

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
    func idleOriginKeepsHeaderFixedForExpansionAndNeverShrinksAfterDrag() {
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
        #expect(reachableIdle.height == retainedAfterDrag.height)
        #expect(WorkflowGraphGeometry(graph: expanded).estimatedHeights[node.id]! > WorkflowGraphGeometry(graph: collapsed).estimatedHeights[node.id]!)

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
            .assetInstance(projectID: UUID(), instanceID: UUID(), assetID: UUID()),
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

        let output = WorkflowPortIdentity(nodeID: source.id, port: "text", input: false)
        let input = WorkflowPortIdentity(nodeID: target.id, port: "text", input: true)
        for (start, end) in [(output, input), (input, output)] {
            let pair = try #require(WorkflowCanvasConnectionPolicy.directedPorts(start, end))
            #expect(pair.output == output && pair.input == input)
            #expect(WorkflowCanvasConnectionPolicy.canConnect(graph: graph, registry: registry, tools: [],
                sourceNodeID: pair.output.nodeID, sourcePort: pair.output.port,
                targetNodeID: pair.input.nodeID, targetPort: pair.input.port))
        }
        #expect(WorkflowCanvasConnectionPolicy.directedPorts(output,
            WorkflowPortIdentity(nodeID: target.id, port: "textOut", input: false)) == nil)
        #expect(WorkflowCanvasConnectionPolicy.directedPorts(input,
            WorkflowPortIdentity(nodeID: source.id, port: "textIn", input: true)) == nil)

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

private final class WireTestDocument: NSView { override var isFlipped: Bool { true } }

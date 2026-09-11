import AppKit
import XCTest

/// Native UI exercises use a DEBUG-only isolated settings/library session. Fixture
/// projects contain CPU-created PNGs and open through the normal NSOpenPanel path.
final class DUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWelcomeOffersProjectActionsInResizableNativeWindow() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["new-project"].isEnabled)
        XCTAssertTrue(app.buttons["open-project"].isEnabled)
        XCTAssertTrue(app.buttons["open-model-library"].isEnabled)
        XCTAssertGreaterThanOrEqual(window.frame.width, 860)
        XCTAssertGreaterThanOrEqual(window.frame.height, 580)
        XCTAssertTrue(app.menuBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["generate"].exists, "Generation requires an open project.")
        recordScreenshot(app, name: "D native Liquid Glass welcome")
    }

    @MainActor
    func testNewProjectPanelCanBeCancelledWithoutChangingWelcome() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))

        app.buttons["new-project"].click()
        let panel = try nativePanel(in: app, identifier: "save-panel")
        recordScreenshot(app, name: "D native new-project panel")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(panel.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["new-project"].isEnabled)
        XCTAssertTrue(app.buttons["open-project"].isEnabled)
        XCTAssertFalse(app.buttons["generate"].exists)
    }

    @MainActor
    func testNativeNewAndOpenKeyboardCommandsPresentCancellablePanels() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))

        // These are the actual File menu commands; no test-only app action is installed.
        for shortcut in ["n", "o"] {
            app.typeKey(shortcut, modifierFlags: .command)
            let panel = try nativePanel(in: app, identifier: shortcut == "n" ? "save-panel" : "open-panel")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(panel.waitForNonExistence(timeout: 8))
            XCTAssertTrue(app.buttons["new-project"].isEnabled)
            XCTAssertTrue(app.buttons["open-project"].isEnabled)
        }
    }

    @MainActor
    func testClosingWelcomeWindowKeepsHostAliveAndModelManagerCanReopen() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))
        let host = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(host.bundleURL?.lastPathComponent, "D.app")
        let processID = host.processIdentifier

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 8))
        // Observe the process before sending any reopening command. activate()/launch()
        // would hide an unintended app termination by starting a replacement process.
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1))
        XCTAssertNotEqual(app.state, .notRunning)
        XCTAssertFalse(host.isTerminated)

        app.typeKey("m", modifierFlags: [.command, .shift])
        let done = app.buttons["model-library-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, processID)
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["new-project"].isEnabled)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(host.isTerminated)
    }

    @MainActor
    func testModelManagerWorksWithoutProjectAndKeepsProjectCommandsModal() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-model-library"].waitForExistence(timeout: 10))
        app.buttons["open-model-library"].click()

        let done = app.buttons["model-library-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["model-library-location"].exists)
        XCTAssertTrue(app.buttons["model-register-existing"].exists)
        XCTAssertTrue(app.buttons["model-install-flux2-klein-4b-q8"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["512 × 512"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "model-use-")).count, 0,
                       "A library opened without a project must not offer a misleading project selection action.")

        let windows = app.windows.count
        let dialogs = app.dialogs.count
        let sheets = app.sheets.count
        // New/Open must not place another native picker over the model manager.
        for shortcut in ["n", "o"] {
            app.typeKey(shortcut, modifierFlags: .command)
            XCTAssertEqual(app.windows.count, windows)
            XCTAssertEqual(app.dialogs.count, dialogs)
            XCTAssertEqual(app.sheets.count, sheets)
            XCTAssertTrue(done.isEnabled)
        }
        recordScreenshot(app, name: "D model manager without an open project")
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["new-project"].isEnabled)

        app.typeKey("m", modifierFlags: [.command, .shift])
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testExistingModelPickerCancelReturnsToManagerWithoutRegistration() throws {
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-model-library"].waitForExistence(timeout: 10))
        app.buttons["open-model-library"].click()
        let register = app.buttons["model-register-existing"]
        XCTAssertTrue(register.waitForExistence(timeout: 8))
        XCTAssertTrue(register.isEnabled)
        let recordQuery = NSPredicate(format: "identifier BEGINSWITH %@", "model-status-")
        let initialRecordCount = app.staticTexts.matching(recordQuery).count

        register.click()
        // NSOpenPanel exposes the stable AppKit identifier "open-panel". Its
        // visible title is not its XCTest label on this macOS version.
        let picker = try nativePanel(in: app, identifier: "open-panel")
        XCTAssertFalse(app.buttons["model-library-done"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(picker.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["model-library-done"].isEnabled)
        XCTAssertEqual(app.staticTexts.matching(recordQuery).count, initialRecordCount)
        app.buttons["model-library-done"].click()
        XCTAssertTrue(app.buttons["model-library-done"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testProjectFirstModalityNavigationAndAssetScopePreserveText() throws {
        let fixture = try makeExplorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let token = UUID().uuidString
        let app = launchWithoutRestoringProject(sessionID: token)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-project"].waitForExistence(timeout: 10))
        try openFixture(fixture, in: app)
        let before = try readFixtureManifest(fixture)
        app.buttons["creator-mode-text"].click()
        XCTAssertTrue(app.buttons["new-text-document"].waitForExistence(timeout: 8))
        XCTAssertEqual((try readFixtureManifest(fixture)["documents"] as? [[String: Any]])?.count,
                       (before["documents"] as? [[String: Any]])?.count,
                       "Selecting an empty modality must not create a document.")
        app.buttons["new-text-document"].click()
        let editor = app.scrollViews["text-draft-editor"].textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        replaceText(editor, with: "Navigation draft: keep this original while browsing assets.")
        app.buttons["text-save"].click()
        app.buttons["workspace-assets"].click()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "resource-media-\(fixtureFirstAsset)").firstMatch.exists,
                       "Text assets start with the current modality only.")
        app.checkBoxes["assets-filter-other"].click()
        let image = app.descendants(matching: .any).matching(identifier: "resource-media-\(fixtureFirstAsset)").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8)); image.click()
        XCTAssertEqual(editor.value as? String, "Navigation draft: keep this original while browsing assets.")
        let saved = try readFixtureManifest(fixture)
        let textID = try XCTUnwrap(saved["activeDocumentID"] as? String)
        app.buttons["creator-mode-image"].click()
        XCTAssertTrue(app.buttons["new-document"].waitForExistence(timeout: 8))
        app.buttons["creator-mode-text"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(try readFixtureManifest(fixture)["activeDocumentID"] as? String, textID)
        XCTAssertEqual(editor.value as? String, "Navigation draft: keep this original while browsing assets.")
        app.buttons["back-to-projects"].click()
        XCTAssertTrue(app.buttons["open-project"].waitForExistence(timeout: 8))
        let projectID = try XCTUnwrap(saved["id"] as? String)
        let recent = app.buttons["recent-project-\(projectID)"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8)); recent.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, "Navigation draft: keep this original while browsing assets.")
        recordScreenshot(app, name: "Project modality text save reopen and isolated asset preview")
    }

    @MainActor
    func testDocumentsCandidateEditsPersistThroughReopen() throws {
        let fixture = try makeExplorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let token = UUID().uuidString
        var app = launchWithoutRestoringProject(sessionID: token)
        defer { app.terminate() }
        try openFixture(fixture, in: app)
        XCTAssertTrue(app.buttons["document-\(fixtureFirstDocument)"].waitForExistence(timeout: 10))
        // Verify the first sheet presentation without typing: mode, initial value,
        // and Save enablement must derive from the same immutable context.
        app.buttons["rename-document-\(fixtureFirstDocument)"].click()
        expectNameEditor(title: "重命名创作", name: "Landscape study", in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["save-document-name"].waitForNonExistence(timeout: 8))
        app.buttons["new-document"].click()
        expectNameEditor(title: "新建创作", name: "新创作", in: app)
        replaceText(app.textFields["document-name"], with: "Alternate composition")
        app.buttons["save-document-name"].click()
        XCTAssertTrue(app.buttons["save-document-name"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alternate composition")).firstMatch.waitForExistence(timeout: 8))
        let documents = try readFixtureManifest(fixture)["documents"] as? [[String: Any]]
        let created = try XCTUnwrap(documents?.first { $0["name"] as? String == "Alternate composition" })
        let createdID = try XCTUnwrap(created["id"] as? String)
        app.buttons["rename-document-\(createdID)"].click()
        expectNameEditor(title: "重命名创作", name: "Alternate composition", in: app)
        replaceText(app.textFields["document-name"], with: "Composition study")
        app.buttons["save-document-name"].click()
        XCTAssertTrue(app.buttons["save-document-name"].waitForNonExistence(timeout: 8))
        app.buttons["document-\(fixtureFirstDocument)"].click()
        expectCandidateName("Warm candidate", in: app)
        app.buttons["artwork-\(fixtureSecondAsset)"].click()
        expectCandidateName("Cool candidate", in: app)
        revealInInspector(app.buttons["edit-candidate"], in: app)
        app.buttons["edit-candidate"].click()
        replaceText(app.textFields["candidate-name"], with: "Blue choice")
        let note = app.descendants(matching: .any).matching(identifier: "candidate-note").firstMatch
        replaceText(note, with: "Keep the cool palette")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1), "Quit must not discard pending metadata.")
        app.activate()
        XCTAssertTrue(app.buttons["save-candidate"].exists)
        XCTAssertEqual(note.value as? String, "Keep the cool palette")
        app.buttons["save-candidate"].click()
        XCTAssertTrue(app.buttons["save-candidate"].waitForNonExistence(timeout: 8))
        app.activate()
        expectCandidateName("Blue choice", in: app)
        let favorite = app.descendants(matching: .any).matching(identifier: "candidate-favorite").firstMatch
        revealInInspector(favorite, in: app)
        favorite.click()
        waitForUI(NSPredicate(format: "value == 1 OR value == '1'"), element: favorite,
                  message: "Favorite was not saved", in: app)
        revealInInspector(app.buttons["adopt-candidate"], in: app)
        app.buttons["adopt-candidate"].click()
        waitForUI(NSPredicate(format: "label == %@", "取消采用"), element: app.buttons["adopt-candidate"],
                  message: "Adoption did not complete", in: app)
        dismissInspectorPopover(in: app)
        app.buttons["document-\(fixtureSecondDocument)"].click()
        XCTAssertTrue(app.buttons["artwork-\(fixtureSecondAsset)"].waitForNonExistence(timeout: 8))
        app.buttons["workspace-assets"].click()
        let resource = app.descendants(matching: .any).matching(identifier: "resource-media-\(fixtureSecondAsset)").firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 8))
        resource.click()
        XCTAssertEqual(try readFixtureManifest(fixture)["activeDocumentID"] as? String, fixtureSecondDocument,
                       "Asset preview must not change the active creation.")
        app.buttons["workspace-creations"].click()
        app.buttons["document-\(fixtureFirstDocument)"].click()
        expectCandidateName("Blue choice", in: app)
        recordScreenshot(app, name: "D document candidates and adoption")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app = launchWithoutRestoringProject(sessionID: token)
        try openFixture(fixture, in: app)
        expectCandidateName("Blue choice", in: app)
        let saved = try readFixtureManifest(fixture)
        let savedDocuments = try XCTUnwrap(saved["documents"] as? [[String: Any]])
        let first = try XCTUnwrap(savedDocuments.first { $0["id"] as? String == fixtureFirstDocument })
        XCTAssertEqual(first["selectedAssetID"] as? String, fixtureSecondAsset)
        XCTAssertEqual(first["adoptedAssetID"] as? String, fixtureSecondAsset)
        XCTAssertTrue(savedDocuments.contains { $0["name"] as? String == "Composition study" })
        let assets = try XCTUnwrap(saved["assets"] as? [[String: Any]])
        let edited = try XCTUnwrap(assets.first { $0["id"] as? String == fixtureSecondAsset })
        XCTAssertEqual(edited["note"] as? String, "Keep the cool palette")
        XCTAssertEqual(edited["isFavorite"] as? Bool, true)
    }

    @MainActor
    func testCompareAndForkUseActualConditionsWithoutChangingOriginal() throws {
        let fixture = try makeExplorationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let app = launchWithoutRestoringProject()
        defer { app.terminate() }
        try openFixture(fixture, in: app)
        app.buttons["compare-select-\(fixtureFirstAsset)"].click()
        app.buttons["compare-select-\(fixtureSecondAsset)"].click()
        waitForUI(NSPredicate(format: "enabled == true"), element: app.buttons["compare-artworks"],
                  message: "Two candidates did not enable comparison", in: app)
        app.buttons["compare-artworks"].click()
        XCTAssertTrue(app.buttons["end-comparison"].waitForExistence(timeout: 8))
        for id in [fixtureFirstAsset, fixtureSecondAsset] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "comparison-image-\(id)").firstMatch.exists)
        }
        XCTAssertTrue(app.buttons["comparison-center"].exists)
        for id in [fixtureFirstAsset, fixtureSecondAsset] {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "comparison-prompt-difference-\(id)").firstMatch.label, "提示词不同")
        }
        let zoom = app.descendants(matching: .any).matching(identifier: "comparison-zoom").firstMatch
        let actual = zoom.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "100%")).firstMatch
        XCTAssertTrue(actual.exists)
        actual.click()
        let image = app.descendants(matching: .any).matching(identifier: "comparison-image-\(fixtureFirstAsset)").firstMatch
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        recordScreenshot(app, name: "D side by side actual-pixel comparison")
        app.buttons["end-comparison"].click()
        XCTAssertTrue(app.buttons["end-comparison"].waitForNonExistence(timeout: 8))
        expectCandidateName("Warm candidate", in: app)
        app.buttons["copy-settings"].click()
        // NSAlert.runModal presents an AppKit dialog, not necessarily an XCTest Alert.
        let warning = app.staticTexts["使用当前模型探索"].firstMatch
        let continueButtons = app.dialogs.buttons.matching(identifier: "action-button-1")
        let proceed = continueButtons.firstMatch
        guard warning.waitForExistence(timeout: 8), proceed.waitForExistence(timeout: 8) else {
            recordScreenshot(app, name: "Missing native model compatibility warning")
            XCTFail("Native model compatibility warning is missing.\n\(app.debugDescription)")
            throw NativePanelError.notFound
        }
        XCTAssertEqual(continueButtons.count, 1)
        proceed.click()
        XCTAssertTrue(proceed.waitForNonExistence(timeout: 8))
        showInspector(in: app)
        let forkedPrompt = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Warm illustrated landscape"),
            object: app.textViews["prompt-editor"])
        XCTAssertEqual(XCTWaiter.wait(for: [forkedPrompt], timeout: 8), .completed)
        XCTAssertEqual(app.textViews["prompt-editor"].value as? String, "Warm illustrated landscape")
        XCTAssertEqual(app.textFields["seed-field"].value as? String, "42")
        let manifest = try readFixtureManifest(fixture)
        let documents = try XCTUnwrap(manifest["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 3)
        XCTAssertEqual(documents.last?["sourceAssetID"] as? String, fixtureFirstAsset)
        XCTAssertEqual((manifest["assets"] as? [Any])?.count, 2, "Fork references its source and never duplicates image files.")
        XCTAssertEqual((documents.first?["draft"] as? [String: Any])?["prompt"] as? String, "An unfinished draft")
    }

    private let fixtureFirstDocument = "10000000-0000-0000-0000-000000000001"
    private let fixtureSecondDocument = "10000000-0000-0000-0000-000000000002"
    private let fixtureFirstAsset = "20000000-0000-0000-0000-000000000001"
    private let fixtureSecondAsset = "20000000-0000-0000-0000-000000000002"

    @MainActor
    private func makeExplorationFixture() throws -> URL {
        // The UI runner is sandboxed. This tiny CPU fixture must start in its own
        // temporary container; the app receives access through the normal open panel.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("D-UI-\(UUID())", isDirectory: true)
        let project = root.appendingPathComponent("Exploration.dproject", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Tasks"), withIntermediateDirectories: true)
        let date = Date().timeIntervalSinceReferenceDate
        var assets: [[String: Any]] = []
        var jobs: [[String: Any]] = []
        for index in 0..<2 {
            let job = UUID().uuidString
            let asset = index == 0 ? fixtureFirstAsset : fixtureSecondAsset
            let path = "Tasks/\(job)-\(UUID())/image.png"
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let width = index == 0 ? 1024 : 768
            let height = index == 0 ? 768 : 1024
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            (index == 0 ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 128, y: 128, width: 192, height: 512)).fill()
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            assets.append(["id": asset, "jobID": job, "relativePath": path, "mediaType": "image/png", "role": "result",
                "createdAt": date, "metadata": ["width": width, "height": height, "bitDepth": 8],
                "name": index == 0 ? "Warm candidate" : "Cool candidate", "isFavorite": false, "note": ""])
            jobs.append(["id": job, "documentID": fixtureFirstDocument, "createdAt": date, "state": "completed",
                "artifactIDs": [asset], "resultMetadata": [:], "request": ["id": job,
                "model": ["directory": root.absoluteString, "revision": "fixture-only"],
                "input": ["image": ["_0": ["prompt": index == 0 ? "Warm illustrated landscape" : "Cool illustrated landscape",
                    "width": width, "height": height, "steps": 4, "guidanceScale": 1, "seed": index == 0 ? 42 : 99]]]]])
        }
        let draft: [String: Any] = ["prompt": "An unfinished draft", "randomSeed": true, "seedText": "-"]
        let manifest: [String: Any] = ["schemaVersion": 2, "revision": 0, "id": UUID().uuidString,
            "name": "Exploration", "createdAt": date, "updatedAt": date, "activeDocumentID": fixtureFirstDocument,
            "documents": [["id": fixtureFirstDocument, "name": "Landscape study", "draft": draft, "selectedAssetID": fixtureFirstAsset],
                ["id": fixtureSecondDocument, "name": "Another study", "draft": draft]], "jobs": jobs, "assets": assets]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: project.appendingPathComponent("project.json"))
        return project
    }

    private func readFixtureManifest(_ project: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("project.json"))) as? [String: Any])
    }

    @MainActor
    private func openFixture(_ url: URL, in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["open-project"].waitForExistence(timeout: 10))
        app.buttons["open-project"].click()
        let panel = try nativePanel(in: app, identifier: "open-panel")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = app.descendants(matching: .any).matching(identifier: "GoToWindow").firstMatch
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 8))
        path.click()
        app.typeKey("a", modifierFlags: .command)
        path.typeText(url.path)
        // Native path processing and its accessibility snapshot may settle after typing.
        // Observe only: never retype, truncate the fixture path, or confirm a partial path.
        let initiallyObservedPath = path.value as? String
        let pathWaitStarted = Date()
        var pathWaitResult: XCTWaiter.Result = .completed
        if initiallyObservedPath != url.path {
            let completePath = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", url.path), object: path)
            pathWaitResult = XCTWaiter.wait(for: [completePath], timeout: 8)
        }
        XCTContext.runActivity(named: "Native fixture path synchronization") { activity in
            let evidence = XCTAttachment(string:
                "Expected: \(url.path)\nInitial: \(String(describing: initiallyObservedPath))\nFinal: \(String(describing: path.value))\nElapsed: \(Date().timeIntervalSince(pathWaitStarted))")
            evidence.lifetime = .keepAlways
            activity.add(evidence)
        }
        XCTAssertEqual(pathWaitResult, .completed, "Wait for the complete native fixture path without retyping.")
        XCTAssertEqual(path.value as? String, url.path, "The native path field must contain the complete fixture path.")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(goTo.waitForNonExistence(timeout: 8), "Finish native path navigation before confirming the parent panel.")
        XCTAssertTrue(panel.buttons["OKButton"].isEnabled)
        panel.buttons["OKButton"].click()
        guard panel.waitForNonExistence(timeout: 8) else {
            recordScreenshot(app, name: "Project open panel remained visible")
            XCTFail("Native project panel did not close.\n\(app.debugDescription)")
            throw NativePanelError.notFound
        }
        guard app.buttons["back-to-projects"].waitForExistence(timeout: 10) else {
            recordScreenshot(app, name: "Project opened without accessible creation controls")
            XCTFail("Project creation controls missing after native open.\n\(app.debugDescription)")
            throw NativePanelError.notFound
        }
    }

    @MainActor
    private func expectNameEditor(title: String, name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.textFields["document-name"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["document-name"].value as? String, name)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "document-name-title").firstMatch.label, title)
        XCTAssertTrue(app.buttons["save-document-name"].isEnabled, "Valid default names must be immediately savable.")
    }

    @MainActor
    private func waitForUI(_ predicate: NSPredicate, element: XCUIElement, message: String, in app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: element)
        guard XCTWaiter.wait(for: [expected], timeout: 8) == .completed else {
            recordScreenshot(app, name: message)
            XCTFail("\(message).\n\(app.debugDescription)")
            return
        }
    }

    @MainActor
    private func expectCandidateName(_ name: String, in app: XCUIApplication) {
        // Selection is visible in the candidate strip even when parameters are collapsed.
        let label = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "artwork-", name)).firstMatch
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND selected == true AND label == %@", name), object: label)
        guard XCTWaiter.wait(for: [expected], timeout: 8) == .completed else {
            recordScreenshot(app, name: "Candidate selection did not settle")
            XCTFail("Expected selected candidate \(name).\n\(app.debugDescription)")
            return
        }
    }

    @MainActor
    private func showInspector(in app: XCUIApplication) {
        let scroll = app.scrollViews["generation-inspector-scroll"]
        if !scroll.exists {
            let toggle = app.buttons["toggle-inspector"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            toggle.click()
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
    }

    @MainActor
    private func dismissInspectorPopover(in app: XCUIApplication) {
        let scroll = app.scrollViews["generation-inspector-scroll"]
        if app.buttons["toggle-inspector"].label == "打开创作参数", scroll.exists {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(scroll.waitForNonExistence(timeout: 8))
        }
    }

    @MainActor
    private func revealInInspector(_ element: XCUIElement, in app: XCUIApplication) {
        app.activate()
        showInspector(in: app)
        let scroll = app.scrollViews["generation-inspector-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
        for _ in 0..<8 {
            if element.exists, element.isHittable, scroll.frame.intersects(element.frame) { return }
            scroll.scroll(byDeltaX: 0, deltaY: -240)
        }
        recordScreenshot(app, name: "Inspector control could not be revealed")
        XCTFail("Inspector control is not visible and hittable.\n\(app.debugDescription)")
    }

    @MainActor
    private func replaceText(_ element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    @MainActor
    private func launchWithoutRestoringProject(sessionID: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["D_UI_TEST_SESSION"] = sessionID
        // Argument-domain overrides do not modify the persistent defaults domain.
        // A string intentionally cannot decode as bookmark Data.
        app.launchArguments = [
            "-workbench.projectBookmark.v1", "UI-test-no-project",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func nativePanel(in app: XCUIApplication, identifier: String) throws -> XCUIElement {
        // AppKit supplies these identifiers for both its open and save panels.
        // Matching an exact identifier keeps the query from retargeting the main
        // window or the model-manager sheet once the native panel closes.
        let panel = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if panel.waitForExistence(timeout: 8) {
            XCTAssertTrue(panel.buttons["CancelButton"].exists)
            XCTAssertTrue(panel.buttons["OKButton"].exists)
            return panel
        }
        recordScreenshot(app, name: "Missing native panel")
        XCTFail("The native \(identifier) panel did not appear.\n\(app.debugDescription)")
        throw NativePanelError.notFound
    }

    @MainActor
    private func recordScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum NativePanelError: Error { case notFound }
}

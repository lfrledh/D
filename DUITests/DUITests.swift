import AppKit
import XCTest

/// Exercise the real app and native panels without generating, creating projects,
/// changing model registrations, or replacing the persistent project bookmark.
/// Run only when the development app has no active installs: launching/terminating
/// the real app uses its normal model-registry recovery and shutdown behavior.
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
    private func launchWithoutRestoringProject() -> XCUIApplication {
        let app = XCUIApplication()
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

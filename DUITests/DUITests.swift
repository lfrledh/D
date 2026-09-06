import XCTest

/// These exercise the real app and native panels without generating, creating files,
/// or replacing the user's persisted project bookmark.
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
        let panel = try nativePanel(in: app)
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
            let panel = try nativePanel(in: app)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(panel.waitForNonExistence(timeout: 8))
            XCTAssertTrue(app.buttons["new-project"].isEnabled)
            XCTAssertTrue(app.buttons["open-project"].isEnabled)
        }
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
    private func nativePanel(in app: XCUIApplication) throws -> XCUIElement {
        // macOS can expose a native open/save panel as a dialog, sheet, or window.
        // Accept those native presentations instead of depending on system language.
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) { return dialog }
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 1) { return sheet }
        // The welcoming main window is named D; a panel's separate window must
        // be matched by identity rather than an index that changes after closing.
        let additionalWindow = app.windows.matching(NSPredicate(format: "label != %@", "D")).firstMatch
        if additionalWindow.waitForExistence(timeout: 3) { return additionalWindow }
        recordScreenshot(app, name: "Missing native panel")
        XCTFail("The native open/save panel did not appear.\n\(app.debugDescription)")
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

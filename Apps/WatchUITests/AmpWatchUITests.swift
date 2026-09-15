import XCTest

/// Semantic checks on the rendered UI.
///
/// These assert the accessibility tree, which is what VoiceOver and the
/// screenshot harness both depend on. Visual correctness is verified separately
/// by `Scripts/capture-screens.sh`, whose PNGs a human or agent reviews.
@MainActor
final class AmpWatchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ampwatch-screen", screen]
        app.launch()
        return app
    }

    func testThreadListShowsFirstAndLastFixtureThread() {
        let app = launch(screen: "threads")
        let list = app.descendants(matching: .any)["thread-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        // `List` only materialises rows that fit on screen, so counting rows
        // measures the watch size, not the data. Check the ends instead: the
        // first fixture thread is visible at rest, and the untitled fourth one
        // (rendered by its ID prefix) appears after scrolling.
        let rows = app.descendants(matching: .any).matching(identifier: "thread-row")
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Fix the flaky watchOS simulator boot"))

        list.swipeUp()
        list.swipeUp()
        let last = rows.containing(NSPredicate(format: "label CONTAINS %@", "T-77c3ba91")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5))
    }

    func testEmptyStateIsReachableAndNotJustAnEmptyList() {
        let app = launch(screen: "threads-empty")
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 20))
    }

    func testUnauthorizedRendersAnActionableErrorRatherThanABlankScreen() {
        let app = launch(screen: "threads-error")
        XCTAssertTrue(app.descendants(matching: .any)["error-state"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testSendIsDisabledUntilThePromptHasContent() {
        let app = launch(screen: "compose")
        XCTAssertTrue(app.descendants(matching: .any)["compose"].waitForExistence(timeout: 20))
        // A send button that is tappable while empty would fire a no-op webhook
        // request and burn rate-limit capacity.
        XCTAssertFalse(app.buttons["send-button"].isEnabled)
    }

    func testUsageShowsATotal() {
        let app = launch(screen: "usage")
        XCTAssertTrue(app.descendants(matching: .any)["usage"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["total-cost"].exists)
    }

    func testSetupCannotContinueWithoutAToken() {
        let app = launch(screen: "setup")
        XCTAssertTrue(app.descendants(matching: .any)["setup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["continue-button"].isEnabled)
    }

    func testSettingsMasksSecrets() {
        let app = launch(screen: "settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings"].waitForExistence(timeout: 20))
        // The fixture token ends in "7f3a"; a screenshot of this screen ends up
        // in a public CI artifact, so only that suffix may be on screen.
        let token = app.staticTexts["token-value"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        XCTAssertEqual(token.label, "…7f3a")
        XCTAssertEqual(app.staticTexts["webhook-value"].label, "hooks.example.test")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fixture-token")).firstMatch.exists)
    }

    func testDetailOffersStopOnlyBehindAConfirmation() {
        let app = launch(screen: "detail")
        XCTAssertTrue(app.descendants(matching: .any)["thread-detail"].waitForExistence(timeout: 20))
        // The fixture thread was updated 12 s ago, so it counts as live and
        // must offer Stop — but never send on the first tap.
        let stop = app.buttons["cancel-button"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(app.buttons["cancel-confirm-button"].waitForExistence(timeout: 5))
    }

    func testNewThreadCannotStartWithoutAPrompt() {
        let app = launch(screen: "new-thread")
        XCTAssertTrue(app.descendants(matching: .any)["new-thread"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["start-button"].isEnabled)
    }

    func testDetailShowsFullTitleInBodyNotOnlyInBar() {
        let app = launch(screen: "detail")
        XCTAssertTrue(app.descendants(matching: .any)["thread-detail"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["thread-title"].label, "Fix the flaky watchOS simulator boot in CI")
    }
}

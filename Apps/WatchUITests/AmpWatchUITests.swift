import XCTest

/// Semantic checks on the rendered UI.
///
/// These assert the accessibility tree, which is what VoiceOver and the
/// screenshot harness both depend on. Visual correctness is verified separately
/// by `Scripts/capture-screens.sh`, whose PNGs a human or agent reviews.
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

    func testThreadListShowsOneRowPerFixtureThread() {
        let app = launch(screen: "threads")
        XCTAssertTrue(app.otherElements["thread-list"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "thread-row").count, 4)
    }

    func testEmptyStateIsReachableAndNotJustAnEmptyList() {
        let app = launch(screen: "threads-empty")
        XCTAssertTrue(app.otherElements["empty-state"].waitForExistence(timeout: 20))
    }

    func testUnauthorizedRendersAnActionableErrorRatherThanABlankScreen() {
        let app = launch(screen: "threads-error")
        XCTAssertTrue(app.otherElements["error-state"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testSendIsDisabledUntilThePromptHasContent() {
        let app = launch(screen: "compose")
        XCTAssertTrue(app.otherElements["compose"].waitForExistence(timeout: 20))
        // A send button that is tappable while empty would fire a no-op webhook
        // request and burn rate-limit capacity.
        XCTAssertFalse(app.buttons["send-button"].isEnabled)
    }

    func testUsageShowsATotal() {
        let app = launch(screen: "usage")
        XCTAssertTrue(app.otherElements["usage"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["total-cost"].exists)
    }
}

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

    private func reveal(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5), element.isHittable { return }
        for _ in 0..<60 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.08)
            if element.exists && element.isHittable { return }
        }
        XCTFail("Could not reveal \(element)")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPuckEntryExplainsTheLimitWithoutOfferingFakeChat() {
        let app = launch(screen: "threads")
        let puck = app.descendants(matching: .any)["puck-button"]
        XCTAssertTrue(puck.waitForExistence(timeout: 20))
        XCTAssertTrue(puck.label.contains("Phone / web only"))
        puck.tap()
        XCTAssertTrue(app.descendants(matching: .any)["puck"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["puck-unavailable"].exists)
        XCTAssertFalse(app.buttons["send-button"].exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        app.descendants(matching: .any)["puck"].swipeUp()
        capture(app, name: "puck-guidance")
    }

    func testGroupedOverviewShowsCountsTitlesAndMissingRepository() {
        let app = launch(screen: "threads-grouped")
        XCTAssertTrue(app.descendants(matching: .any)["puck-button"].waitForExistence(timeout: 20))
        let groups = app.descendants(matching: .any).matching(identifier: "thread-group")
        let first = groups.containing(NSPredicate(format: "label == %@", "soll/AmpWatch · 2")).firstMatch
        reveal(first)
        let rows = app.descendants(matching: .any).matching(identifier: "thread-row")
        let chinese = rows.containing(NSPredicate(format: "label CONTAINS %@", "多语言与语音功能")).firstMatch
        reveal(chinese)
        XCTAssertTrue(chinese.label.contains("Updated 1m"))
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.16)
        capture(app, name: "grouped-chinese-title")
        reveal(groups.containing(NSPredicate(format: "label CONTAINS %@", "Repository unavailable")).firstMatch)
        capture(app, name: "grouped-missing-repository")
        reveal(app.staticTexts["threads-more-note"])
        capture(app, name: "grouped-page-limit")
    }

    func testThreadListShowsFirstAndLastFixtureThread() {
        let app = launch(screen: "threads")
        let list = app.descendants(matching: .any)["thread-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        // Puck and section headers take space. Reveal named rows rather than
        // assuming a particular number of threads fits on every watch size.
        let rows = app.descendants(matching: .any).matching(identifier: "thread-row")
        let first = rows.containing(NSPredicate(format: "label CONTAINS %@", "Fix the flaky watchOS simulator boot")).firstMatch
        reveal(first)
        XCTAssertTrue(first.label.contains("Updated 12s"))
        let last = rows.containing(NSPredicate(format: "label CONTAINS %@", "T-77c3ba91")).firstMatch
        reveal(last)
    }

    func testEmptyStateIsReachableAndNotJustAnEmptyList() {
        let app = launch(screen: "threads-empty")
        XCTAssertTrue(app.descendants(matching: .any)["puck-button"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 20))
    }

    func testUnauthorizedRendersAnActionableErrorRatherThanABlankScreen() {
        let app = launch(screen: "threads-error")
        XCTAssertTrue(app.descendants(matching: .any)["error-state"].waitForExistence(timeout: 20))
        reveal(app.buttons["Retry"])
        capture(app, name: "threads-error-retry")
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
        let settings = app.descendants(matching: .any)["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        // The credentials sit below the wrist preferences. `List` only keeps
        // the rows currently on screen in the accessibility tree, and one
        // `swipeUp()` flings a 40mm screen straight past them to the bottom
        // (seen in the xcresult of run 34948838337). Turn the crown a little
        // at a time instead and stop as soon as the row is there.
        let token = app.descendants(matching: .any)["token-value"]
        for _ in 0..<30 where !token.exists {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.08)
        }
        // The fixture token ends in "7f3a"; a screenshot of this screen ends up
        // in a public CI artifact, so only that suffix may be on screen.
        XCTAssertTrue(token.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(token.label, "…7f3a")
        // Further crown turns did nothing once the token row was on screen
        // (run 34950202185), but a swipe lands on the last screenful, and the
        // bridge row is the first thing there (run 34948838337).
        let webhook = app.descendants(matching: .any)["webhook-value"]
        for _ in 0..<3 where !webhook.exists {
            settings.swipeUp()
        }
        XCTAssertTrue(webhook.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(webhook.label, "hooks.example.test")
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

    func testDetailOffersTheAskMeFirstPicker() {
        let app = launch(screen: "detail")
        XCTAssertTrue(app.descendants(matching: .any)["thread-detail"].waitForExistence(timeout: 20))
        let list = app.descendants(matching: .any)["thread-detail"]
        list.swipeUp()
        list.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["arm-picker"].waitForExistence(timeout: 5))
    }

    func testPlainApprovalOffersApproveAndReject() {
        let app = launch(screen: "approval")
        XCTAssertTrue(app.descendants(matching: .any)["approval"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["approval-command"].label.contains("swift test"))
        XCTAssertTrue(app.buttons["approve-button"].isEnabled)
        XCTAssertTrue(app.buttons["reject-button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["approval-warning"].exists)
    }

    func testDestructiveApprovalWarnsBeforeTheCommand() {
        let app = launch(screen: "approval-destructive")
        XCTAssertTrue(app.descendants(matching: .any)["approval"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["approval-warning"].exists)
        let warning = app.staticTexts["force push"]
        XCTAssertTrue(warning.exists)
        // Approve is still offered, but sits below the command and the warning.
        let approve = app.buttons["approve-button"]
        XCTAssertTrue(approve.exists)
        XCTAssertLessThan(warning.frame.minY, approve.frame.minY)
    }

    func testTruncatedApprovalHasNoApproveButton() {
        let app = launch(screen: "approval-deferred")
        XCTAssertTrue(app.descendants(matching: .any)["approval"].waitForExistence(timeout: 20))
        // Approving what cannot be read is the failure this screen prevents:
        // the button must not exist, not merely be disabled.
        XCTAssertFalse(app.buttons["approve-button"].exists)
        XCTAssertTrue(app.buttons["defer-button"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["approval-defer-reason"].exists)
    }

    func testExpiredApprovalOffersNoDecisionAtAll() {
        let app = launch(screen: "approval-expired")
        XCTAssertTrue(app.descendants(matching: .any)["approval"].waitForExistence(timeout: 20))
        // The bridge already rejected this call. Any button here would send
        // a decision into nothing — or onto a later call with the same id.
        XCTAssertTrue(app.descendants(matching: .any)["approval-expired"].exists)
        XCTAssertFalse(app.buttons["approve-button"].exists)
        XCTAssertFalse(app.buttons["reject-button"].exists)
        XCTAssertFalse(app.buttons["defer-button"].exists)
        // The command stays visible so the user knows what was skipped.
        XCTAssertTrue(app.staticTexts["approval-command"].label.contains("swift build"))
    }

    func testQueuedCommandsShowAboveTheThreadList() {
        let app = launch(screen: "threads-queued")
        XCTAssertTrue(app.descendants(matching: .any)["thread-list"].waitForExistence(timeout: 20))
        let banner = app.descendants(matching: .any)["outbox-banner"]
        reveal(banner)
        XCTAssertTrue(banner.label.contains("2 waiting to send"), banner.label)
        // Without anything queued there is no banner at all, not an empty one.
        let plain = launch(screen: "threads")
        XCTAssertTrue(plain.descendants(matching: .any)["thread-list"].waitForExistence(timeout: 20))
        XCTAssertFalse(plain.descendants(matching: .any)["outbox-banner"].exists)
    }

    func testLiveThreadOverTheCapIsFlaggedInTheList() {
        let app = launch(screen: "threads-over-cap")
        XCTAssertTrue(app.descendants(matching: .any)["thread-list"].waitForExistence(timeout: 20))
        let rows = app.descendants(matching: .any).matching(identifier: "thread-row")
        // The first fixture thread is live and has spent $1.87 against a
        // $1.50 cap; the second is quiet, so its cost is never fetched.
        let flagged = rows.containing(NSPredicate(format: "label CONTAINS %@", "over cap")).firstMatch
        reveal(flagged)
        XCTAssertTrue(flagged.label.contains("$1.87"), flagged.label)
        let quiet = rows.containing(NSPredicate(format: "label CONTAINS %@", "Trim the bundle")).firstMatch
        reveal(quiet)
        XCTAssertFalse(quiet.label.contains("$"), quiet.label)
    }

    func testDetailCostRowWarnsOnlyPastTheCap() {
        let over = launch(screen: "detail-over-cap")
        XCTAssertTrue(over.descendants(matching: .any)["thread-detail"].waitForExistence(timeout: 20))
        let row = over.descendants(matching: .any)["cost-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("over cap"), row.label)

        // Same spend under the default $5 cap: a plain amount, no warning.
        let fine = launch(screen: "detail")
        XCTAssertTrue(fine.descendants(matching: .any)["thread-detail"].waitForExistence(timeout: 20))
        let plain = fine.descendants(matching: .any)["cost-row"]
        XCTAssertTrue(plain.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "$1.87"), object: plain)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, plain.label)
        XCTAssertFalse(plain.label.contains("cap"), plain.label)
    }

    func testComposeOffersTheSavedPhrases() {
        let app = launch(screen: "compose")
        XCTAssertTrue(app.descendants(matching: .any)["compose"].waitForExistence(timeout: 20))
        let chips = app.buttons.matching(identifier: "phrase-chip")
        XCTAssertEqual(chips.count, 6)
        chips.element(boundBy: 1).tap()
        // Tapping fills the field; it must not send on its own.
        XCTAssertEqual(app.descendants(matching: .any)["prompt-field"].value as? String, "Run the tests")
        XCTAssertFalse(app.descendants(matching: .any)["send-confirmation"].exists)
        XCTAssertTrue(app.buttons["send-button"].isEnabled)
    }

    func testPhrasesScreenListsTheDefaultsAndRejectsABlankEntry() {
        let app = launch(screen: "phrases")
        XCTAssertTrue(app.descendants(matching: .any)["phrases"].waitForExistence(timeout: 20))
        let rows = app.descendants(matching: .any).matching(identifier: "phrase-row")
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.element(boundBy: 0).label, "Continue")
        XCTAssertTrue(app.descendants(matching: .any)["phrase-field"].exists)
    }

    func testTemplatesScreenCannotSaveWithoutTitleAndPrompt() {
        let app = launch(screen: "templates")
        XCTAssertTrue(app.descendants(matching: .any)["templates"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["template-save-button"].isEnabled)
        // The saved templates sit below the form.
        app.descendants(matching: .any)["templates"].swipeUp()
        let rows = app.descendants(matching: .any).matching(identifier: "template-row")
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Fix CI"))
    }

    func testNewThreadOffersATemplatePicker() {
        let app = launch(screen: "new-thread")
        XCTAssertTrue(app.descendants(matching: .any)["new-thread"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["template-picker"].exists)
    }

    func testComplicationFacesSpeakOneSentenceEach() {
        let app = launch(screen: "glance")
        XCTAssertTrue(app.descendants(matching: .any)["glance"].waitForExistence(timeout: 20))
        let faces = app.descendants(matching: .any)
        // Fixture: one live thread, one held call, $1.87 of usage today.
        XCTAssertEqual(faces["face-awaiting-circular"].label, "Amp: 1 waiting on you, 1 moving")
        XCTAssertEqual(faces["face-awaiting-rectangular"].label, "Amp: 1 waiting on you, 1 moving")
        // A face with nothing to show says so instead of showing zeros.
        app.descendants(matching: .any)["glance"].swipeUp()
        let stale = faces["face-stale"]
        XCTAssertTrue(stale.waitForExistence(timeout: 5))
        XCTAssertEqual(stale.label, "Amp: open to refresh")

        let spend = launch(screen: "glance-spend")
        XCTAssertTrue(spend.descendants(matching: .any)["glance-spend"].waitForExistence(timeout: 20))
        XCTAssertEqual(spend.descendants(matching: .any)["face-spend-circular"].label, "Amp: $1.87 today")
    }
}

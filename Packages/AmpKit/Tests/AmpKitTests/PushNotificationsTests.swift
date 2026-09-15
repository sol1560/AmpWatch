import XCTest
@testable import AmpKit

final class PushNotificationsTests: XCTestCase {
    func testDeviceTokenIsLowercaseHexWithLeadingZeros() {
        XCTAssertEqual(DeviceToken.hex(Data([0x0a, 0xff, 0x00])), "0aff00")
        XCTAssertEqual(DeviceToken.hex(Data(repeating: 0xab, count: 32)).count, 64)
    }

    /// The `approval` object exactly as `Plugin/apns.ts` writes it.
    private let approvalFields: [AnyHashable: Any] = [
        "id": "call-3",
        "toolName": "shell_command",
        "input": "/repo $ swift test",
        "inputIsComplete": true,
        "requestedAt": 1_773_480_020_000.0,
    ]

    /// A moment inside the plain approval's window.
    private let now = Date(timeIntervalSince1970: 1_773_480_060)

    private var plain: PendingApproval {
        PendingApproval(
            id: "call-3",
            threadID: "T-1",
            toolName: "shell_command",
            input: "/repo $ swift test",
            requestedAt: Date(timeIntervalSince1970: 1_773_480_020)
        )
    }

    func testPayloadNeedsAThreadIDAndKeepsApprovalOptional() {
        XCTAssertEqual(PushPayload(userInfo: ["threadID": "T-1"]), PushPayload(threadID: "T-1"))
        XCTAssertEqual(
            PushPayload(userInfo: ["threadID": "T-1", "approval": approvalFields, "aps": ["alert": "x"]]),
            PushPayload(threadID: "T-1", approval: plain)
        )
        XCTAssertNil(PushPayload(userInfo: ["threadID": 12]))
        XCTAssertNil(PushPayload(userInfo: ["threadID": "not-a-thread"]))
        XCTAssertNil(PushPayload(userInfo: ["approval": approvalFields]))
    }

    func testAnApprovalMissingItsInputIsDroppedNotHalfRead() {
        var fields = approvalFields
        fields["input"] = nil
        XCTAssertEqual(PushPayload(userInfo: ["threadID": "T-1", "approval": fields]), PushPayload(threadID: "T-1"))
    }

    func testRequestedAtIsMilliseconds() {
        let payload = PushPayload(userInfo: ["threadID": "T-1", "approval": approvalFields])
        XCTAssertEqual(payload?.approval?.requestedAt, Date(timeIntervalSince1970: 1_773_480_020))
    }

    func testAnApprovalWithoutTheCompletenessFlagIsNotTrustedAsComplete() {
        // The bridge always writes the key. Missing it means this is not a
        // payload we built, and "assume complete" would let a cut command
        // through to Approve.
        var fields = approvalFields
        fields["inputIsComplete"] = nil
        XCTAssertEqual(PushPayload(userInfo: ["threadID": "T-1", "approval": fields]), PushPayload(threadID: "T-1"))
    }

    func testContinueIsAQueuedPromptNotASteer() {
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "CONTINUE", payload: PushPayload(threadID: "T-1"), now: now),
            .send(.prompt(threadID: "T-1", text: "Continue.", steer: false))
        )
    }

    func testApproveFromTheBannerOnlyForACommandTheScreenWouldNotWarnAbout() {
        XCTAssertEqual(PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1"), now: now), .open)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: plain), now: now),
            .send(plain.decision(.approve))
        )
        // A force push warns on the screen, so the banner must not approve it.
        let risky = PendingApproval(id: "call-4", threadID: "T-1", toolName: "shell_command", input: "git push -f", requestedAt: now)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: risky), now: now),
            .review(risky)
        )
        // A truncated command cannot be approved anywhere; the screen says why.
        let cut = PendingApproval(id: "call-5", threadID: "T-1", toolName: "shell_command", input: "ls", requestedAt: now, inputIsComplete: false)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: cut), now: now),
            .review(cut)
        )
    }

    func testRejectFromTheBannerIsAlwaysHonoured() {
        let risky = PendingApproval(id: "call-4", threadID: "T-1", toolName: "shell_command", input: "git push -f", requestedAt: now)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "REJECT", payload: PushPayload(threadID: "T-1", approval: risky), now: now),
            .send(risky.decision(.reject))
        )
    }

    func testTheBannerDoesNotApproveACommandItCouldNotShowWhole() {
        // The alert body is clipped at 160 characters (`MAX_SUMMARY` in
        // Plugin/apns.ts). Approving from a clipped banner is approving a
        // command you did not read.
        let long = PendingApproval(
            id: "call-6", threadID: "T-1", toolName: "shell_command",
            input: String(repeating: "swift build && ", count: 12), requestedAt: now
        )
        XCTAssertTrue(long.input.count < PendingApproval.maxReadableInputLength, "still readable on the screen")
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: long), now: now),
            .review(long)
        )
    }

    func testAnExpiredApprovalGoesToTheScreenFromEitherButton() {
        // The bridge rejected the call ten minutes after holding it. A banner
        // left on the wrist since then must not send a decision into nothing.
        let late = plain.deadline.addingTimeInterval(1)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: plain), now: late),
            .review(plain)
        )
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "REJECT", payload: PushPayload(threadID: "T-1", approval: plain), now: late),
            .review(plain)
        )
    }

    func testAPlainTapOpensTheApprovalIfThereIsOne() {
        // UNNotificationDefaultActionIdentifier, spelled out to keep AmpKit off UserNotifications.
        let tap = "com.apple.UNNotificationDefaultActionIdentifier"
        XCTAssertEqual(PushAction.response(actionIdentifier: tap, payload: PushPayload(threadID: "T-1"), now: now), .open)
        XCTAssertEqual(PushAction.response(actionIdentifier: tap, payload: PushPayload(threadID: "T-1", approval: plain), now: now), .review(plain))
    }

    func testEveryCategoryHasAtLeastOneActionAndTheStringsMatchThePlugin() {
        for category in PushCategory.allCases {
            XCTAssertFalse(category.actions.isEmpty, category.rawValue)
        }
        XCTAssertEqual(PushCategory.allCases.map(\.rawValue), ["THREAD_DONE", "THREAD_ERROR", "APPROVAL"])
    }
}

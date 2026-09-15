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

    func testRequestedAtIsMillisecondsAndCompletenessDefaultsToTrue() {
        var fields = approvalFields
        fields["inputIsComplete"] = nil
        let payload = PushPayload(userInfo: ["threadID": "T-1", "approval": fields])
        XCTAssertEqual(payload?.approval?.requestedAt, Date(timeIntervalSince1970: 1_773_480_020))
        XCTAssertEqual(payload?.approval?.inputIsComplete, true)
    }

    func testContinueIsAQueuedPromptNotASteer() {
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "CONTINUE", payload: PushPayload(threadID: "T-1")),
            .send(.prompt(threadID: "T-1", text: "Continue.", steer: false))
        )
    }

    func testApproveFromTheBannerOnlyForACommandTheScreenWouldNotWarnAbout() {
        XCTAssertEqual(PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1")), .open)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: plain)),
            .send(.decide(approvalID: "call-3", threadID: "T-1", decision: .approve))
        )
        // A force push warns on the screen, so the banner must not approve it.
        let risky = PendingApproval(id: "call-4", threadID: "T-1", toolName: "shell_command", input: "git push -f", requestedAt: .distantPast)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: risky)),
            .review(risky)
        )
        // A truncated command cannot be approved anywhere; the screen says why.
        let cut = PendingApproval(id: "call-5", threadID: "T-1", toolName: "shell_command", input: "ls", requestedAt: .distantPast, inputIsComplete: false)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1", approval: cut)),
            .review(cut)
        )
    }

    func testRejectFromTheBannerIsAlwaysHonoured() {
        let risky = PendingApproval(id: "call-4", threadID: "T-1", toolName: "shell_command", input: "git push -f", requestedAt: .distantPast)
        XCTAssertEqual(
            PushAction.response(actionIdentifier: "REJECT", payload: PushPayload(threadID: "T-1", approval: risky)),
            .send(.decide(approvalID: "call-4", threadID: "T-1", decision: .reject))
        )
    }

    func testAPlainTapOpensTheApprovalIfThereIsOne() {
        // UNNotificationDefaultActionIdentifier, spelled out to keep AmpKit off UserNotifications.
        let tap = "com.apple.UNNotificationDefaultActionIdentifier"
        XCTAssertEqual(PushAction.response(actionIdentifier: tap, payload: PushPayload(threadID: "T-1")), .open)
        XCTAssertEqual(PushAction.response(actionIdentifier: tap, payload: PushPayload(threadID: "T-1", approval: plain)), .review(plain))
    }

    func testEveryCategoryHasAtLeastOneActionAndTheStringsMatchThePlugin() {
        for category in PushCategory.allCases {
            XCTAssertFalse(category.actions.isEmpty, category.rawValue)
        }
        XCTAssertEqual(PushCategory.allCases.map(\.rawValue), ["THREAD_DONE", "THREAD_ERROR", "APPROVAL"])
    }
}

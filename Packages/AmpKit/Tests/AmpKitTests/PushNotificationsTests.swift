import XCTest
@testable import AmpKit

final class PushNotificationsTests: XCTestCase {
    func testDeviceTokenIsLowercaseHexWithLeadingZeros() {
        XCTAssertEqual(DeviceToken.hex(Data([0x0a, 0xff, 0x00])), "0aff00")
        XCTAssertEqual(DeviceToken.hex(Data(repeating: 0xab, count: 32)).count, 64)
    }

    func testPayloadNeedsAThreadIDAndKeepsApprovalOptional() {
        XCTAssertEqual(PushPayload(userInfo: ["threadID": "T-1"]), PushPayload(threadID: "T-1"))
        XCTAssertEqual(
            PushPayload(userInfo: ["threadID": "T-1", "approvalID": "call-3", "aps": ["alert": "x"]]),
            PushPayload(threadID: "T-1", approvalID: "call-3")
        )
        XCTAssertNil(PushPayload(userInfo: ["threadID": 12]))
        XCTAssertNil(PushPayload(userInfo: ["threadID": "not-a-thread"]))
        XCTAssertNil(PushPayload(userInfo: ["approvalID": "call-3"]))
    }

    func testContinueIsAQueuedPromptNotASteer() {
        XCTAssertEqual(
            PushAction.command(actionIdentifier: "CONTINUE", payload: PushPayload(threadID: "T-1")),
            .prompt(threadID: "T-1", text: "Continue.", steer: false)
        )
    }

    func testApproveNeedsAnApprovalIDAndRejectIsADecision() {
        XCTAssertNil(PushAction.command(actionIdentifier: "APPROVE", payload: PushPayload(threadID: "T-1")))
        XCTAssertEqual(
            PushAction.command(actionIdentifier: "REJECT", payload: PushPayload(threadID: "T-1", approvalID: "call-3")),
            .decide(approvalID: "call-3", threadID: "T-1", decision: .reject)
        )
    }

    func testAPlainTapSendsNothing() {
        // UNNotificationDefaultActionIdentifier, spelled out to keep AmpKit off UserNotifications.
        XCTAssertNil(PushAction.command(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", payload: PushPayload(threadID: "T-1")))
    }

    func testEveryCategoryHasAtLeastOneActionAndTheStringsMatchThePlugin() {
        for category in PushCategory.allCases {
            XCTAssertFalse(category.actions.isEmpty, category.rawValue)
        }
        XCTAssertEqual(PushCategory.allCases.map(\.rawValue), ["THREAD_DONE", "THREAD_ERROR", "APPROVAL"])
    }
}

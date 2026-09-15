import XCTest
@testable import AmpKit

final class PendingApprovalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_773_480_060)

    private func approval(
        _ input: String,
        complete: Bool = true,
        tool: String = "bash"
    ) -> PendingApproval {
        PendingApproval(
            id: "call-1",
            threadID: "T-1",
            toolName: tool,
            input: input,
            requestedAt: t0,
            inputIsComplete: complete
        )
    }

    func testAnOrdinaryCommandIsDecidable() {
        XCTAssertEqual(approval("swift test").recommendation(), .decide)
    }

    func testTruncatedInputIsNeverApprovable() {
        // Approving what you cannot see is the failure this type prevents. A
        // truncated command must not offer Approve at all, even when the
        // visible part looks harmless.
        guard case .deferToLargerScreen = approval("swift test", complete: false).recommendation() else {
            return XCTFail("truncated input must defer")
        }
    }

    func testOverlongInputDefersEvenWhenComplete() {
        let long = String(repeating: "a", count: PendingApproval.maxReadableInputLength + 1)
        guard case .deferToLargerScreen = approval(long).recommendation() else {
            return XCTFail("unreadably long input must defer")
        }
        // Exactly at the limit is still readable.
        let atLimit = String(repeating: "a", count: PendingApproval.maxReadableInputLength)
        XCTAssertEqual(approval(atLimit).recommendation(), .decide)
    }

    func testDestructiveCommandsAreFlagged() {
        for command in ["rm -rf /tmp/x", "git push --force", "git reset --hard HEAD~3",
                        "psql -c 'DROP TABLE users'", "cat ~/.ssh/id_rsa"] {
            guard case .warn = approval(command).recommendation() else {
                return XCTFail("\(command) should warn")
            }
        }
    }

    func testFlaggingIsCaseInsensitive() {
        guard case let .warn(signals) = approval("psql -c 'Drop Table Users'").recommendation() else {
            return XCTFail("should warn regardless of case")
        }
        XCTAssertEqual(signals.map(\.label), ["drops a table"])
    }

    func testEachRiskIsReportedOnceEvenWithSeveralMatches() {
        // "rm -rf" and "rm -fr" share a label; the warning should not repeat it.
        guard case let .warn(signals) = approval("rm -rf a && rm -fr b").recommendation() else {
            return XCTFail("should warn")
        }
        XCTAssertEqual(signals.count, 1)
    }

    func testTruncationOutranksEverythingElse() {
        // A truncated destructive command must defer, not merely warn: warning
        // would still present an Approve button for an unreadable command.
        guard case .deferToLargerScreen = approval("rm -rf /", complete: false).recommendation() else {
            return XCTFail("truncation must win over warning")
        }
    }

    func testWaitedSecondsNeverGoesNegative() {
        XCTAssertEqual(approval("ls").waitedSeconds(now: t0.addingTimeInterval(-30)), 0)
        XCTAssertEqual(approval("ls").waitedSeconds(now: t0.addingTimeInterval(45)), 45)
    }
}

final class ThreadStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_480_060)

    private func status(_ id: String, _ state: AgentState?, ageSeconds: TimeInterval) -> ThreadStatus {
        ThreadStatus(
            thread: ThreadSummary(id: id, updatedAt: now.addingTimeInterval(-ageSeconds)),
            agentState: state
        )
    }

    func testBlockedThreadsOutrankEverythingIncludingNewerOnes() {
        // A thread blocked on the user two hours ago matters more than one
        // that ran a second ago.
        let ranked = [
            status("running-now", .running, ageSeconds: 1),
            status("blocked", .awaitingApproval, ageSeconds: 7200),
            status("idle", .idle, ageSeconds: 30),
        ].rankedForWatch(now: now)

        XCTAssertEqual(ranked.map(\.id), ["blocked", "running-now", "idle"])
    }

    func testErrorsRankBelowApprovalsButAboveRunning() {
        let ranked = [
            status("running", .running, ageSeconds: 5),
            status("error", .error, ageSeconds: 5),
            status("blocked", .awaitingApproval, ageSeconds: 5),
        ].rankedForWatch(now: now)

        XCTAssertEqual(ranked.map(\.id), ["blocked", "error", "running"])
    }

    func testThreadsWithoutBridgeStateFallBackToObservedRecency() {
        // No bridge plugin: a thread that just changed should still sort near
        // running threads rather than sinking below stale ones.
        let ranked = [
            status("stale-unknown", nil, ageSeconds: 86_400),
            status("fresh-unknown", nil, ageSeconds: 5),
            status("idle-known", .idle, ageSeconds: 60),
        ].rankedForWatch(now: now)

        XCTAssertEqual(ranked.first?.id, "fresh-unknown")
        XCTAssertEqual(ranked.last?.id, "stale-unknown")
    }

    func testBlockedIsNeverInferredWithoutBridgeState() {
        // Sending someone to an approval screen with nothing to approve is a
        // lie; absence of state means unknown, not blocked.
        XCTAssertFalse(status("unknown", nil, ageSeconds: 1).isBlockedOnUser)
        XCTAssertFalse(status("running", .running, ageSeconds: 1).isBlockedOnUser)
        XCTAssertTrue(status("blocked", .awaitingApproval, ageSeconds: 1).isBlockedOnUser)
        XCTAssertTrue(status("error", .error, ageSeconds: 1).isBlockedOnUser)
    }

    func testBlockedOnUserFiltersToActionableThreads() {
        let all = [
            status("a", .running, ageSeconds: 1),
            status("b", .awaitingApproval, ageSeconds: 1),
            status("c", nil, ageSeconds: 1),
            status("d", .error, ageSeconds: 1),
        ]
        XCTAssertEqual(all.blockedOnUser().map(\.id), ["b", "d"])
    }

    func testTiesBreakByRecencyWithinABucket() {
        let ranked = [
            status("older", .running, ageSeconds: 300),
            status("newer", .running, ageSeconds: 10),
        ].rankedForWatch(now: now)

        XCTAssertEqual(ranked.map(\.id), ["newer", "older"])
    }
}

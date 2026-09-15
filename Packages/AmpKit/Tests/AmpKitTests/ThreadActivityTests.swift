import XCTest
@testable import AmpKit

final class ThreadActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_480_060)

    func testBoundariesAreHalfOpenIntervals() {
        // Just inside the live window stays live; exactly at the boundary has
        // already aged out of it. This separates `<` from `<=`.
        XCTAssertEqual(activity(ageSeconds: 89.999), .live)
        XCTAssertEqual(activity(ageSeconds: 90), .recent)

        XCTAssertEqual(activity(ageSeconds: 899.999), .recent)
        XCTAssertEqual(activity(ageSeconds: 900), .dormant)
    }

    func testFutureTimestampCountsAsLive() {
        // Clock skew between the watch and the server must not make a thread
        // that is actively running look dormant.
        XCTAssertEqual(activity(ageSeconds: -30), .live)
    }

    func testMissingTimestampIsUnknownRatherThanDormant() {
        XCTAssertEqual(ThreadActivity.derive(updatedAt: nil, now: now), .unknown)
    }

    func testCustomWindowsAreHonoured() {
        XCTAssertEqual(
            ThreadActivity.derive(
                updatedAt: now.addingTimeInterval(-120),
                now: now,
                liveWindow: 300,
                recentWindow: 600
            ),
            .live
        )
    }

    func testThreadSummaryUsesItsOwnUpdatedAt() {
        let thread = ThreadSummary(id: "T-1", updatedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(thread.activity(now: now), .live)
    }

    private func activity(ageSeconds: TimeInterval) -> ThreadActivity {
        ThreadActivity.derive(updatedAt: now.addingTimeInterval(-ageSeconds), now: now)
    }
}

import XCTest
@testable import AmpKit

final class GlanceTests: XCTestCase {
    /// 2026-03-14 09:21 UTC; the calendar below is fixed to UTC so "today"
    /// began 9h21m ago.
    private let now = Fixtures.referenceDate
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func thread(_ id: String, title: String? = nil, updatedAgo: TimeInterval?) -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            createdAt: nil,
            updatedAt: updatedAgo.map { now.addingTimeInterval(-$0) },
            creatorUserID: "u"
        )
    }

    func testTodayIsTheCalendarDayNotTheLast24Hours() {
        let threads = [
            thread("a", updatedAgo: 9 * 3600 + 20 * 60),      // 00:01 today
            thread("b", updatedAgo: 9 * 3600 + 22 * 60),      // 23:59 yesterday, well inside 24h
            thread("c", updatedAgo: nil),
        ]
        let usage = [
            "a": ThreadUsage(threadID: "a", usage: 1.25),
            "b": ThreadUsage(threadID: "b", usage: 10),
            "c": ThreadUsage(threadID: "c", usage: 10),
        ]

        let glance = Glance.make(threads: threads, usage: usage, awaiting: 0, now: now, calendar: utc)

        XCTAssertEqual(glance.spentTodayUSD, 1.25)
        XCTAssertEqual(glance.spentTodayThreads, 1)
    }

    func testSpendOnlyCountsThreadsWhoseUsageWasLoaded() {
        let threads = [thread("a", updatedAgo: 60), thread("b", updatedAgo: 120)]
        let usage = ["a": ThreadUsage(threadID: "a", usage: 0.4)]

        let glance = Glance.make(threads: threads, usage: usage, awaiting: 0, now: now, calendar: utc)

        XCTAssertEqual(glance.spentTodayUSD, 0.4)
        XCTAssertEqual(glance.spentTodayThreads, 1, "a thread with no usage loaded is not silently $0")
    }

    func testLiveUsesTheActivityWindowAndHeadlineIsTheNewestLiveThread() {
        let threads = [
            thread("old-live", title: "Older", updatedAgo: 80),
            thread("new-live", title: "Newest", updatedAgo: 5),
            thread("recent", title: "Recent", updatedAgo: ThreadActivity.defaultLiveWindow + 1),
        ]

        let glance = Glance.make(threads: threads, usage: [:], awaiting: 2, now: now, calendar: utc)

        XCTAssertEqual(glance.live, 2)
        XCTAssertEqual(glance.headline, "Newest", "list order must not decide the headline")
        XCTAssertEqual(glance.awaiting, 2)
    }

    func testNoLiveThreadMeansNoHeadline() {
        let glance = Glance.make(threads: [thread("a", updatedAgo: 3600)], usage: [:], awaiting: 0, now: now, calendar: utc)
        XCTAssertNil(glance.headline)
        XCTAssertEqual(glance.live, 0)
    }

    func testStaleIsPastMaxAge() {
        let glance = Glance.make(threads: [], usage: [:], awaiting: 0, now: now)
        XCTAssertFalse(glance.isStale(now: now.addingTimeInterval(Glance.maxAge)))
        XCTAssertTrue(glance.isStale(now: now.addingTimeInterval(Glance.maxAge + 1)))
    }

    func testStoreRoundTripsAndRejectsForeignVersions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString)")
        let store = GlanceStore(fileURL: dir.appendingPathComponent("nested/glance.json"))
        XCTAssertNil(store.load(), "missing file reads as nothing")

        let glance = Glance(live: 1, awaiting: 2, spentTodayUSD: 3.5, spentTodayThreads: 4, headline: "Fix CI", updatedAt: now)
        try store.save(glance)
        XCTAssertEqual(store.load(), glance)

        var future = glance
        future.version = Glance.currentVersion + 1
        try store.save(future)
        XCTAssertNil(store.load(), "a newer file shape must not be misread")

        try "not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load())
    }
}

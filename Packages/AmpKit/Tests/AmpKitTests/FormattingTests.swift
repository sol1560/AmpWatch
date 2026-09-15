import XCTest
@testable import AmpKit

final class FormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_480_060)

    func testRelativeTimeSwitchesUnitsAtEachBoundary() {
        XCTAssertEqual(ago(0), "0s")
        XCTAssertEqual(ago(59), "59s")
        XCTAssertEqual(ago(60), "1m")
        XCTAssertEqual(ago(3599), "59m")
        XCTAssertEqual(ago(3600), "1h")
        XCTAssertEqual(ago(86_399), "23h")
        XCTAssertEqual(ago(86_400), "1d")
        XCTAssertEqual(ago(7 * 86_400 - 1), "6d")
        XCTAssertEqual(ago(7 * 86_400), "1w")
    }

    func testRelativeTimeHandlesMissingAndFutureDates() {
        XCTAssertEqual(RelativeTime.short(from: nil, to: now), "—")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(30), to: now), "now")
    }

    func testMoneyKeepsCentsWhereTheyMatterAndDropsThemWhereTheyDoNot() {
        XCTAssertEqual(Money.compact(usd: 0), "$0")
        XCTAssertEqual(Money.compact(usd: 0.004), "<$0.01")
        XCTAssertEqual(Money.compact(usd: 0.01), "$0.01")
        XCTAssertEqual(Money.compact(usd: 1.874), "$1.87")
        XCTAssertEqual(Money.compact(usd: 9.99), "$9.99")
        XCTAssertEqual(Money.compact(usd: 10), "$10")
        XCTAssertEqual(Money.compact(usd: 999), "$999")
        XCTAssertEqual(Money.compact(usd: 1000), "$1.0k")
        XCTAssertEqual(Money.compact(usd: 12_400), "$12.4k")
    }

    func testTokenCountsStayShortEnoughForAWatchRow() {
        XCTAssertEqual(TokenCount.compact(0), "0")
        XCTAssertEqual(TokenCount.compact(999), "999")
        XCTAssertEqual(TokenCount.compact(1000), "1.0k")
        XCTAssertEqual(TokenCount.compact(128_400), "128.4k")
        XCTAssertEqual(TokenCount.compact(2_500_000), "2.5M")
    }

    func testRepositoryShortNameFallsBackInsteadOfCrashing() {
        XCTAssertEqual(Repository(url: "https://github.com/soll/AmpWatch").shortName, "soll/AmpWatch")
        XCTAssertEqual(Repository(url: "https://github.com/soll/AmpWatch.git").shortName, "soll/AmpWatch")
        XCTAssertEqual(Repository(url: "not a url at all").shortName, "not a url at all")
    }

    func testDateParsingAcceptsBothISOForms() {
        let parser = DateParsing()
        let withFraction = parser.date(from: "2026-03-14T09:41:00.000Z")
        let withoutFraction = parser.date(from: "2026-03-14T09:41:00Z")

        XCTAssertNotNil(withFraction)
        XCTAssertEqual(withFraction, withoutFraction)
        XCTAssertNil(parser.date(from: "yesterday"))
    }

    private func ago(_ seconds: TimeInterval) -> String {
        RelativeTime.short(from: now.addingTimeInterval(-seconds), to: now)
    }
}

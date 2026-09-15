import XCTest
@testable import AmpKit

final class LocalizationTests: XCTestCase {
    func testEnglishAndSimplifiedChineseResourcesArePackaged() {
        XCTAssertEqual(AmpStrings.text("error.no_connection", localeIdentifier: "en"), "No connection")
        XCTAssertEqual(AmpStrings.text("error.no_connection", localeIdentifier: "zh-Hans"), "无网络连接")
        XCTAssertEqual(AmpStrings.text("mode.high", localeIdentifier: "zh-Hans"), "高")
    }

    func testMissingKeyFallsBackToKeyRatherThanServerText() {
        XCTAssertEqual(AmpStrings.text("localization.missing", localeIdentifier: "zh-Hans"), "localization.missing")
    }
}

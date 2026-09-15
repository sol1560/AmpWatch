import XCTest
@testable import AmpKit

final class ThreadMessageTests: XCTestCase {
    private let dates = DateParsing()

    func testStableFieldsSurviveUnknownSiblingFields() throws {
        // The API documents every field except messageID/messageVersion/createdAt
        // as unstable, so unrecognised siblings must not break extraction.
        let message = extract("""
        {
          "messageID": "msg_42",
          "messageVersion": 3,
          "createdAt": "2026-03-14T09:41:00.000Z",
          "role": "assistant",
          "content": [{"type": "text", "text": "Booted the simulator."}],
          "someFieldInventedNextQuarter": {"nested": [1, 2, 3]},
          "anotherOne": true
        }
        """)

        XCTAssertEqual(message.id, "msg_42")
        XCTAssertEqual(message.version, 3)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.text, "Booted the simulator.")
        XCTAssertEqual(message.createdAt, dates.date(from: "2026-03-14T09:41:00.000Z"))
    }

    func testNonTextBlocksAreSkippedAndTextBlocksJoined() throws {
        // A tool call rendered verbatim would fill a 40mm screen with JSON.
        let message = extract("""
        {
          "messageID": "msg_1",
          "role": "assistant",
          "content": [
            {"type": "text", "text": "Running the tests."},
            {"type": "tool_use", "name": "bash", "input": {"cmd": "swift test"}},
            {"type": "text", "text": "All green."}
          ]
        }
        """)

        XCTAssertEqual(message.text, "Running the tests.\nAll green.")
    }

    func testToolOnlyMessageHasNoText() {
        let message = extract("""
        {"messageID": "msg_2", "role": "assistant",
         "content": [{"type": "tool_use", "name": "bash"}]}
        """)

        XCTAssertNil(message.text)
        XCTAssertEqual(message.role, .assistant)
    }

    func testPlainStringContentAndBareTextFallback() {
        XCTAssertEqual(
            extract(#"{"messageID": "a", "role": "user", "content": "ship it"}"#).text,
            "ship it"
        )
        XCTAssertEqual(
            extract(#"{"messageID": "b", "role": "user", "text": "ship it"}"#).text,
            "ship it"
        )
    }

    func testWhitespaceOnlyContentIsTreatedAsNoText() {
        XCTAssertNil(extract(#"{"messageID": "c", "content": "   \n  "}"#).text)
    }

    func testUnrecognisedRoleDegradesToUnknown() {
        XCTAssertEqual(extract(#"{"messageID": "d", "role": "tool"}"#).role, .unknown)
        XCTAssertEqual(extract(#"{"messageID": "e"}"#).role, .unknown)
    }

    func testMessagesWithoutIDsStayDistinguishable() {
        // A constant placeholder id would collapse every such row into one in
        // a SwiftUI List.
        let first = extract(#"{"role": "user", "content": "one"}"#, index: 0)
        let second = extract(#"{"role": "user", "content": "two"}"#, index: 1)

        XCTAssertNotEqual(first.id, second.id)
    }

    func testUnparseableCreatedAtDoesNotDiscardTheMessage() {
        let message = extract(#"{"messageID": "f", "createdAt": "March 14", "content": "hi"}"#)

        XCTAssertNil(message.createdAt)
        XCTAssertEqual(message.text, "hi")
    }

    private func extract(_ json: String, index: Int = 0) -> ThreadMessage {
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return ThreadMessage.extract(from: value, index: index, dates: dates)
    }
}

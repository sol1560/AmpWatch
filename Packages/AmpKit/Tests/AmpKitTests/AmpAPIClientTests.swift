import XCTest
@testable import AmpKit

final class AmpAPIClientTests: XCTestCase {
    private let base = URL(string: "https://amp.test/api/v2")!

    // MARK: - Request shape

    func testThreadRequestCarriesBearerTokenAndOmitsAbsentCursor() async throws {
        let transport = StubTransport(json: #"{"threads": []}"#)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("tok_123"))

        _ = try await client.threads(limit: 25, cursor: nil)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/api/v2/threads")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok_123")

        let query = transport.queryItems(of: request)
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["sort"], "DESC")
        // An empty `cursor=` would be sent as a real cursor by the server.
        XCTAssertNil(query["cursor"])
    }

    func testThreadRequestForwardsCursorWhenPaging() async throws {
        let transport = StubTransport(json: #"{"threads": []}"#)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        _ = try await client.threads(limit: 10, cursor: "cur_abc")

        XCTAssertEqual(transport.queryItems(of: try XCTUnwrap(transport.lastRequest))["cursor"], "cur_abc")
    }

    func testThreadIDIsPercentEncodedIntoThePath() async throws {
        let transport = StubTransport(json: #"{"messages": []}"#)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        _ = try await client.messages(threadID: "T-abc", limit: 5, cursor: nil)

        XCTAssertEqual(try XCTUnwrap(transport.lastRequest).url.path, "/api/v2/threads/T-abc/messages")
    }

    // MARK: - Decoding

    func testThreadListDecodesWithoutScopeGatedFields() async throws {
        // Without `threads.contents:view` the server omits title and
        // repositories entirely; those threads must still list.
        let transport = StubTransport(json: """
        {
          "nextCursor": "cur_next",
          "threads": [
            {
              "id": "T-1",
              "createdAt": "2026-03-14T08:00:00.000Z",
              "updatedAt": "2026-03-14T09:40:00Z",
              "creatorUserID": "user_1",
              "subThreads": []
            },
            {
              "id": "T-2",
              "title": "Trim the bundle",
              "creatorUserID": "user_1",
              "repositories": [{"url": "https://github.com/soll/storefront"}],
              "subThreads": [null]
            }
          ]
        }
        """)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        let page = try await client.threads(limit: 50, cursor: nil)

        XCTAssertEqual(page.nextCursor, "cur_next")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNil(page.items[0].title)
        XCTAssertEqual(page.items[0].displayTitle, "T-1")
        // Mixed fractional and whole-second timestamps in one payload.
        XCTAssertEqual(page.items[0].updatedAt, DateParsing().date(from: "2026-03-14T09:40:00Z"))
        XCTAssertEqual(page.items[1].repositories.first?.shortName, "soll/storefront")
        XCTAssertEqual(page.items[1].subThreads, [])
    }

    func testNullMessageEntriesAreDroppedRatherThanFailingThePage() async throws {
        // The API's own example response is `"messages": [null]`.
        let transport = StubTransport(json: """
        {"messages": [null, {"messageID": "m1", "role": "user", "content": "hi"}]}
        """)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        let page = try await client.messages(threadID: "T-1", limit: 50, cursor: nil)

        XCTAssertEqual(page.items.map(\.id), ["m1"])
    }

    func testUsageDecodesAndOrdersModelsBySpend() async throws {
        let transport = StubTransport(json: """
        {
          "threadID": "T-1",
          "subThreadIDs": ["T-1a"],
          "usage": 1.87,
          "models": [
            {"provider": "openai", "model": "gpt-5.6", "requests": 11,
             "inputTokens": 44100, "outputTokens": 6050,
             "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "usage": 0.45},
            {"provider": "anthropic", "model": "claude-fable-5.1", "requests": 42,
             "inputTokens": 128400, "outputTokens": 18200,
             "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "usage": 1.42}
          ]
        }
        """)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        let usage = try await client.usage(threadID: "T-1")

        XCTAssertEqual(usage.usage, 1.87, accuracy: 0.0001)
        XCTAssertEqual(usage.modelsByCost.map(\.model), ["claude-fable-5.1", "gpt-5.6"])
    }

    // MARK: - Errors

    func testStatusCodesMapToTypedErrors() async throws {
        await assertThrows(status: 401, json: #"{"error": "nope"}"#, expected: .unauthorized)
        await assertThrows(
            status: 403,
            json: #"{"error": "missing scope amp.api:workspace.threads.contents:view"}"#,
            expected: .forbidden("missing scope amp.api:workspace.threads.contents:view")
        )
        await assertThrows(status: 404, json: #"{"error": "gone"}"#, expected: .notFound)
        await assertThrows(status: 500, json: #"{"error": "boom"}"#, expected: .server(status: 500, message: "boom"))
    }

    func testRateLimitCarriesRetryAfterFromALowercasedHeader() async {
        let transport = StubTransport(
            status: 429,
            json: #"{"error": "slow down"}"#,
            headers: ["retry-after": "120"]
        )
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        do {
            _ = try await client.threads(limit: 1, cursor: nil)
            XCTFail("expected a rate limit error")
        } catch {
            XCTAssertEqual(error as? AmpError, .rateLimited(retryAfter: 120))
        }
    }

    func testMalformedBodySurfacesAsDecodingNotAsSuccess() async {
        let transport = StubTransport(json: #"{"threads": "not an array"}"#)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))

        do {
            _ = try await client.threads(limit: 1, cursor: nil)
            XCTFail("expected a decoding error")
        } catch {
            guard case .decoding = (error as? AmpError) else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }

    private func assertThrows(
        status: Int,
        json: String,
        expected: AmpError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let transport = StubTransport(status: status, json: json)
        let client = AmpAPIClient(baseURL: base, transport: transport, tokens: StaticAccessToken("t"))
        do {
            _ = try await client.threads(limit: 1, cursor: nil)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AmpError, expected, file: file, line: line)
        }
    }
}

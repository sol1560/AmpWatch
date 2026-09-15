import XCTest
@testable import AmpKit

/// A thread-safe counter, so the idempotency-key factory can stay `@Sendable`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class WebhookPromptSinkTests: XCTestCase {
    private let webhook = URL(string: "https://webhooks.amp.test/w/secret-capability")!

    func testPostsTrimmedPromptWithIdempotencyKey() async throws {
        let transport = StubTransport(responses: [HTTPResponse(status: 202)])
        let sink = WebhookPromptSink(
            webhookURL: webhook,
            transport: transport,
            makeIdempotencyKey: { "key-1" }
        )

        try await sink.send(prompt: "  run the tests\n", to: "T-1")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, webhook)
        XCTAssertEqual(request.headers["Idempotency-Key"], "key-1")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let body = try JSONDecoder().decode(
            [String: String].self,
            from: try XCTUnwrap(request.body)
        )
        XCTAssertEqual(body, ["type": "steer", "threadID": "T-1", "prompt": "run the tests"])
    }

    func testEveryCommandHasTheWireShapeThePluginParses() async throws {
        let transport = StubTransport(responses: Array(repeating: HTTPResponse(status: 202), count: 4))
        let sink = WebhookPromptSink(webhookURL: webhook, transport: transport)

        try await sink.send(.prompt(threadID: "T-1", text: "go", steer: false), idempotencyKey: "outbox-7")
        try await sink.send(.cancel(threadID: "T-1"), idempotencyKey: nil)
        try await sink.send(.create(prompt: "new thread", mode: .high), idempotencyKey: nil)
        try await sink.send(.decide(approvalID: "call-9", threadID: "T-1", decision: .reject), idempotencyKey: nil)

        let bodies = try transport.requests.map {
            try JSONDecoder().decode([String: String].self, from: try XCTUnwrap($0.body))
        }
        XCTAssertEqual(bodies, [
            ["type": "prompt", "threadID": "T-1", "prompt": "go"],
            ["type": "cancel", "threadID": "T-1"],
            ["type": "create", "prompt": "new thread", "mode": "high"],
            ["type": "decide", "approvalID": "call-9", "threadID": "T-1", "decision": "reject"],
        ])
        // An outbox retry reuses its item ID so Amp can collapse duplicates.
        XCTAssertEqual(transport.requests[0].headers["Idempotency-Key"], "outbox-7")
    }

    func testEachSendGetsAFreshIdempotencyKey() async throws {
        let transport = StubTransport(responses: [
            HTTPResponse(status: 202),
            HTTPResponse(status: 202),
        ])
        let counter = Counter()
        let sink = WebhookPromptSink(webhookURL: webhook, transport: transport) {
            "key-\(counter.next())"
        }

        try await sink.send(prompt: "one", to: "T-1")
        try await sink.send(prompt: "two", to: "T-1")

        // Reusing a key would make Amp silently drop the second prompt as a
        // duplicate retry.
        XCTAssertEqual(
            transport.requests.compactMap { $0.headers["Idempotency-Key"] },
            ["key-1", "key-2"]
        )
    }

    func testBlankPromptIsNotSentAtAll() async throws {
        let transport = StubTransport(responses: [])
        let sink = WebhookPromptSink(webhookURL: webhook, transport: transport)

        try await sink.send(prompt: "   \n ", to: "T-1")

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRateLimitIsSurfacedWithItsRetryAfter() async {
        let transport = StubTransport(responses: [
            HTTPResponse(status: 429, headers: ["Retry-After": "6"], body: Data()),
        ])
        let sink = WebhookPromptSink(webhookURL: webhook, transport: transport)

        do {
            try await sink.send(prompt: "again", to: "T-1")
            XCTFail("expected a rate limit error")
        } catch {
            XCTAssertEqual(error as? AmpError, .rateLimited(retryAfter: 6))
        }
    }
}

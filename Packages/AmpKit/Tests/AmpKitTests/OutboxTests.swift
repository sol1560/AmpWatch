import XCTest
@testable import AmpKit

/// Records what a flush attempted, and can be told to fail on demand.
private final class Sender: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (seen: [String](), failUntilAttempt: 0, failOnCall: 0, attempt: 0)

    init(failFirst: Int = 0, failOnCall: Int = 0) {
        state.failUntilAttempt = failFirst
        state.failOnCall = failOnCall
    }

    var seen: [String] { lock.withLock { state.seen } }

    func send(_ item: OutboxItem) throws {
        try lock.withLock {
            state.attempt += 1
            if state.attempt <= state.failUntilAttempt || state.attempt == state.failOnCall {
                throw AmpError.transport("offline")
            }
            state.seen.append(item.id)
        }
    }
}

/// A settable clock the outbox can read from a `@Sendable` closure.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_773_480_060)

final class OutboxTests: XCTestCase {

    private func prompt(_ id: String, _ text: String, at offset: TimeInterval = 0) -> OutboxItem {
        OutboxItem(
            id: id,
            command: .prompt(threadID: "T-1", text: text),
            createdAt: t0.addingTimeInterval(offset)
        )
    }

    func testQueuedPromptsArriveInOrderExactlyOnce() async {
        // The scenario this type exists for: three prompts written with no
        // link, then one reconnect.
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))
        await outbox.enqueue(prompt("c", "three"))

        let sender = Sender()
        let result = await outbox.flush { try sender.send($0) }

        XCTAssertEqual(sender.seen, ["a", "b", "c"])
        XCTAssertEqual(result.delivered, ["a", "b", "c"])
        XCTAssertEqual(result.remaining, 0)
    }

    func testAFailedFlushDeliversNothingTwiceOnTheNextAttempt() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))
        await outbox.enqueue(prompt("c", "three"))

        // Succeeds on "a", then the link drops mid-flush.
        let flaky = Sender(failOnCall: 2)
        let first = await outbox.flush { try flaky.send($0) }
        XCTAssertEqual(first.delivered, ["a"])
        XCTAssertEqual(first.remaining, 2)

        let second = Sender()
        let result = await outbox.flush { try second.send($0) }

        // "a" must not be re-sent: the user would see a duplicate prompt.
        XCTAssertEqual(second.seen, ["b", "c"])
        XCTAssertEqual(result.delivered, ["b", "c"])
    }

    func testOrderIsPreservedWhenTheFirstItemFails() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))

        // Fails outright, so nothing is delivered and nothing is reordered.
        _ = await outbox.flush { _ in throw AmpError.transport("offline") }

        let sender = Sender()
        _ = await outbox.flush { try sender.send($0) }
        XCTAssertEqual(sender.seen, ["a", "b"])
    }

    func testEnqueuingTheSameIDTwiceDoesNotDuplicateOrReorder() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))
        await outbox.enqueue(prompt("a", "one"))

        let sender = Sender()
        _ = await outbox.flush { try sender.send($0) }

        XCTAssertEqual(sender.seen, ["a", "b"])
    }

    func testChangingYourMindSendsOneDecisionNotTwo() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueueDecision(id: "d1", approvalID: "call-1", threadID: "T-1", decision: .approve)
        await outbox.enqueueDecision(id: "d2", approvalID: "call-1", threadID: "T-1", decision: .reject)

        let pending = await outbox.pending
        XCTAssertEqual(pending.count, 1)
        guard case let .decide(_, _, decision) = pending[0].command else {
            return XCTFail("expected a decision")
        }
        XCTAssertEqual(decision, .reject)
    }

    func testDecisionsForDifferentApprovalsCoexist() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueueDecision(id: "d1", approvalID: "call-1", threadID: "T-1", decision: .approve)
        await outbox.enqueueDecision(id: "d2", approvalID: "call-2", threadID: "T-1", decision: .approve)

        let count = await outbox.count
        XCTAssertEqual(count, 2)
    }

    func testAStaleDecisionIsDroppedRatherThanApplied() async {
        // The agent stopped waiting long ago. Delivering this could approve
        // some later tool call the user never saw.
        let clock = Clock(t0)
        let outbox = Outbox(now: { clock.now })
        await outbox.enqueueDecision(id: "d1", approvalID: "call-1", threadID: "T-1", decision: .approve)

        clock.now = t0.addingTimeInterval(Outbox.decisionTTL + 1)

        let sender = Sender()
        let result = await outbox.flush { try sender.send($0) }

        XCTAssertTrue(sender.seen.isEmpty)
        XCTAssertEqual(result.dropped.map(\.id), ["d1"])
        XCTAssertEqual(result.dropped.map(\.reason), [.expired])
    }

    func testAPromptNeverExpires() async {
        // Unlike a decision, a prompt written hours ago is still what the user
        // wants to say.
        let clock = Clock(t0)
        let outbox = Outbox(now: { clock.now })
        await outbox.enqueue(prompt("a", "one"))

        clock.now = t0.addingTimeInterval(Outbox.decisionTTL * 10)

        let sender = Sender()
        let result = await outbox.flush { try sender.send($0) }
        XCTAssertEqual(result.delivered, ["a"])
    }

    func testAPoisonItemIsDroppedAndDoesNotBlockTheQueue() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("bad", "poison"))
        await outbox.enqueue(prompt("good", "fine"))

        let sender = Sender()
        var result = OutboxFlush(delivered: [], dropped: [], remaining: 0)
        for _ in 0..<Outbox.maxAttempts {
            result = await outbox.flush { item in
                if item.id == "bad" { throw AmpError.server(status: 400, message: "malformed") }
                try sender.send(item)
            }
        }

        XCTAssertEqual(result.dropped.map(\.reason), [.exhausted])
        // The healthy item behind it still goes out.
        XCTAssertEqual(sender.seen, ["good"])
        XCTAssertEqual(result.remaining, 0)
    }
}

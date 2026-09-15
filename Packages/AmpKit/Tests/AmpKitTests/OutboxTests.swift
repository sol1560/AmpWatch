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
            command: .prompt(threadID: "T-1", text: text, steer: true),
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

    private func decision(_ id: String, approval: String, _ decision: ApprovalDecision, heldAt: Date = t0) -> OutboxItem {
        OutboxItem(
            id: id,
            command: .decide(approvalID: approval, threadID: "T-1", decision: decision, requestedAt: heldAt),
            createdAt: t0
        )
    }

    private func enqueueDecision(_ item: OutboxItem, into outbox: Outbox) async {
        await outbox.enqueue(item) { Outbox.supersedes(item.command, $0.command) }
    }

    func testChangingYourMindSendsOneDecisionNotTwo() async {
        let outbox = Outbox(now: { t0 })
        await enqueueDecision(decision("d1", approval: "call-1", .approve), into: outbox)
        await enqueueDecision(decision("d2", approval: "call-1", .reject), into: outbox)

        let pending = await outbox.pending
        XCTAssertEqual(pending.count, 1)
        guard case let .decide(_, _, decision, _) = pending[0].command else {
            return XCTFail("expected a decision")
        }
        XCTAssertEqual(decision, .reject)
    }

    func testDecisionsForDifferentApprovalsCoexist() async {
        let outbox = Outbox(now: { t0 })
        await enqueueDecision(decision("d1", approval: "call-1", .approve), into: outbox)
        await enqueueDecision(decision("d2", approval: "call-2", .approve), into: outbox)

        let count = await outbox.count
        XCTAssertEqual(count, 2)
    }

    func testAStaleDecisionIsDroppedRatherThanApplied() async {
        // The agent stopped waiting long ago. Delivering this could approve
        // some later tool call the user never saw.
        let clock = Clock(t0)
        let outbox = Outbox(now: { clock.now })
        await enqueueDecision(decision("d1", approval: "call-1", .approve), into: outbox)

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

    func testTheLatestArmLevelReplacesAQueuedOne() async {
        let outbox = Outbox(now: { t0 })
        let all = OutboxItem(id: "a1", command: .arm(threadID: "T-1", level: .all), createdAt: t0)
        let off = OutboxItem(id: "a2", command: .arm(threadID: "T-1", level: .off), createdAt: t0)
        let other = OutboxItem(id: "a3", command: .arm(threadID: "T-2", level: .risky), createdAt: t0)
        await outbox.enqueue(all) { Outbox.supersedes(all.command, $0.command) }
        await outbox.enqueue(other) { Outbox.supersedes(other.command, $0.command) }
        await outbox.enqueue(off) { Outbox.supersedes(off.command, $0.command) }

        let pending = await outbox.pending
        // T-1's "all" is gone; T-2's level is untouched; "off" is newest.
        XCTAssertEqual(pending.map(\.id), ["a3", "a2"])
    }

    func testBeingOfflineDoesNotUseUpAnItemsAttempts() async {
        // Three prompts in airplane mode, then many wrist raises before the
        // Wi-Fi is back: each raise is a flush, and each must leave the queue
        // exactly as it was.
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))
        await outbox.enqueue(prompt("c", "three"))

        for _ in 0..<(Outbox.maxAttempts * 3) {
            _ = await outbox.flush { _ in throw AmpError.transport("offline") }
        }
        let attempts = await outbox.pending.map(\.attempts)
        XCTAssertEqual(attempts, [0, 0, 0])

        let sender = Sender()
        let result = await outbox.flush { try sender.send($0) }
        XCTAssertEqual(result.delivered, ["a", "b", "c"])
    }

    func testAServerThatSaysNoCountsButABusyOneDoesNot() async {
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        _ = await outbox.flush { _ in throw AmpError.rateLimited(retryAfter: 5) }
        _ = await outbox.flush { _ in throw AmpError.server(status: 503, message: nil) }
        var attempts = await outbox.pending.map(\.attempts)
        XCTAssertEqual(attempts, [0])

        _ = await outbox.flush { _ in throw AmpError.server(status: 400, message: "bad") }
        _ = await outbox.flush { _ in throw AmpError.unauthorized }
        attempts = await outbox.pending.map(\.attempts)
        XCTAssertEqual(attempts, [2])
    }

    func testTwoOverlappingFlushesSendEachItemOnceInOrder() async {
        // The retry timer fires while a wrist-raise flush is mid-send. Both
        // pass over the same queue; a re-entrant loop would send "a" twice
        // and then remove "b" without sending it.
        let outbox = Outbox(now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))
        await outbox.enqueue(prompt("c", "three"))

        let gate = Gate()
        gate.close()
        let log = Sender()
        let send: @Sendable (OutboxItem) async throws -> Void = { item in
            await gate.pass()
            try log.send(item)
        }
        let first = Task { await outbox.flush(send) }
        await gate.waitUntilBlocked()
        let second = Task { await outbox.flush(send) }
        // Let the second flush line up behind the first before releasing it.
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()
        let results = await (first.value, second.value)

        XCTAssertEqual(log.seen, ["a", "b", "c"])
        XCTAssertEqual(results.0.delivered, ["a", "b", "c"])
        XCTAssertEqual(results.1.delivered, [])
        let remaining = await outbox.count
        XCTAssertEqual(remaining, 0)
    }

    func testAMindChangedWhileTheOldDecisionIsInFlightStillGetsSent() async {
        // Approve is on the wire; the user taps Reject before the reply comes
        // back. The reject replaces the approve in the queue. When the approve
        // send returns, the drain must remove *that* item, not whatever is now
        // first — which is the reject the user still wants delivered.
        let outbox = Outbox(now: { t0 })
        await enqueueDecision(decision("d1", approval: "call-1", .approve), into: outbox)

        let gate = Gate()
        gate.close()
        let log = Sender()
        let send: @Sendable (OutboxItem) async throws -> Void = { item in
            await gate.pass()
            try log.send(item)
        }
        let first = Task { await outbox.flush(send) }
        await gate.waitUntilBlocked()
        await enqueueDecision(decision("d2", approval: "call-1", .reject), into: outbox)
        gate.open()
        let result = await first.value

        // The same pass keeps going and picks up the reject; nothing is lost.
        XCTAssertEqual(log.seen, ["d1", "d2"])
        XCTAssertEqual(result.delivered, ["d1", "d2"])
        let remaining = await outbox.count
        XCTAssertEqual(remaining, 0)
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

    func testQueueSurvivesARestartFromTheSameFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Outbox(fileURL: file, now: { t0 })
        await first.enqueue(prompt("a", "dictated in a stairwell"))
        await first.enqueue(prompt("b", "then another"))

        // A new instance is what a killed-and-relaunched app gets.
        let second = Outbox(fileURL: file, now: { t0 })
        let pending = await second.pending
        XCTAssertEqual(pending.map(\.id), ["a", "b"])
        XCTAssertEqual(pending.first?.command, .prompt(threadID: "T-1", text: "dictated in a stairwell", steer: true))

        // Delivery on the new instance must clear the file too, or the next
        // launch re-sends what already went.
        let sender = Sender()
        _ = await second.flush { try sender.send($0) }
        let third = await Outbox(fileURL: file, now: { t0 }).count
        XCTAssertEqual(third, 0)
    }

    func testTheFileForgetsAnItemTheMomentItIsDelivered() async {
        // A kill between two accepted sends must not re-send the first on
        // the next launch, so the file is written after every delivery,
        // not once at the end of the pass.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outbox = Outbox(fileURL: file, now: { t0 })
        await outbox.enqueue(prompt("a", "one"))
        await outbox.enqueue(prompt("b", "two"))

        _ = await outbox.flush { item in
            if item.id == "b" {
                // "a" was accepted; the app dies before "b" goes out.
                let onDisk = await Outbox(fileURL: file, now: { t0 }).pending.map(\.id)
                XCTAssertEqual(onDisk, ["b"])
                throw AmpError.transport("killed")
            }
        }
    }
}

import Foundation

/// Something the user asked for that must reach Amp eventually.
public struct OutboxItem: Sendable, Hashable, Identifiable, Codable {
    public typealias Command = WatchCommand

    public let id: String
    public let command: Command
    public let createdAt: Date
    /// Number of failed delivery attempts so far.
    public private(set) var attempts: Int

    public init(id: String, command: Command, createdAt: Date, attempts: Int = 0) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
        self.attempts = attempts
    }

    func retried() -> OutboxItem {
        OutboxItem(id: id, command: command, createdAt: createdAt, attempts: attempts + 1)
    }
}

/// Why an item left the outbox without being delivered.
public enum OutboxDrop: Sendable, Equatable {
    /// Too many failed attempts.
    case exhausted
    /// The decision is no longer meaningful — the agent stopped waiting.
    case expired
}

public struct OutboxFlush: Sendable, Equatable {
    public let delivered: [String]
    public let dropped: [(id: String, reason: OutboxDrop)]
    public let remaining: Int

    public static func == (lhs: OutboxFlush, rhs: OutboxFlush) -> Bool {
        lhs.delivered == rhs.delivered
            && lhs.remaining == rhs.remaining
            && lhs.dropped.count == rhs.dropped.count
            && zip(lhs.dropped, rhs.dropped).allSatisfy { $0.id == $1.id && $0.reason == $1.reason }
    }
}

/// A durable, ordered, exactly-once-per-item queue of commands.
///
/// This exists because the watch loses its link constantly — wrist down, out of
/// Bluetooth range, captive Wi-Fi — and a prompt the user dictated must not
/// vanish, nor arrive twice because a reply was lost rather than the request.
///
/// Delivery is **in order and one at a time**. A prompt that lands out of order
/// changes what the agent does, so a parallel flush would be wrong even though
/// it would be faster.
public actor Outbox {
    /// Attempts before an item is dropped rather than retried forever.
    public static let maxAttempts = 5

    /// How long an approval stays meaningful.
    ///
    /// The bridge rejects a held call nobody decided within
    /// `APPROVAL_TIMEOUT_MS` (10 minutes in `Plugin/amp-watch-bridge.ts`), so a
    /// decision older than that would land on nothing. Keep the two in step.
    public static let decisionTTL: TimeInterval = 10 * 60

    private var items: [OutboxItem] = []
    private let now: @Sendable () -> Date
    /// Where the queue survives an app kill. `nil` keeps it in memory only,
    /// which is what tests and screenshots want.
    private let fileURL: URL?

    public init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            // A file this app cannot read any more (older schema, corruption)
            // is worth less than a working queue; start empty rather than
            // refuse to launch.
            items = (try? JSONDecoder().decode([OutboxItem].self, from: data)) ?? []
        }
    }

    /// Writes the queue after every change, so the on-disk copy is never
    /// behind what the user was told is queued.
    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // Losing durability is bad; crashing while the user is dictating
            // is worse. The in-memory queue still delivers this session.
        }
    }

    public var pending: [OutboxItem] { items }
    public var count: Int { items.count }

    /// Enqueues a command.
    ///
    /// Re-enqueuing the same `id` replaces the existing item in place rather
    /// than appending, so a retry from a flaky UI cannot duplicate a prompt or
    /// reorder the queue.
    public func enqueue(_ item: OutboxItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist()
    }

    /// Replaces any queued decision for the same approval.
    ///
    /// Changing your mind before the link returns must send one decision, not
    /// two contradictory ones.
    public func enqueueDecision(id: String, approvalID: String, threadID: String, decision: ApprovalDecision) {
        items.removeAll {
            if case let .decide(existing, _, _) = $0.command { return existing == approvalID }
            return false
        }
        items.append(OutboxItem(
            id: id,
            command: .decide(approvalID: approvalID, threadID: threadID, decision: decision),
            createdAt: now()
        ))
        persist()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Attempts delivery of every queued item, oldest first.
    ///
    /// Stops at the first failure and keeps the rest queued, preserving order.
    /// `send` must be idempotent on the item's `id`: an item whose send throws
    /// may already have been applied upstream, and is retried.
    @discardableResult
    public func flush(_ send: @Sendable (OutboxItem) async throws -> Void) async -> OutboxFlush {
        var delivered: [String] = []
        var dropped: [(id: String, reason: OutboxDrop)] = []

        while let item = items.first {
            if isExpired(item) {
                items.removeFirst()
                dropped.append((item.id, .expired))
                continue
            }

            do {
                try await send(item)
                items.removeFirst()
                delivered.append(item.id)
            } catch {
                let retried = item.retried()
                if retried.attempts >= Self.maxAttempts {
                    items.removeFirst()
                    dropped.append((item.id, .exhausted))
                    // A poison item must not block the queue behind it.
                    continue
                }
                items[0] = retried
                break
            }
        }

        persist()
        return OutboxFlush(delivered: delivered, dropped: dropped, remaining: items.count)
    }

    private func isExpired(_ item: OutboxItem) -> Bool {
        guard case .decide = item.command else { return false }
        return now().timeIntervalSince(item.createdAt) > Self.decisionTTL
    }
}

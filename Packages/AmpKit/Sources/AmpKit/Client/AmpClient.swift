import Foundation

public struct Page<Element: Sendable>: Sendable {
    public let items: [Element]
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Everything the watch can read. Backed by `GET /api/v2/...`, which is
/// read-only: the External API has no endpoint for sending a message.
public protocol AmpClient: Sendable {
    func threads(limit: Int, cursor: String?) async throws -> Page<ThreadSummary>
    func messages(threadID: String, limit: Int, cursor: String?) async throws -> Page<ThreadMessage>
    func usage(threadID: String) async throws -> ThreadUsage
}

extension AmpClient {
    public func threads(limit: Int = 25) async throws -> Page<ThreadSummary> {
        try await threads(limit: limit, cursor: nil)
    }

    public func messages(threadID: String, limit: Int = 25) async throws -> Page<ThreadMessage> {
        try await messages(threadID: threadID, limit: limit, cursor: nil)
    }
}

/// Everything the watch can write. Deliberately a separate protocol from
/// `AmpClient` because reads and writes travel over different channels with
/// different credentials: reads go to the External API, writes go to an Amp
/// plugin webhook.
public protocol AmpPromptSink: Sendable {
    /// Delivers one command. `idempotencyKey` lets a retry of the same
    /// user action (an outbox item) be deduplicated upstream; pass `nil` for
    /// a fresh action.
    func send(_ command: WatchCommand, idempotencyKey: String?) async throws
}

extension AmpPromptSink {
    /// Steering prompt to a thread, the common case from the wrist.
    public func send(prompt: String, to threadID: String) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await send(.prompt(threadID: threadID, text: trimmed, steer: true), idempotencyKey: nil)
    }
}

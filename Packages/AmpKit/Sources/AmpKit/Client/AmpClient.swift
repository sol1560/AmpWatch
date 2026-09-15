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
    func send(prompt: String, to threadID: String) async throws
}

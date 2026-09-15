import Foundation

/// What the app can do with the secrets it currently holds.
///
/// Built from a `SecretStore` in one place so the rule "no token → set-up
/// screen, token → live client, URL → write path" is testable on Linux and the
/// views never look at raw secrets.
public enum AmpSession: Sendable {
    case needsSetup
    case ready(client: any AmpClient, promptSink: (any AmpPromptSink)?)

    public static func load(
        from secrets: any SecretStore,
        transport: any HTTPTransport,
        baseURL: URL = AmpAPIClient.productionBaseURL
    ) -> AmpSession {
        guard let token = Self.nonEmpty(try? secrets.read(.accessToken)) else {
            return .needsSetup
        }

        let client = AmpAPIClient(
            baseURL: baseURL,
            transport: transport,
            tokens: StaticAccessToken(token)
        )
        let sink = Self.webhookURL(from: secrets).map {
            WebhookPromptSink(webhookURL: $0, transport: transport)
        }
        return .ready(client: client, promptSink: sink)
    }

    /// The bridge URL is optional and may have been typed by hand; anything
    /// that is not an absolute https URL is treated as unset rather than
    /// letting a malformed value surface as a transport error later.
    public static func webhookURL(from secrets: any SecretStore) -> URL? {
        guard let raw = nonEmpty(try? secrets.read(.webhookURL)),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }

    /// The client to hand out while in `.needsSetup`, so views that are never
    /// shown in that state still have a well-typed environment. Every call
    /// fails the way a missing token would fail on the server.
    public struct UnconfiguredClient: AmpClient {
        public init() {}
        public func threads(limit: Int, cursor: String?) async throws -> Page<ThreadSummary> {
            throw AmpError.unauthorized
        }
        public func messages(threadID: String, limit: Int, cursor: String?) async throws -> Page<ThreadMessage> {
            throw AmpError.unauthorized
        }
        public func usage(threadID: String) async throws -> ThreadUsage {
            throw AmpError.unauthorized
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    private static func nonEmpty(_ value: String??) -> String? {
        guard let value, let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

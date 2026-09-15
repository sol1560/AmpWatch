import Foundation

/// Sends a prompt to a thread through an Amp plugin webhook.
///
/// The External API cannot write to a thread, and the plugin webhook handler
/// signature is `(event, ctx) => void | Promise<void>` — it returns no body.
/// So this channel is strictly fire-and-forget: a 2xx means Amp accepted the
/// event for at-least-once delivery, not that the agent has replied. The
/// matching plugin lives in `Plugin/amp-watch-bridge.ts`.
///
/// The webhook URL is a capability URL. Treat it as a password: Keychain only,
/// never logged, never committed.
public struct WebhookPromptSink: AmpPromptSink {
    private let webhookURL: URL
    private let transport: any HTTPTransport
    private let makeIdempotencyKey: @Sendable () -> String

    public init(
        webhookURL: URL,
        transport: any HTTPTransport,
        makeIdempotencyKey: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.webhookURL = webhookURL
        self.transport = transport
        self.makeIdempotencyKey = makeIdempotencyKey
    }

    public func send(_ command: WatchCommand, idempotencyKey: String?) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = idempotencyKey ?? makeIdempotencyKey()
        // The key travels in the body too: the bridge forwards `arm` and
        // `decide` to a second webhook under a fresh event ID, and dedupes
        // that hop on `commandID`.
        var body = command.wireObject
        body["commandID"] = key
        let request = HTTPRequest(
            method: "POST",
            url: webhookURL,
            headers: [
                "Content-Type": "application/json",
                // Amp deduplicates retries by this key without consuming rate
                // capacity, so a flaky watch radio does not double-prompt.
                "Idempotency-Key": key,
            ],
            body: try encoder.encode(body)
        )

        let response = try await transport.send(request)
        if let error = AmpError.from(response: response) { throw error }
    }
}

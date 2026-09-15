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

    public func send(prompt: String, to threadID: String) async throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let payload = Payload(threadID: threadID, prompt: trimmed)
        let request = HTTPRequest(
            method: "POST",
            url: webhookURL,
            headers: [
                "Content-Type": "application/json",
                // Amp deduplicates retries by this key without consuming rate
                // capacity, so a flaky watch radio does not double-prompt.
                "Idempotency-Key": makeIdempotencyKey(),
            ],
            body: try JSONEncoder().encode(payload)
        )

        let response = try await transport.send(request)
        if let error = AmpError.from(response: response) { throw error }
    }

    private struct Payload: Encodable {
        let threadID: String
        let prompt: String
    }
}

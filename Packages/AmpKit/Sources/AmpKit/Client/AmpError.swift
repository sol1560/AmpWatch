import Foundation

public enum AmpError: Error, Equatable, Sendable {
    case unauthorized
    /// The token is valid but is missing a scope, e.g. `…threads.contents:view`.
    case forbidden(String?)
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case transport(String)
    case decoding(String)

    /// Maps an HTTP status onto a typed error, reading the API's
    /// `{"error": "..."}` body when one is present.
    static func from(response: HTTPResponse) -> AmpError? {
        guard !(200..<300).contains(response.status) else { return nil }
        let message = (try? JSONDecoder().decode([String: String].self, from: response.body))?["error"]
        switch response.status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(message)
        case 404:
            return .notFound
        case 429:
            return .rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        default:
            return .server(status: response.status, message: message)
        }
    }
}

extension AmpError {
    /// Whether the same request could succeed later without anyone changing
    /// anything: no link, a busy server, a broken one. A 4xx is an answer.
    public var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited: true
        case let .server(status, _): status >= 500
        case .unauthorized, .forbidden, .notFound, .decoding: false
        }
    }

    /// Short enough for a 40mm screen.
    public var watchDescription: String {
        switch self {
        case .unauthorized: AmpStrings.text("error.sign_in_again")
        case .forbidden: AmpStrings.text("error.missing_scope")
        case .notFound: AmpStrings.text("error.not_found")
        case .rateLimited: AmpStrings.text("error.rate_limited")
        case let .server(status, _): AmpStrings.format("error.server", status)
        case .transport: AmpStrings.text("error.no_connection")
        case .decoding: AmpStrings.text("error.unexpected_reply")
        }
    }
}

import Foundation
@testable import AmpKit

/// Records outgoing requests and replays canned responses.
///
/// Uses `withLock` rather than bare `lock()`/`unlock()` because the latter is
/// unavailable from async contexts under Swift 6 concurrency checking.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private struct State {
        var responses: [HTTPResponse]
        var requests: [HTTPRequest] = []
    }

    private let lock = NSLock()
    private var state: State

    init(responses: [HTTPResponse]) {
        state = State(responses: responses)
    }

    convenience init(status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.init(responses: [
            HTTPResponse(status: status, headers: headers, body: Data(json.utf8)),
        ])
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            state.requests.append(request)
            guard !state.responses.isEmpty else {
                throw AmpError.transport("StubTransport ran out of responses")
            }
            return state.responses.removeFirst()
        }
    }

    var requests: [HTTPRequest] {
        lock.withLock { state.requests }
    }

    var lastRequest: HTTPRequest? {
        requests.last
    }

    func queryItems(of request: HTTPRequest) -> [String: String] {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        return Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
}

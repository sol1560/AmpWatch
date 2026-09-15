import XCTest
@testable import AmpKit

final class AmpSessionTests: XCTestCase {
    private let transport = StubTransport(responses: [])

    func testNoTokenMeansSetup() {
        let session = AmpSession.load(from: InMemorySecretStore(), transport: transport)
        XCTAssertFalse(session.isReady)
    }

    func testWhitespaceTokenStillMeansSetup() {
        let store = InMemorySecretStore([.accessToken: "  \n"])
        XCTAssertFalse(AmpSession.load(from: store, transport: transport).isReady)
    }

    func testTokenWithoutURLIsReadyButCannotWrite() throws {
        let store = InMemorySecretStore([.accessToken: "amp_token"])
        guard case let .ready(client, sink) = AmpSession.load(from: store, transport: transport) else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(client is AmpAPIClient)
        XCTAssertNil(sink)
    }

    func testTokenAndURLIsReadyWithSink() throws {
        let store = InMemorySecretStore([
            .accessToken: "amp_token",
            .webhookURL: " https://hooks.ampcode.com/w/abc \n",
        ])
        guard case let .ready(_, sink) = AmpSession.load(from: store, transport: transport) else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(sink is WebhookPromptSink)
    }

    func testMalformedOrInsecureURLIsTreatedAsUnset() {
        for raw in ["hooks.ampcode.com/w/abc", "http://hooks.ampcode.com/w/abc", "not a url", "https://"] {
            let store = InMemorySecretStore([.accessToken: "amp_token", .webhookURL: raw])
            XCTAssertNil(AmpSession.webhookURL(from: store), raw)
        }
    }

    func testTokenIsSentAsBearer() async throws {
        let transport = StubTransport(responses: [
            HTTPResponse(status: 200, body: Data(#"{"threads":[]}"#.utf8)),
        ])
        let store = InMemorySecretStore([.accessToken: "amp_secret_1"])
        guard case let .ready(client, _) = AmpSession.load(from: store, transport: transport) else {
            return XCTFail("expected ready")
        }
        _ = try await client.threads(limit: 5)
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer amp_secret_1")
    }

    func testInMemoryStoreRoundTripAndRemoveAll() throws {
        let store = InMemorySecretStore()
        try store.write("t", for: .accessToken)
        try store.write("u", for: .webhookURL)
        XCTAssertEqual(try store.read(.accessToken), "t")
        try store.write(nil, for: .accessToken)
        XCTAssertNil(try store.read(.accessToken))
        XCTAssertEqual(try store.read(.webhookURL), "u")
        try store.removeAll()
        XCTAssertNil(try store.read(.webhookURL))
    }

    func testMaskingNeverRevealsMoreThanTheSuffix() {
        XCTAssertEqual(SecretDisplay.masked("amp_abcdef1234"), "…1234")
        XCTAssertEqual(SecretDisplay.masked("ab"), "••")
        XCTAssertEqual(SecretDisplay.masked("  amp_x9  "), "…p_x9")
        XCTAssertEqual(
            SecretDisplay.maskedURL(URL(string: "https://hooks.ampcode.com/w/secret")!),
            "hooks.ampcode.com"
        )
    }
}

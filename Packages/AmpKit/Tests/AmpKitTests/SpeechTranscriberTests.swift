import XCTest
@testable import AmpKit

final class SpeechTranscriberTests: XCTestCase {
    func testMultipartPreservesAudioAndMultilingualTranscript() async throws {
        let transport = StubTransport(json: #"{"text":"运行 tests，然后解释结果。"}"#)
        let audio = Data([0, 255, 13, 10, 128, 65])
        let result = try await ElevenLabsTranscriber(apiKey: "test-key", transport: transport).transcribe(audio: audio)
        XCTAssertEqual(result, "运行 tests，然后解释结果。")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["xi-api-key"], "test-key")
        let boundary = try XCTUnwrap(request.headers["Content-Type"]?.components(separatedBy: "boundary=").last)
        let body = try XCTUnwrap(request.body)
        let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n"
        XCTAssertTrue(body.starts(with: Data(prefix.utf8)))
        let fileHeader = "Content-Type: audio/mp4\r\n\r\n"
        let start = try XCTUnwrap(body.range(of: Data(fileHeader.utf8))).upperBound
        XCTAssertEqual(body.subdata(in: start..<(start + audio.count)), audio)
        XCTAssertEqual(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count), Data("\r\n--\(boundary)--\r\n".utf8))
    }

    func testProviderErrorsAreSanitizedAndNeverRetried() async {
        for (status, expected) in [(401, TranscriptionError.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable)] {
            let transport = StubTransport(status: status, json: #"{"detail":"sensitive provider body"}"#)
            do {
                _ = try await ElevenLabsTranscriber(apiKey: "test-key", transport: transport).transcribe(audio: Data([1]))
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? TranscriptionError, expected)
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testEmptyOrOversizedAudioNeverLeavesDevice() async {
        let transport = StubTransport(responses: [])
        for audio in [Data(), Data(repeating: 1, count: ElevenLabsTranscriber.maximumBytes + 1)] {
            do {
                _ = try await ElevenLabsTranscriber(apiKey: "test-key", transport: transport).transcribe(audio: audio)
                XCTFail("Expected rejection")
            } catch {
                XCTAssertEqual(error as? TranscriptionError, .invalidAudio)
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMalformedAndEmptyTranscriptsDoNotBecomeDrafts() async {
        for json in ["{}", "not json", #"{"text":"  \n "}"#] {
            do {
                _ = try await ElevenLabsTranscriber(apiKey: "test-key", transport: StubTransport(json: json)).transcribe(audio: Data([1]))
                XCTFail("Expected invalid response")
            } catch {
                XCTAssertEqual(error as? TranscriptionError, .invalidResponse)
            }
        }
    }
}

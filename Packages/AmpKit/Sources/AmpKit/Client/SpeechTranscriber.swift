import Foundation

public protocol SpeechTranscriber: Sendable {
    func transcribe(audio: Data) async throws -> String
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case invalidAudio, unauthorized, rateLimited, unavailable, invalidResponse
}

/// Short, user-confirmed M4A recordings only. No automatic retry: a retry
/// could charge for the same audio twice. Never surface provider error bodies.
public struct ElevenLabsTranscriber: SpeechTranscriber {
    public static let maximumBytes = 2 * 1024 * 1024
    private let apiKey: String
    private let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func transcribe(audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= Self.maximumBytes else {
            throw TranscriptionError.invalidAudio
        }
        let boundary = "AmpWatch-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in [("model_id", "scribe_v2"), ("tag_audio_events", "false")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(
                method: "POST", url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
                headers: ["xi-api-key": apiKey, "Content-Type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            ))
        } catch {
            throw TranscriptionError.unavailable
        }
        switch response.status {
        case 200: break
        case 401, 403: throw TranscriptionError.unauthorized
        case 429: throw TranscriptionError.rateLimited
        default: throw TranscriptionError.unavailable
        }
        struct Transcript: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(Transcript.self, from: response.body),
              !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.invalidResponse
        }
        return decoded.text
    }
}

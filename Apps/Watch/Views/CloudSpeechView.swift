import SwiftUI
import WatchKit
import AmpKit

struct CloudSpeechView: View {
    @Binding var text: String
    @Environment(\.amp) private var amp
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var problem: String?

    init(text: Binding<String>, busy: Bool = false, problem: String? = nil) {
        _text = text
        _busy = State(initialValue: busy)
        _problem = State(initialValue: problem)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if busy {
                    ProgressView("Recording or transcribing…")
                        .accessibilityIdentifier("speech-progress")
                }
                if let problem {
                    Text(problem)
                        .font(AmpTheme.body(12))
                        .foregroundStyle(AmpTheme.ember)
                        .accessibilityIdentifier("speech-error")
                }
                Text("Up to 60s. Audio goes to ElevenLabs and may cost money. Review text before sending to Amp.")
                    .font(AmpTheme.body(12))
                    .foregroundStyle(AmpTheme.parchment)
                if amp.speech == nil {
                    Text("Add an ElevenLabs API key in Settings first. System dictation needs no key.")
                        .font(AmpTheme.body(12))
                        .foregroundStyle(AmpTheme.parchmentDim)
                        .accessibilityIdentifier("speech-needs-key")
                }
                Button {
                    record()
                } label: {
                    Label("Record and transcribe", systemImage: "mic")
                }
                .disabled(busy || amp.speech == nil)
                .ampAccent()
                .accessibilityIdentifier("cloud-record-button")
            }
        }
        .navigationTitle("ElevenLabs")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .accessibilityIdentifier("cloud-speech")
    }

    private func record() {
        guard let speech = amp.speech else { return }
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            problem = WatchStrings.text("Recording failed. Check microphone access.")
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        busy = true
        problem = nil
        controller.presentAudioRecorderController(withOutputURL: file, preset: .wideBandSpeech,
            options: [WKAudioRecorderControllerOptionsMaximumDurationKey: 60,
                      WKAudioRecorderControllerOptionsActionTitleKey: WatchStrings.text("Transcribe")]) { saved, error in
            Task { @MainActor in
                defer {
                    try? FileManager.default.removeItem(at: file)
                    busy = false
                }
                guard saved, error == nil else {
                    if error != nil { problem = WatchStrings.text("Recording failed. Check microphone access.") }
                    return
                }
                do {
                    let result = try await speech.transcribe(audio: Data(contentsOf: file))
                    text = text.isEmpty ? result : text + "\n" + result
                    dismiss()
                } catch {
                    switch error as? TranscriptionError {
                    case .unauthorized: problem = WatchStrings.text("Check your ElevenLabs API key.")
                    case .rateLimited: problem = WatchStrings.text("ElevenLabs is busy or your quota is exhausted. Try later.")
                    case .invalidResponse: problem = WatchStrings.text("No speech was recognized. Try again.")
                    default: problem = WatchStrings.text("Transcription failed. Check your connection and try again.")
                    }
                }
            }
        }
    }
}

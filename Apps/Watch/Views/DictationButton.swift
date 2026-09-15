import SwiftUI
import WatchKit

/// System text input offers dictation without giving this app raw audio.
/// Accepting text only edits the draft; sending remains a separate action.
struct DictationButton: View {
    @Binding var text: String
    @State private var presenting = false
    @State private var unavailable = false

    var body: some View {
        Button {
            guard let controller = WKApplication.shared().visibleInterfaceController else {
                unavailable = true
                return
            }
            presenting = true
            controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
                presenting = false
                guard let result = results?.first as? String,
                      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                text = text.isEmpty ? result : text + "\n" + result
            }
        } label: {
            Label("Voice input", systemImage: "mic")
        }
        .font(AmpTheme.body(13))
        .disabled(presenting)
        .accessibilityIdentifier("dictation-button")
        .accessibilityHint("Choose the microphone in system input. Review the text before sending.")
        .alert("Voice input unavailable", isPresented: $unavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Tap the prompt field to use system dictation.")
        }
    }
}

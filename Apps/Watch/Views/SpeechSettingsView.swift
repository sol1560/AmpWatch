import SwiftUI
import AmpKit

struct SpeechSettingsView: View {
    @Environment(\.amp) private var amp
    @State private var key = ""
    @State private var configured = false
    @State private var problem: String?

    var body: some View {
        List {
            Text("System dictation is always available. ElevenLabs is optional and uses your account's quota.")
                .font(AmpTheme.body(12))
            Text(configured ? WatchStrings.text("Key saved") : WatchStrings.text("not set"))
                .accessibilityIdentifier("speech-key-status")
            SecureField("ElevenLabs API key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("speech-key-field")
            Button("Save key") { save(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("speech-key-save")
            Button("Remove key", role: .destructive) { save(nil) }
                .disabled(!configured)
                .accessibilityIdentifier("speech-key-remove")
            if let problem { Text(problem).foregroundStyle(AmpTheme.ember) }
        }
        .navigationTitle("Voice settings")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .accessibilityIdentifier("speech-settings")
        .onAppear { configured = (try? amp.secrets.read(.elevenLabsAPIKey)) != nil }
    }

    private func save(_ value: String?) {
        do {
            try amp.secrets.write(value, for: .elevenLabsAPIKey)
            key = ""
            configured = value != nil
            problem = nil
            amp.reload()
        } catch {
            problem = WatchStrings.text("Could not save to the Keychain.")
        }
    }
}

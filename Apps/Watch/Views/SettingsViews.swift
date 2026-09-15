import SwiftUI
import AmpKit

/// First run: no token yet. Explains what to fetch and where, takes it, and
/// hands control back to `RootView` via `amp.reload()`.
///
/// There is no phone in this product, so the token is typed on the watch
/// (the Ultra has a full keyboard). This is a one-time cost; the token lives
/// in the Keychain afterwards.
struct SetupView: View {
    @Environment(\.amp) private var amp
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("amp")
                    .font(AmpTheme.display(30))
                    .foregroundStyle(AmpTheme.parchment)

                Text("Paste an API token from ampcode.com → Settings → API. Read scope is enough to start.")
                    .font(AmpTheme.body(12))
                    .foregroundStyle(AmpTheme.parchmentDim)

                AmpRule()

                TextField("API token", text: $token)
                    .font(AmpTheme.body(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("token-field")

                Button {
                    save()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .ampAccent()
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("continue-button")

                if let problem {
                    Text(problem)
                        .font(AmpTheme.body(11))
                        .foregroundStyle(AmpTheme.ember)
                }
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("setup")
    }

    private func save() {
        do {
            try amp.secrets.write(token, for: .accessToken)
            amp.reload()
        } catch {
            problem = "Could not save to the Keychain."
        }
    }
}

/// Credentials, shown masked, each replaceable in place; plus sign-out.
struct SettingsView: View {
    @Environment(\.amp) private var amp
    @State private var newToken = ""
    @State private var newWebhookURL = ""
    @State private var problem: String?
    @State private var preferences = WatchPreferences.defaults

    /// Caps a wrist can pick from. Typing a number on a watch is not worth
    /// the precision; `nil` is off.
    private static let capChoices: [Double?] = [nil, 1, 2, 5, 10, 20, 50]

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PhrasesView()
                } label: {
                    Label("Saved phrases", systemImage: "text.quote")
                }
                .accessibilityIdentifier("phrases-link")

                NavigationLink {
                    TemplatesView()
                } label: {
                    Label("Thread templates", systemImage: "doc.text")
                }
                .accessibilityIdentifier("templates-link")

                Picker(selection: $preferences.budgetCapUSD) {
                    ForEach(Self.capChoices, id: \.self) { cap in
                        Text(cap.map { Money.compact(usd: $0) } ?? "off").tag(cap)
                    }
                } label: {
                    Label("Flag at", systemImage: "dollarsign.circle")
                }
                .pickerStyle(.navigationLink)
                .onChange(of: preferences.budgetCapUSD) { _, _ in amp.preferences.save(preferences) }
                .accessibilityIdentifier("budget-picker")
            }
            .font(AmpTheme.body(13))
            .listRowBackground(Color.clear)

            secretRow(
                title: "API token",
                value: tokenSummary,
                placeholder: "New token",
                text: $newToken,
                identifier: "token"
            ) { try amp.secrets.write($0, for: .accessToken) }

            secretRow(
                title: "Bridge URL",
                value: webhookSummary,
                placeholder: "https://…",
                text: $newWebhookURL,
                identifier: "webhook"
            ) { try amp.secrets.write($0, for: .webhookURL) }

            Section {
                Button(role: .destructive) {
                    try? amp.secrets.removeAll()
                    amp.reload()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("sign-out-button")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem {
                        Text(problem).foregroundStyle(AmpTheme.ember)
                    }
                    Text("AmpWatch \(Bundle.main.shortVersion)")
                }
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchmentDim)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings")
        .onAppear { preferences = amp.preferences.load() }
    }

    private var tokenSummary: String {
        ((try? amp.secrets.read(.accessToken)) ?? nil).map { SecretDisplay.masked($0) } ?? "not set"
    }

    private var webhookSummary: String {
        AmpSession.webhookURL(from: amp.secrets).map(SecretDisplay.maskedURL) ?? "not set"
    }

    private func secretRow(
        title: String,
        value: String,
        placeholder: String,
        text: Binding<String>,
        identifier: String,
        save: @escaping (String) throws -> Void
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AmpTheme.body(11, weight: .medium))
                    .foregroundStyle(AmpTheme.parchmentDim)
                Text(value)
                    .font(AmpTheme.body(14).monospaced())
                    .foregroundStyle(AmpTheme.parchment)
                    .accessibilityIdentifier("\(identifier)-value")
            }
            .listRowBackground(Color.clear)

            TextField(placeholder, text: text)
                .font(AmpTheme.body(13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("\(identifier)-field")
                .onSubmit {
                    let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    do {
                        try save(trimmed)
                        text.wrappedValue = ""
                        problem = nil
                        amp.reload()
                    } catch {
                        problem = "Could not save to the Keychain."
                    }
                }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

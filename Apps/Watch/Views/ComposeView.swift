import SwiftUI
import AmpKit

@MainActor
@Observable
final class ComposeModel {
    enum Status: Equatable {
        case editing
        case sending
        case sent
        /// Saved on the watch; goes out when the link is back.
        case queued(behind: Int)
        case failed(String)
    }

    var text = ""
    private(set) var status: Status = .editing

    var canSend: Bool {
        status != .sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(to threadID: String, using environment: AmpEnvironment) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        status = .sending
        guard let outcome = await environment.deliver(.prompt(threadID: threadID, text: prompt, steer: true)) else {
            status = .failed("No bridge configured")
            return
        }
        switch outcome {
        case .delivered:
            text = ""
            status = .sent
        case let .queued(behind):
            text = ""
            status = .queued(behind: behind)
        case let .dropped(reason):
            status = .failed(OutboxStatus.note(for: reason))
        }
    }
}

/// Sends a prompt to a running thread.
///
/// Writes do not go through the External API — it has no endpoint for this —
/// but through an Amp plugin webhook, which is fire-and-forget. A success here
/// means Amp accepted the prompt for delivery, not that the agent has acted on
/// it, and the UI says exactly that.
struct ComposeView: View {
    let thread: ThreadSummary

    @Environment(\.amp) private var amp
    @State private var model = ComposeModel()
    @State private var phrases: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Prompt", text: $model.text, axis: .vertical)
                    .font(AmpTheme.body(14))
                    .accessibilityIdentifier("prompt-field")

                PhraseChips(phrases: phrases) { model.text = $0 }

                Button {
                    Task { await model.send(to: thread.id, using: amp) }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .ampAccent()
                .disabled(!model.canSend)
                .accessibilityIdentifier("send-button")

                statusLine
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("compose")
        // Re-read on every appearance: the phrases screen may have changed it.
        .onAppear { phrases = amp.preferences.load().phrases }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .editing:
            EmptyView()
        case .sending:
            Text("sending…")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchmentDim)
        case .sent:
            Text("sent — amp will pick it up")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("send-confirmation")
        case let .queued(behind):
            Text(behind == 0
                 ? "saved — sends when the watch is back online"
                 : "saved — \(behind) ahead of it in the queue")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("send-queued")
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }
}

/// Tap-to-fill phrases in two columns, so six of them fit above the fold.
struct PhraseChips: View {
    let phrases: [String]
    let pick: (String) -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(phrases, id: \.self) { phrase in
                Button {
                    pick(phrase)
                } label: {
                    Text(phrase)
                        .font(AmpTheme.body(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(AmpTheme.parchmentDim)
                .accessibilityHint("Puts this in the reply field; Send is still up to you")
                .accessibilityIdentifier("phrase-chip")
            }
        }
    }
}

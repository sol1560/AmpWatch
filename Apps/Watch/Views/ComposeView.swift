import SwiftUI
import AmpKit

@MainActor
@Observable
final class ComposeModel {
    enum Status: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    var text = ""
    private(set) var status: Status = .editing

    var canSend: Bool {
        status != .sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(to threadID: String, using environment: AmpEnvironment) async {
        guard let sink = environment.promptSink else {
            status = .failed("No bridge configured")
            return
        }
        status = .sending
        do {
            try await sink.send(prompt: text, to: threadID)
            text = ""
            status = .sent
        } catch {
            let amp = error as? AmpError ?? .transport(String(describing: error))
            status = .failed(amp.watchDescription)
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

    private static let quickReplies = ["Continue", "Run the tests", "Ship it"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Prompt", text: $model.text, axis: .vertical)
                    .font(AmpTheme.body(14))
                    .accessibilityIdentifier("prompt-field")

                HStack(spacing: 6) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button(reply) { model.text = reply }
                            .font(AmpTheme.body(11))
                            .buttonStyle(.bordered)
                            .tint(AmpTheme.parchmentDim)
                    }
                }

                Button {
                    Task { await model.send(to: thread.id, using: amp) }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AmpTheme.ember)
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
            Text("queued — amp will pick it up")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("send-confirmation")
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }
}

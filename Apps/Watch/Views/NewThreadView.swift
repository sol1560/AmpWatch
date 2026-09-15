import SwiftUI
import AmpKit

@MainActor
@Observable
final class NewThreadModel {
    enum Status: Equatable {
        case editing, sending, sent, failed(String)
    }

    var prompt = ""
    var mode: AgentMode = .medium
    private(set) var status: Status = .editing

    var canSend: Bool {
        status != .sending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(using environment: AmpEnvironment) async {
        guard let sink = environment.promptSink else {
            status = .failed("No bridge configured")
            return
        }
        status = .sending
        do {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            try await sink.send(.create(prompt: text, mode: mode), idempotencyKey: nil)
            prompt = ""
            status = .sent
        } catch {
            let amp = error as? AmpError ?? .transport(String(describing: error))
            status = .failed(amp.watchDescription)
        }
    }
}

/// Starts a new orb thread in the hub's project with an opening prompt.
///
/// The bridge creates the thread; the watch learns about it the next time the
/// list refreshes, because the webhook returns no body. The status line says
/// so rather than pretending a thread ID is known.
struct NewThreadView: View {
    @Environment(\.amp) private var amp
    @State private var model = NewThreadModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What should it do?", text: $model.prompt, axis: .vertical)
                    .font(AmpTheme.body(14))
                    .accessibilityIdentifier("new-thread-prompt")

                Picker(selection: $model.mode) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                } label: {
                    Label("Mode", systemImage: "gauge.with.dots.needle.33percent")
                }
                // The watch's native picker: a row that opens a wheel list.
                // An inline picker draws as a bare outline on this screen size.
                .pickerStyle(.navigationLink)
                .font(AmpTheme.body(13))
                .accessibilityIdentifier("mode-picker")

                Button {
                    Task { await model.send(using: amp) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AmpTheme.ember)
                .disabled(!model.canSend)
                .accessibilityIdentifier("start-button")

                statusLine
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("new-thread")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .editing:
            EmptyView()
        case .sending:
            Text("starting…")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchmentDim)
        case .sent:
            Text("queued — it will show in the list shortly")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }
}

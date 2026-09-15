import SwiftUI
import AmpKit

@MainActor
@Observable
final class ThreadDetailModel {
    enum CancelStatus: Equatable {
        case idle, confirming, sending, sent, failed(String)
    }

    private(set) var state: Loadable<[ThreadMessage]> = .loading
    var cancelStatus: CancelStatus = .idle

    func cancel(threadID: String, using environment: AmpEnvironment) async {
        guard let sink = environment.promptSink else {
            cancelStatus = .failed("No bridge configured")
            return
        }
        cancelStatus = .sending
        do {
            try await sink.send(.cancel(threadID: threadID), idempotencyKey: nil)
            cancelStatus = .sent
        } catch {
            let amp = error as? AmpError ?? .transport(String(describing: error))
            cancelStatus = .failed(amp.watchDescription)
        }
    }

    func load(threadID: String, from environment: AmpEnvironment) async {
        do {
            let page = try await environment.client.messages(threadID: threadID, limit: 25)
            state = .loaded(page.items)
        } catch {
            state = .failed(error as? AmpError ?? .transport(String(describing: error)))
        }
    }
}

struct ThreadDetailView: View {
    let thread: ThreadSummary

    @Environment(\.amp) private var amp
    @State private var model = ThreadDetailModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                LoadingView(label: thread.displayTitle)
            case let .failed(error):
                ErrorView(error: error) { await model.load(threadID: thread.id, from: amp) }
            case let .loaded(messages) where messages.isEmpty:
                EmptyStateView(headline: "No messages", detail: "This thread has not started yet.")
            case let .loaded(messages):
                transcript(messages)
            }
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        // Titles are sentences; the watch nav bar only fits a few words and
        // scrolls anything longer. Keep the bar short and put the full title
        // in the body where it can wrap.
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(threadID: thread.id, from: amp) }
    }

    private func transcript(_ messages: [ThreadMessage]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(thread.displayTitle)
                    .font(AmpTheme.display(17))
                    .foregroundStyle(AmpTheme.parchment)
                    .accessibilityIdentifier("thread-title")
                header

                ForEach(messages) { message in
                    MessageView(message: message, now: amp.now())
                }

                NavigationLink {
                    ComposeView(thread: thread)
                } label: {
                    Label("Reply", systemImage: "mic.fill")
                }
                .tint(AmpTheme.ember)
                .accessibilityIdentifier("reply-button")

                NavigationLink {
                    UsageView(thread: thread)
                } label: {
                    Label("Cost", systemImage: "dollarsign.circle")
                }
                .tint(AmpTheme.parchmentDim)

                // Cancel is only offered while the thread looks mid-turn;
                // cancelling an idle thread is a no-op that costs rate budget.
                if thread.activity(now: amp.now()) == .live {
                    cancelControl
                }
            }
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("thread-detail")
    }

    @ViewBuilder
    private var cancelControl: some View {
        switch model.cancelStatus {
        case .idle:
            Button(role: .destructive) {
                model.cancelStatus = .confirming
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(AmpTheme.ember)
            .accessibilityIdentifier("cancel-button")
        case .confirming:
            HStack {
                Button("Stop turn", role: .destructive) {
                    Task { await model.cancel(threadID: thread.id, using: amp) }
                }
                .tint(AmpTheme.ember)
                .accessibilityIdentifier("cancel-confirm-button")
                Button("Keep") { model.cancelStatus = .idle }
                    .tint(AmpTheme.parchmentDim)
            }
            .font(AmpTheme.body(12))
        case .sending:
            Text("stopping…")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchmentDim)
        case .sent:
            Text("stop requested")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }

    private var header: some View {
        let activity = thread.activity(now: amp.now())
        return HStack(spacing: 6) {
            ActivityDot(activity: activity)
            Text(activity.label)
            Spacer()
            Text(RelativeTime.short(from: thread.updatedAt, to: amp.now()))
        }
        .font(AmpTheme.body(12))
        .foregroundStyle(AmpTheme.parchmentDim)
    }
}

struct MessageView: View {
    let message: ThreadMessage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(speaker)
                    .foregroundStyle(message.role == .user ? AmpTheme.ember : AmpTheme.parchmentDim)
                Spacer()
                Text(RelativeTime.short(from: message.createdAt, to: now))
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
            .font(AmpTheme.body(11, weight: .medium))

            if let text = message.text {
                Text(text)
                    .font(AmpTheme.body(14))
                    .foregroundStyle(AmpTheme.parchment)
            } else {
                // Tool calls and other non-text blocks: say so instead of
                // rendering an empty row the user cannot interpret.
                Text("tool activity")
                    .font(AmpTheme.body(13).italic())
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("message")
    }

    private var speaker: String {
        switch message.role {
        case .user: "you"
        case .assistant: "amp"
        case .system: "system"
        case .unknown: "—"
        }
    }
}

import SwiftUI
import AmpKit

@MainActor
@Observable
final class ThreadDetailModel {
    private(set) var state: Loadable<[ThreadMessage]> = .loading

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
        .navigationTitle(thread.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(threadID: thread.id, from: amp) }
    }

    private func transcript(_ messages: [ThreadMessage]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            }
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("thread-detail")
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

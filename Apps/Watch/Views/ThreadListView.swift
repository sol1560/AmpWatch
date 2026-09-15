import SwiftUI
import AmpKit

@MainActor
@Observable
final class ThreadListModel {
    private(set) var state: Loadable<[ThreadSummary]> = .loading

    func load(from environment: AmpEnvironment) async {
        do {
            let page = try await environment.client.threads(limit: 25)
            state = .loaded(page.items)
        } catch {
            state = .failed(error as? AmpError ?? .transport(String(describing: error)))
        }
    }
}

struct ThreadListView: View {
    @Environment(\.amp) private var amp
    @State private var model = ThreadListModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                LoadingView(label: "Threads")
            case let .failed(error):
                ErrorView(error: error) { await model.load(from: amp) }
            case let .loaded(threads) where threads.isEmpty:
                EmptyStateView(
                    headline: "Nothing running",
                    detail: "Start a thread on the web or in the CLI."
                )
            case let .loaded(threads):
                list(threads)
            }
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("amp")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settings-button")
            }
        }
        .task { await model.load(from: amp) }
    }

    private func list(_ threads: [ThreadSummary]) -> some View {
        List {
            ForEach(threads) { thread in
                NavigationLink(value: thread) {
                    ThreadRow(thread: thread, now: amp.now())
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("thread-list")
        .navigationDestination(for: ThreadSummary.self) { thread in
            ThreadDetailView(thread: thread)
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    let now: Date

    private var activity: ThreadActivity { thread.activity(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ActivityDot(activity: activity)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(thread.displayTitle)
                    .font(AmpTheme.display(16))
                    .foregroundStyle(AmpTheme.parchment)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 4) {
                if let repository = thread.repositories.first {
                    Text(repository.shortName)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("·")
                }
                Text(RelativeTime.short(from: thread.updatedAt, to: now))
            }
            .font(AmpTheme.body(12))
            .foregroundStyle(AmpTheme.parchmentDim)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread-row")
    }
}

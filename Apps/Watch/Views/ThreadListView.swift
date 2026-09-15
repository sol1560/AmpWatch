import SwiftUI
import AmpKit

@MainActor
@Observable
final class ThreadListModel {
    private(set) var state: Loadable<[ThreadSummary]> = .loading
    /// Spend for the threads that matter today: the live ones, whose cost is
    /// still growing, and anything else that changed since midnight, which is
    /// what the spend complication adds up. A thread quiet since yesterday
    /// is not looked up; each lookup is one request against a budget shared
    /// with everything else the watch does.
    private(set) var usage: [String: ThreadUsage] = [:]

    func load(from environment: AmpEnvironment) async {
        do {
            let page = try await environment.client.threads(limit: 25)
            state = .loaded(page.items)
            let now = environment.now()
            await loadUsage(for: page.items.filter { Self.isWorthPricing($0, now: now) }, from: environment)
            await environment.glance?.publish(threads: page.items, usage: usage, now: now)
        } catch {
            state = .failed(error as? AmpError ?? .transport(String(describing: error)))
        }
    }

    static func isWorthPricing(_ thread: ThreadSummary, now: Date) -> Bool {
        if thread.activity(now: now) == .live { return true }
        guard let updatedAt = thread.updatedAt else { return false }
        return Calendar.current.isDate(updatedAt, inSameDayAs: now)
    }

    private func loadUsage(for threads: [ThreadSummary], from environment: AmpEnvironment) async {
        let client = environment.client
        let found = await withTaskGroup(of: ThreadUsage?.self) { group in
            for thread in threads {
                group.addTask { try? await client.usage(threadID: thread.id) }
            }
            var found: [String: ThreadUsage] = [:]
            for await usage in group {
                if let usage { found[usage.threadID] = usage }
            }
            return found
        }
        usage.merge(found) { _, new in new }
    }
}

struct ThreadListView: View {
    @Environment(\.amp) private var amp
    @State private var model = ThreadListModel()
    @State private var budgetCap: Double?

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
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(AmpTheme.canvas)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settings-button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NewThreadView()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(AmpTheme.canvas)
                }
                .accessibilityLabel("New thread")
                .accessibilityIdentifier("new-thread-button")
            }
        }
        .task { await model.load(from: amp) }
        .onAppear { budgetCap = amp.preferences.load().budgetCapUSD }
    }

    private func list(_ threads: [ThreadSummary]) -> some View {
        List {
            if amp.outbox.pending > 0 || amp.outbox.note != nil {
                OutboxBanner(status: amp.outbox)
                    .listRowBackground(Color.clear)
            }
            ForEach(threads) { thread in
                NavigationLink(value: thread) {
                    ThreadRow(
                        thread: thread,
                        now: amp.now(),
                        usageUSD: model.usage[thread.id]?.usage,
                        budgetCapUSD: budgetCap
                    )
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

/// What is waiting to go out, and what never made it. Sits above the threads
/// because "did my message send?" is the first thing a raised wrist asks.
struct OutboxBanner: View {
    let status: OutboxStatus
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.pending > 0 {
                Label(
                    status.pending == 1 ? "1 waiting to send" : "\(status.pending) waiting to send",
                    systemImage: "tray.and.arrow.up"
                )
                .foregroundStyle(AmpTheme.accent(dimmed: dimmed))
            }
            if let note = status.note {
                Text(note)
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
        }
        .font(AmpTheme.body(12, weight: .medium))
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outbox-banner")
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    let now: Date
    var usageUSD: Double?
    var budgetCapUSD: Double?

    private var activity: ThreadActivity { thread.activity(now: now) }
    private var standing: BudgetStanding { BudgetStanding(usageUSD: usageUSD ?? 0, capUSD: budgetCapUSD) }

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
                if let usageUSD, standing == .fine {
                    Spacer(minLength: 4)
                    BudgetBadge(usageUSD: usageUSD, standing: standing)
                }
            }
            .font(AmpTheme.body(12))
            .foregroundStyle(AmpTheme.parchmentDim)

            // A flag needs its own line; squeezed next to the repo name it
            // wraps into three and pushes the name off the row.
            if let usageUSD, standing != .fine {
                BudgetBadge(usageUSD: usageUSD, standing: standing)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread-row")
    }
}

import SwiftUI
import AmpKit

@MainActor
@Observable
final class ThreadDetailModel {
    enum CancelStatus: Equatable {
        case idle, confirming, sending, sent, queued, failed(String)
    }

    enum ArmStatus: Equatable {
        case idle, sending, queued, failed(String)
    }

    private(set) var state: Loadable<[ThreadMessage]> = .loading
    /// Spend so far, once known. Loaded alongside the transcript; a failure
    /// here is not worth an error screen, the Cost row just shows no number.
    private(set) var usage: ThreadUsage?
    var cancelStatus: CancelStatus = .idle
    /// What the watch last asked for. The bridge keeps the real value in
    /// memory and forgets it when its orb restarts, so this is a request, not
    /// a mirror; it starts at the bridge's own default.
    var armLevel: ArmLevel = .off
    var armStatus: ArmStatus = .idle

    func arm(_ level: ArmLevel, threadID: String, using environment: AmpEnvironment) async {
        armStatus = .sending
        // Only the latest level matters, so a fixed id per thread replaces a
        // queued earlier pick instead of sending both.
        guard let outcome = await environment.deliver(.arm(threadID: threadID, level: level), id: "arm-\(threadID)") else {
            armStatus = .failed("No bridge configured")
            return
        }
        switch outcome {
        case .delivered: armStatus = .idle
        case .queued: armStatus = .queued
        case let .dropped(reason): armStatus = .failed(OutboxStatus.note(for: reason))
        }
    }

    func cancel(threadID: String, using environment: AmpEnvironment) async {
        cancelStatus = .sending
        guard let outcome = await environment.deliver(.cancel(threadID: threadID)) else {
            cancelStatus = .failed("No bridge configured")
            return
        }
        switch outcome {
        case .delivered: cancelStatus = .sent
        case .queued: cancelStatus = .queued
        case let .dropped(reason): cancelStatus = .failed(OutboxStatus.note(for: reason))
        }
    }

    func load(threadID: String, from environment: AmpEnvironment) async {
        let client = environment.client
        let cost = Task { try? await client.usage(threadID: threadID) }
        do {
            let page = try await client.messages(threadID: threadID, limit: 25)
            state = .loaded(page.items)
        } catch {
            state = .failed(error as? AmpError ?? .transport(String(describing: error)))
        }
        usage = await cost.value
    }
}

struct ThreadDetailView: View {
    let thread: ThreadSummary

    @Environment(\.amp) private var amp
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var model = ThreadDetailModel()
    @State private var budgetCap: Double?

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
        .onAppear { budgetCap = amp.preferences.load().budgetCapUSD }
    }

    private func transcript(_ messages: [ThreadMessage]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(thread.displayTitle)
                    .font(AmpTheme.display(17))
                    .foregroundStyle(AmpTheme.parchment)
                    .accessibilityIdentifier("thread-title")
                header

                // Stop sits under the header, where the eye lands on a live
                // thread; it is only offered while the thread looks mid-turn,
                // because stopping an idle thread is a no-op that costs rate
                // budget.
                if thread.activity(now: amp.now()) == .live {
                    cancelControl
                }

                ForEach(messages) { message in
                    MessageView(message: message, now: amp.now())
                }

                NavigationLink {
                    ComposeView(thread: thread)
                } label: {
                    Label("Reply", systemImage: "mic.fill")
                }
                .ampAccent()
                .accessibilityIdentifier("reply-button")

                costRow

                armControl
            }
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("thread-detail")
    }

    /// The Cost link carries the number and, past the cap, a warning in the
    /// accent colour — the thing a student wants to see without opening
    /// anything.
    private var costRow: some View {
        let standing = BudgetStanding(usageUSD: model.usage?.usage ?? 0, capUSD: budgetCap)
        return NavigationLink {
            UsageView(thread: thread)
        } label: {
            HStack {
                Label("Cost", systemImage: "dollarsign.circle")
                Spacer()
                if let usage = model.usage {
                    BudgetBadge(usageUSD: usage.usage, standing: standing)
                }
            }
        }
        .tint(standing == .fine ? AmpTheme.parchmentDim : AmpTheme.accent(dimmed: dimmed))
        .accessibilityIdentifier("cost-row")
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
            .ampAccent()
            .accessibilityIdentifier("cancel-button")
        case .confirming:
            HStack {
                Button("Stop turn", role: .destructive) {
                    Task { await model.cancel(threadID: thread.id, using: amp) }
                }
                .ampAccent()
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
        case .queued:
            Text("saved — stops when the watch is back online")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }

    /// Which of this thread's commands should stop and ask the watch. Sent
    /// on every change; the bridge answers with pushes, not with a reply.
    @ViewBuilder
    private var armControl: some View {
        Picker(selection: $model.armLevel) {
            ForEach(ArmLevel.allCases, id: \.self) { level in
                Text(level.label).tag(level)
            }
        } label: {
            Label("Ask me first", systemImage: "hand.raised")
        }
        .pickerStyle(.navigationLink)
        .font(AmpTheme.body(13))
        .tint(AmpTheme.parchmentDim)
        .disabled(model.armStatus == .sending)
        .onChange(of: model.armLevel) { _, level in
            Task { await model.arm(level, threadID: thread.id, using: amp) }
        }
        .accessibilityIdentifier("arm-picker")

        switch model.armStatus {
        case .idle, .sending:
            EmptyView()
        case .queued:
            Text("saved — applies when the watch is back online")
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
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(speaker)
                    .foregroundStyle(message.role == .user ? AmpTheme.accent(dimmed: dimmed) : AmpTheme.parchmentDim)
                Spacer()
                Text(RelativeTime.short(from: message.createdAt, to: now))
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
            .font(AmpTheme.body(11, weight: .medium))

            if let text = message.text {
                // Redacted on the always-on face: a wrist resting on a desk
                // should not show the room what the agent just said.
                Text(text)
                    .font(AmpTheme.body(14))
                    .foregroundStyle(AmpTheme.parchment)
                    .privacySensitive()
            } else {
                // Tool calls and other non-text blocks: say so instead of
                // rendering an empty row the user cannot interpret.
                Text("tool activity")
                    .font(AmpTheme.body(13).italic())
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker), \(RelativeTime.short(from: message.createdAt, to: now)) ago: \(message.text ?? "tool activity")")
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

/// Spend and, when it matters, how it sits against the cap.
struct BudgetBadge: View {
    let usageUSD: Double
    let standing: BudgetStanding
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        HStack(spacing: 3) {
            if standing != .fine {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(text)
        }
        .font(AmpTheme.body(12, weight: standing == .fine ? .regular : .medium))
        .foregroundStyle(standing == .fine ? AmpTheme.parchmentDim : AmpTheme.accent(dimmed: dimmed))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(standing == .fine ? "cost-amount" : "budget-warning")
    }

    private var spoken: String {
        let amount = Money.compact(usd: usageUSD)
        switch standing {
        case .fine: return "spent \(amount)"
        case .near: return "spent \(amount), near cap"
        case .over: return "spent \(amount), over cap"
        }
    }

    private var text: String {
        switch standing {
        case .fine: Money.compact(usd: usageUSD)
        case .near: "\(Money.compact(usd: usageUSD)) near cap"
        case .over: "\(Money.compact(usd: usageUSD)) over cap"
        }
    }
}

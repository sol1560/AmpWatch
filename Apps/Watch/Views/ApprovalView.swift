import SwiftUI
import AmpKit

@MainActor
@Observable
final class ApprovalModel {
    enum Status: Equatable {
        case deciding, sending, sent(ApprovalDecision), queued(ApprovalDecision), failed(String)
    }

    private(set) var status: Status = .deciding

    func send(_ decision: ApprovalDecision, for approval: PendingApproval, using environment: AmpEnvironment) async {
        status = .sending
        let command = WatchCommand.decide(approvalID: approval.id, threadID: approval.threadID, decision: decision)
        guard let outcome = await environment.deliver(command) else {
            status = .failed("No bridge configured")
            return
        }
        switch outcome {
        case .delivered: status = .sent(decision)
        case .queued: status = .queued(decision)
        case let .dropped(reason): status = .failed(OutboxStatus.note(for: reason))
        }
    }
}

/// One held tool call and the buttons the watch is willing to offer for it.
///
/// The shape of the screen follows `PendingApproval.recommendation()`:
/// a plain command gets Approve first; a flagged one gets the warning first
/// and Approve last, unhighlighted; a command the watch cannot show whole gets
/// no Approve at all. The command text is always on screen, above the buttons,
/// so a decision is never made from a summary.
struct ApprovalView: View {
    let approval: PendingApproval

    @Environment(\.amp) private var amp
    @State private var model = ApprovalModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                switch approval.recommendation() {
                case .decide:
                    command
                    decideButtons(primaryApprove: true)
                case let .warn(signals):
                    warning(signals)
                    command
                    decideButtons(primaryApprove: false)
                case let .deferToLargerScreen(reason):
                    command
                    deferral(reason)
                }
                statusLine
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 8)
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Approve?")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("approval")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(approval.toolName)
                .font(AmpTheme.body(12, weight: .medium))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("approval-tool")
            Spacer()
            Text("waiting \(RelativeTime.short(from: approval.requestedAt, to: amp.now()))")
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.parchmentDim)
        }
    }

    private var command: some View {
        Text(approval.input)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(AmpTheme.parchment)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(AmpTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("approval-command")
    }

    private func warning(_ signals: [DestructiveSignal]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(signals, id: \.self) { signal in
                Label {
                    Text(signal.label)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(AmpTheme.body(12, weight: .medium))
                .foregroundStyle(AmpTheme.ember)
            }
        }
        .accessibilityIdentifier("approval-warning")
    }

    @ViewBuilder
    private func decideButtons(primaryApprove: Bool) -> some View {
        let approve = Button {
            Task { await model.send(.approve, for: approval, using: amp) }
        } label: {
            Label("Approve", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .disabled(model.status != .deciding)
        .accessibilityIdentifier("approve-button")

        let reject = Button(role: .destructive) {
            Task { await model.send(.reject, for: approval, using: amp) }
        } label: {
            Label("Reject", systemImage: "xmark")
                .frame(maxWidth: .infinity)
        }
        .disabled(model.status != .deciding)
        .accessibilityIdentifier("reject-button")

        if primaryApprove {
            approve.buttonStyle(.borderedProminent).tint(AmpTheme.ember)
            reject.buttonStyle(.bordered).tint(AmpTheme.parchmentDim)
        } else {
            // The flagged case: Reject is the easy tap, Approve is the plain one.
            reject.buttonStyle(.borderedProminent).tint(AmpTheme.ember)
            approve.buttonStyle(.bordered).tint(AmpTheme.parchmentDim)
        }
    }

    private func deferral(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.ember)
                .accessibilityIdentifier("approval-defer-reason")
            Text("Decide this on your Mac. The agent keeps waiting.")
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.parchmentDim)
            Button {
                Task { await model.send(.defer_, for: approval, using: amp) }
            } label: {
                Label("Leave it waiting", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AmpTheme.ember)
            .disabled(model.status != .deciding)
            .accessibilityIdentifier("defer-button")
            Button(role: .destructive) {
                Task { await model.send(.reject, for: approval, using: amp) }
            } label: {
                Label("Reject", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AmpTheme.parchmentDim)
            .disabled(model.status != .deciding)
            .accessibilityIdentifier("reject-button")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .deciding:
            EmptyView()
        case .sending:
            Text("sending…")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchmentDim)
        case let .sent(decision):
            Text(sentLabel(decision))
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("approval-status")
        case .queued:
            // A decision that sits too long is dropped, not delivered late
            // (`Outbox.decisionTTL`); say so, because "saved" alone would
            // read as "done".
            Text("saved — sends when back online, or is dropped after \(Int(Outbox.decisionTTL / 60)) min")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
                .accessibilityIdentifier("approval-status")
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
                .accessibilityIdentifier("approval-status")
        }
    }

    private func sentLabel(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .approve: "approved — it runs now"
        case .reject: "rejected — it will not run"
        case .defer_: "left waiting"
        }
    }
}

#Preview("Plain") {
    NavigationStack { ApprovalView(approval: Fixtures.approvals()[0]) }
        .environment(\.amp, .fixture())
}

#Preview("Warn") {
    NavigationStack { ApprovalView(approval: Fixtures.approvals()[1]) }
        .environment(\.amp, .fixture())
}

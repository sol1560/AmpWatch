import SwiftUI
import AmpKit

@MainActor
@Observable
final class UsageModel {
    private(set) var state: Loadable<ThreadUsage> = .loading

    func load(threadID: String, from environment: AmpEnvironment) async {
        do {
            state = .loaded(try await environment.client.usage(threadID: threadID))
        } catch {
            state = .failed(error as? AmpError ?? .transport(String(describing: error)))
        }
    }
}

struct UsageView: View {
    let thread: ThreadSummary

    @Environment(\.amp) private var amp
    @State private var model = UsageModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                LoadingView(label: "Cost")
            case let .failed(error):
                ErrorView(error: error) { await model.load(threadID: thread.id, from: amp) }
            case let .loaded(usage):
                breakdown(usage)
            }
        }
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Cost")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(threadID: thread.id, from: amp) }
    }

    private func breakdown(_ usage: ThreadUsage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(Money.compact(usd: usage.usage))
                    .font(AmpTheme.display(34))
                    .foregroundStyle(AmpTheme.parchment)
                    .accessibilityIdentifier("total-cost")

                Text(usage.subThreadIDs.isEmpty
                     ? "this thread"
                     : "incl. \(usage.subThreadIDs.count) subthreads")
                    .font(AmpTheme.body(11))
                    .foregroundStyle(AmpTheme.parchmentDim)

                AmpRule()

                ForEach(usage.modelsByCost, id: \.model) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model.model)
                                .font(AmpTheme.body(13))
                                .foregroundStyle(AmpTheme.parchment)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Money.compact(usd: model.usage))
                                .font(AmpTheme.body(13, weight: .medium))
                                .foregroundStyle(AmpTheme.ember)
                        }
                        Text("\(TokenCount.compact(model.inputTokens)) in · \(TokenCount.compact(model.outputTokens)) out")
                            .font(AmpTheme.body(10))
                            .foregroundStyle(AmpTheme.parchmentDim)
                    }
                }
            }
        }
        .accessibilityIdentifier("usage")
    }
}

import SwiftUI
import AmpKit

struct LoadingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .ampAccent()
            Text(label)
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.parchmentDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("loading")
    }
}

struct EmptyStateView: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(AmpTheme.display(18))
                .foregroundStyle(AmpTheme.parchment)
            AmpRule()
            Text(detail)
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.parchmentDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("empty-state")
    }
}

struct ErrorView: View {
    let error: AmpError
    let retry: @Sendable () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.watchDescription)
                .font(AmpTheme.display(18))
                .foregroundStyle(AmpTheme.ember)
            AmpRule()
            Text(detail)
                .font(AmpTheme.body(12))
                .foregroundStyle(AmpTheme.parchmentDim)
                .lineLimit(3)
            Button("Retry") {
                Task { await retry() }
            }
            .buttonStyle(.bordered)
            .ampAccent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("error-state")
    }

    /// Says what the user can actually do about it, rather than echoing a
    /// status code they cannot act on.
    private var detail: String {
        switch error {
        case .unauthorized:
            WatchStrings.text("error.unauthorized.detail")
        case .forbidden:
            WatchStrings.text("error.forbidden.detail")
        case .notFound:
            WatchStrings.text("error.not_found.detail")
        case let .rateLimited(retryAfter):
            retryAfter.map { WatchStrings.format("error.rate_limited.retry", Int($0)) }
                ?? WatchStrings.text("error.rate_limited.detail")
        case .server:
            WatchStrings.text("error.server.detail")
        case .transport:
            WatchStrings.text("error.transport.detail")
        case .decoding:
            WatchStrings.text("error.decoding.detail")
        }
    }
}

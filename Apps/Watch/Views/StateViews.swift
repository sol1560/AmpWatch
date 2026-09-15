import SwiftUI
import AmpKit

struct LoadingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(AmpTheme.ember)
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
            .tint(AmpTheme.ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("error-state")
    }

    /// Says what the user can actually do about it, rather than echoing a
    /// status code they cannot act on.
    private var detail: String {
        switch error {
        case .unauthorized:
            "The API token was rejected. Re-pair from the phone app."
        case .forbidden:
            "This token cannot read thread contents. Add the threads.contents:view scope."
        case .notFound:
            "That thread is gone."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Too many requests. Try again in \(Int($0))s." }
                ?? "Too many requests."
        case .server:
            "Amp had a problem. Try again."
        case .transport:
            "The watch could not reach ampcode.com."
        case .decoding:
            "Amp sent something this build does not understand."
        }
    }
}

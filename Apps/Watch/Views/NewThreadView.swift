import SwiftUI
import AmpKit

@MainActor
@Observable
final class NewThreadModel {
    enum Status: Equatable {
        case editing, sending, sent, queued, failed(String)
    }

    var prompt = ""
    var mode: AgentMode = .medium
    /// Title of the chosen template, or `nil` for a blank prompt.
    var template: String?
    private(set) var status: Status = .editing

    var canSend: Bool {
        status != .sending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func apply(_ template: ThreadTemplate?) {
        guard let template else { return }
        prompt = template.prompt
        mode = template.mode
    }

    func send(using environment: AmpEnvironment) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        status = .sending
        guard let outcome = await environment.deliver(.create(prompt: text, mode: mode)) else {
            status = .failed(WatchStrings.text("No bridge configured"))
            return
        }
        switch outcome {
        case .delivered:
            prompt = ""
            status = .sent
        case .queued:
            prompt = ""
            status = .queued
        case let .dropped(reason):
            status = .failed(OutboxStatus.note(for: reason))
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
    @State private var templates: [ThreadTemplate] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Templates first: on a watch the common case is "start the
                // usual thing", and the field below fills in from the pick.
                Picker(selection: $model.template) {
                    Text("blank").tag(String?.none)
                    ForEach(templates) { template in
                        Text(template.title).tag(String?.some(template.title))
                    }
                } label: {
                    Label("Template", systemImage: "doc.text")
                }
                .pickerStyle(.navigationLink)
                .font(AmpTheme.body(13))
                .onChange(of: model.template) { _, title in
                    model.apply(templates.first { $0.title == title })
                }
                .accessibilityIdentifier("template-picker")

                TextField("What should it do?", text: $model.prompt, axis: .vertical)
                    .font(AmpTheme.body(14))
                    .accessibilityIdentifier("new-thread-prompt")

                DictationButton(text: $model.prompt)
                    .disabled(model.status == .sending)

                Picker(selection: $model.mode) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
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
                .ampAccent()
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
        .onAppear { templates = amp.preferences.load().templates }
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
            Text("started — it will show in the list shortly")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
        case .queued:
            Text("saved — starts when the watch is back online")
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.parchment)
        case let .failed(message):
            Text(message)
                .font(AmpTheme.body(11))
                .foregroundStyle(AmpTheme.ember)
        }
    }
}

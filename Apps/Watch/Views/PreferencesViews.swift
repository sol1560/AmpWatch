import SwiftUI
import AmpKit

/// The tap-to-fill phrases the Reply screen offers. Add by typing (or
/// dictating) into the field; remove by swiping a row.
///
/// The rules — trim, no blanks, no duplicates, a length cap — live in
/// `WatchPreferences`, where they are tested. This screen only shows the
/// result and saves it.
struct PhrasesView: View {
    @Environment(\.amp) private var amp
    @State private var preferences = WatchPreferences.defaults
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                TextField("New phrase", text: $draft)
                    .font(AmpTheme.body(13))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("phrase-field")
                    .onSubmit(add)
            } footer: {
                Text("Up to \(WatchPreferences.maxPhraseLength) characters. Longer thoughts are better dictated on the Reply screen.")
                    .font(AmpTheme.body(11))
                    .foregroundStyle(AmpTheme.parchmentDim)
            }

            Section {
                ForEach(preferences.phrases, id: \.self) { phrase in
                    Text(phrase)
                        .font(AmpTheme.body(14))
                        .foregroundStyle(AmpTheme.parchment)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("phrase-row")
                }
                .onDelete { offsets in
                    for phrase in offsets.map({ preferences.phrases[$0] }) {
                        preferences.removePhrase(phrase)
                    }
                    amp.preferences.save(preferences)
                }
            } header: {
                Text(preferences.phrases.isEmpty ? "No phrases yet" : "Swipe left to remove")
                    .font(AmpTheme.body(11))
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
        }
        .listStyle(.plain)
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Phrases")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("phrases")
        .onAppear { preferences = amp.preferences.load() }
    }

    private func add() {
        guard preferences.addPhrase(draft) else { return }
        draft = ""
        amp.preferences.save(preferences)
    }
}

/// Opening prompts for new threads: a title the picker shows, the prompt it
/// fills in, and the mode it starts in. Saving under an existing title
/// replaces that template.
struct TemplatesView: View {
    @Environment(\.amp) private var amp
    @State private var preferences = WatchPreferences.defaults
    @State private var title = ""
    @State private var prompt = ""
    @State private var mode: AgentMode = .medium

    var body: some View {
        List {
            Section {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("template-title-field")
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .accessibilityIdentifier("template-prompt-field")
                Picker("Mode", selection: $mode) {
                    ForEach(AgentMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.navigationLink)
                Button {
                    save()
                } label: {
                    Label("Save template", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AmpTheme.ember)
                .disabled(!canSave)
                .accessibilityIdentifier("template-save-button")
            }
            .font(AmpTheme.body(13))

            Section {
                ForEach(preferences.templates) { template in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(template.title)
                                .font(AmpTheme.body(14, weight: .medium))
                                .foregroundStyle(AmpTheme.parchment)
                            Spacer()
                            Text(template.mode.rawValue)
                                .font(AmpTheme.body(11))
                                .foregroundStyle(AmpTheme.ember)
                        }
                        Text(template.prompt)
                            .font(AmpTheme.body(11))
                            .foregroundStyle(AmpTheme.parchmentDim)
                            .lineLimit(2)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("template-row")
                }
                .onDelete { offsets in
                    for template in offsets.map({ preferences.templates[$0] }) {
                        preferences.removeTemplate(titled: template.title)
                    }
                    amp.preferences.save(preferences)
                }
            } header: {
                Text(preferences.templates.isEmpty ? "No templates yet" : "Swipe left to remove")
                    .font(AmpTheme.body(11))
                    .foregroundStyle(AmpTheme.parchmentDim)
            }
        }
        .listStyle(.plain)
        .containerBackground(AmpTheme.canvas.gradient, for: .navigation)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("templates")
        .onAppear { preferences = amp.preferences.load() }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard preferences.addTemplate(title: title, prompt: prompt, mode: mode) else { return }
        title = ""
        prompt = ""
        mode = .medium
        amp.preferences.save(preferences)
    }
}

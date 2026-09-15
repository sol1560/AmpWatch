import Foundation

/// A canned opening prompt for a new thread.
public struct ThreadTemplate: Sendable, Hashable, Codable, Identifiable {
    public var id: String { title }
    public let title: String
    public let prompt: String
    public let mode: AgentMode

    public init(title: String, prompt: String, mode: AgentMode = .medium) {
        self.title = title
        self.prompt = prompt
        self.mode = mode
    }
}

/// Everything the user can tune on the wrist that is not a credential:
/// the phrases the reply screen offers, the templates the new-thread screen
/// offers, and the cost at which a thread is flagged.
///
/// A value type with the editing rules on it, so "what happens when you add a
/// duplicate phrase" is a unit test and not a guess about a `List`.
public struct WatchPreferences: Sendable, Equatable, Codable {
    /// Longest phrase or template prompt the watch will keep. Longer text is
    /// a paragraph, and paragraphs are dictated, not tapped.
    public static let maxPhraseLength = 120

    public var phrases: [String]
    public var templates: [ThreadTemplate]
    /// Per-thread USD cost at which the watch flags a thread; `nil` is off.
    public var budgetCapUSD: Double?

    public init(phrases: [String], templates: [ThreadTemplate], budgetCapUSD: Double?) {
        self.phrases = phrases
        self.templates = templates
        self.budgetCapUSD = budgetCapUSD
    }

    /// What a fresh install offers. Short enough to read in a chip, and each
    /// one is a thing a student actually says to an agent from across the room.
    public static let defaults = WatchPreferences(
        phrases: [
            "Continue",
            "Run the tests",
            "Ship it",
            "Stop and explain",
            "Undo that",
            "Try another way",
        ],
        templates: [
            ThreadTemplate(
                title: "Fix CI",
                prompt: "CI is failing on main. Find the cause, fix it, and push when the workflow is green.",
                mode: .medium
            ),
            ThreadTemplate(
                title: "Review last commit",
                prompt: "Review the last commit on main for bugs and anything that would surprise a reviewer. Report; do not change code.",
                mode: .high
            ),
            ThreadTemplate(
                title: "Write tests",
                prompt: "Find the least-tested module and add tests that would catch a real regression. Run them.",
                mode: .medium
            ),
        ],
        budgetCapUSD: 5
    )

    // MARK: Editing

    /// Adds a phrase. Whitespace is trimmed; empty, over-long and duplicate
    /// entries are ignored so the list cannot fill with near-copies.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func addPhrase(_ raw: String) -> Bool {
        guard let phrase = Self.clean(raw), !phrases.contains(phrase) else { return false }
        phrases.append(phrase)
        return true
    }

    public mutating func removePhrase(_ phrase: String) {
        phrases.removeAll { $0 == phrase }
    }

    /// Adds a template. A template whose title is already taken replaces the
    /// old one, because on a watch "edit" and "add again" are the same gesture.
    @discardableResult
    public mutating func addTemplate(title rawTitle: String, prompt rawPrompt: String, mode: AgentMode) -> Bool {
        guard let title = Self.clean(rawTitle, limit: 40), let prompt = Self.clean(rawPrompt, limit: 500) else {
            return false
        }
        let template = ThreadTemplate(title: title, prompt: prompt, mode: mode)
        if let index = templates.firstIndex(where: { $0.title == title }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        return true
    }

    public mutating func removeTemplate(titled title: String) {
        templates.removeAll { $0.title == title }
    }

    private static func clean(_ raw: String, limit: Int = maxPhraseLength) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { return nil }
        return trimmed
    }
}

/// Where a thread's spend sits against the cap.
public enum BudgetStanding: Sendable, Equatable {
    /// No cap set, or well under it.
    case fine
    /// Within the last fifth of the cap: worth a glance.
    case near
    /// At or past the cap.
    case over

    public static let nearFraction = 0.8

    public init(usageUSD: Double, capUSD: Double?) {
        guard let capUSD, capUSD > 0 else {
            self = .fine
            return
        }
        if usageUSD >= capUSD {
            self = .over
        } else if usageUSD >= capUSD * Self.nearFraction {
            self = .near
        } else {
            self = .fine
        }
    }
}

/// Keeps `WatchPreferences` in `UserDefaults`.
///
/// Nothing in here is secret, so the Keychain would be the wrong place; and
/// unlike the outbox it is fine to lose on reinstall.
///
/// `UserDefaults` is documented thread-safe; Apple's SDK marks it `Sendable`,
/// swift-corelibs-foundation on Linux does not yet.
public struct PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ampwatch.preferences") {
        self.defaults = defaults
        self.key = key
    }

    /// The saved preferences, or the defaults if none were ever saved or the
    /// saved form is one this build cannot read.
    public func load() -> WatchPreferences {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(WatchPreferences.self, from: data)
        else { return .defaults }
        return saved
    }

    public func save(_ preferences: WatchPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

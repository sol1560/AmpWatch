import XCTest
@testable import AmpKit

final class WatchPreferencesTests: XCTestCase {

    func testAddPhraseTrimsAndRejectsDuplicatesAndBlanks() {
        var prefs = WatchPreferences(phrases: ["Continue"], templates: [], budgetCapUSD: nil)

        XCTAssertFalse(prefs.addPhrase("  Continue "), "same phrase with whitespace is a duplicate")
        XCTAssertFalse(prefs.addPhrase("   "))
        XCTAssertFalse(prefs.addPhrase(String(repeating: "x", count: WatchPreferences.maxPhraseLength + 1)))
        XCTAssertTrue(prefs.addPhrase(" Run the tests\n"))

        XCTAssertEqual(prefs.phrases, ["Continue", "Run the tests"])
    }

    func testAddTemplateWithSameTitleReplacesInPlace() {
        var prefs = WatchPreferences.defaults
        let before = prefs.templates.map(\.title)

        XCTAssertTrue(prefs.addTemplate(title: "Fix CI", prompt: "Make CI green.", mode: .high))

        XCTAssertEqual(prefs.templates.map(\.title), before, "order must not change on edit")
        XCTAssertEqual(prefs.templates.first { $0.title == "Fix CI" }?.prompt, "Make CI green.")
        XCTAssertEqual(prefs.templates.first { $0.title == "Fix CI" }?.mode, .high)
    }

    func testRemoveTemplateByTitle() {
        var prefs = WatchPreferences.defaults
        prefs.removeTemplate(titled: "Write tests")
        XCTAssertFalse(prefs.templates.contains { $0.title == "Write tests" })
        XCTAssertEqual(prefs.templates.count, WatchPreferences.defaults.templates.count - 1)
    }

    func testBudgetStandingBoundaries() {
        // No cap, or a nonsense cap, never flags.
        XCTAssertEqual(BudgetStanding(usageUSD: 999, capUSD: nil), .fine)
        XCTAssertEqual(BudgetStanding(usageUSD: 999, capUSD: 0), .fine)

        XCTAssertEqual(BudgetStanding(usageUSD: 3.99, capUSD: 5), .fine)
        XCTAssertEqual(BudgetStanding(usageUSD: 4.00, capUSD: 5), .near, "80 % is near, inclusive")
        XCTAssertEqual(BudgetStanding(usageUSD: 4.99, capUSD: 5), .near)
        XCTAssertEqual(BudgetStanding(usageUSD: 5.00, capUSD: 5), .over, "at the cap is over, inclusive")
    }

    func testStoreRoundTripsAndFallsBackToDefaults() throws {
        let suite = "ampwatch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), .defaults)

        var edited = WatchPreferences.defaults
        edited.addPhrase("Deploy to staging")
        edited.budgetCapUSD = 2.5
        store.save(edited)

        XCTAssertEqual(PreferencesStore(defaults: defaults).load(), edited)

        // Garbage on disk must not take the phrases screen down with it.
        defaults.set(Data("not json".utf8), forKey: "ampwatch.preferences")
        XCTAssertEqual(store.load(), .defaults)
    }
}

import XCTest
@testable import AmpKit

final class ThreadGroupTests: XCTestCase {
    func testGroupsAndRowsUseUpdateTimeNotInputOrderOrCreationTime() {
        let a = Repository(url: "https://github.com/owner/a")
        let b = Repository(url: "https://github.com/owner/b")
        let groups = ThreadGroup.grouped([
            thread("old-a", 1, [a]), thread("middle-b", 3, [b]),
            thread("new-a", 5, [a]), thread("older-b", 2, [b]),
        ])
        XCTAssertEqual(groups.map(\.title), ["owner/a", "owner/b"])
        XCTAssertEqual(groups.map { $0.threads.map(\.id) }, [["new-a", "old-a"], ["middle-b", "older-b"]])
    }

    func testMissingMetadataAndTiedDatesHaveStableOrder() {
        let groups = ThreadGroup.grouped([
            ThreadSummary(id: "z"), ThreadSummary(id: "a"),
            thread("dated", 1, [Repository(url: "https://github.com/owner/repo")]),
        ])
        XCTAssertEqual(groups.map(\.title), ["owner/repo", "Repository unavailable"])
        XCTAssertEqual(groups.last?.threads.map(\.id), ["a", "z"])
        XCTAssertNil(groups.last?.id)
        XCTAssertTrue(ThreadGroup.grouped([]).isEmpty)
    }

    func testUsesFirstRepositoryOnceAndKeepsDifferentHostsSeparate() {
        let github = Repository(url: "https://github.com/owner/repo", dir: "one")
        let gitlab = Repository(url: "https://gitlab.com/owner/repo")
        let groups = ThreadGroup.grouped([
            thread("multi", 4, [github, gitlab]),
            thread("same-repo", 2, [Repository(url: github.url, dir: "two")]),
            thread("other-host", 3, [gitlab]),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.id), [github.url, gitlab.url])
        XCTAssertEqual(groups.map { $0.threads.map(\.id) }, [["multi", "same-repo"], ["other-host"]])
    }

    private func thread(_ id: String, _ seconds: Double, _ repositories: [Repository]) -> ThreadSummary {
        ThreadSummary(id: id, createdAt: Date(timeIntervalSince1970: 100 - seconds),
                      updatedAt: Date(timeIntervalSince1970: seconds), repositories: repositories)
    }
}

import XCTest
@testable import ClaudeMonitorCore

final class T3ProjectNameTests: XCTestCase {
    private let home = "/Users/alice"

    func testT3WorktreeReturnsTitle() {
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/.t3/worktrees/table-side/t3code-5f2b1115", home: home),
            "table-side"
        )
    }

    func testT3WorktreeNestedReturnsTitle() {
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/.t3/worktrees/table-side/t3code-5f2b1115/nested", home: home),
            "table-side"
        )
    }

    func testT3WorktreeTrailingTitleOnly() {
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/.t3/worktrees/table-side", home: home),
            "table-side"
        )
    }

    func testNonT3PathFallsBackToBasename() {
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/Development/foo", home: home),
            "foo"
        )
    }

    func testHomeWithTrailingSlash() {
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/.t3/worktrees/table-side/t3code-5f2b1115", home: "/Users/alice/"),
            "table-side"
        )
    }

    func testT3WorktreesRootFallsBackToBasename() {
        // cwd is exactly <home>/.t3/worktrees — no title segment. Falls through to basename.
        XCTAssertEqual(
            deriveProject(cwd: "/Users/alice/.t3/worktrees", home: home),
            "worktrees"
        )
    }
}

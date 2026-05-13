import XCTest
@testable import ClaudeMonitorCore

final class DisambiguationTests: XCTestCase {

    // MARK: - Helpers

    private func session(id: String, project: String, cwd: String) -> SessionInfo {
        SessionInfo(
            session_id: id, status: "idle",
            project: project, cwd: cwd,
            terminal: "", terminal_session_id: "",
            started_at: "2024-01-01T00:00:00Z",
            updated_at: "2024-01-01T00:00:00Z",
            last_prompt: ""
        )
    }

    // MARK: - Tests

    func test_empty_returnsEmptyMap() {
        let result = disambiguateNames([])
        XCTAssertTrue(result.isEmpty)
    }

    func test_uniqueProjects_returnsEmptyMap() {
        let sessions = [
            session(id: "a", project: "alpha", cwd: "/home/user/alpha"),
            session(id: "b", project: "beta", cwd: "/home/user/beta"),
        ]
        let result = disambiguateNames(sessions)
        XCTAssertTrue(result.isEmpty)
    }

    func test_singleSession_noEntry() {
        let sessions = [session(id: "a", project: "myproj", cwd: "/home/user/myproj")]
        let result = disambiguateNames(sessions)
        XCTAssertNil(result["a"])
    }

    func test_twoSessionsSameProject_differentParents_getParentSuffix() {
        let sessions = [
            session(id: "a", project: "myproj", cwd: "/home/alice/myproj"),
            session(id: "b", project: "myproj", cwd: "/home/bob/myproj"),
        ]
        let result = disambiguateNames(sessions)
        XCTAssertEqual(result["a"], "alice/myproj")
        XCTAssertEqual(result["b"], "bob/myproj")
    }

    func test_twoSessionsSameProject_deepDiff_findsFirstDifferingAncestor() {
        let sessions = [
            session(id: "a", project: "myproj", cwd: "/home/user/clientA/myproj"),
            session(id: "b", project: "myproj", cwd: "/home/user/clientB/myproj"),
        ]
        let result = disambiguateNames(sessions)
        XCTAssertEqual(result["a"], "clientA/myproj")
        XCTAssertEqual(result["b"], "clientB/myproj")
    }

    func test_twoSessionsSameProject_identicalCwd_fallsBackToFullCwd() {
        let sessions = [
            session(id: "a", project: "myproj", cwd: "/home/user/myproj"),
            session(id: "b", project: "myproj", cwd: "/home/user/myproj"),
        ]
        let result = disambiguateNames(sessions)
        XCTAssertEqual(result["a"], "/home/user/myproj")
        XCTAssertEqual(result["b"], "/home/user/myproj")
    }

    func test_onlyCollisionsGetEntries_uniqueProjectsUnaffected() {
        let sessions = [
            session(id: "a", project: "myproj", cwd: "/home/alice/myproj"),
            session(id: "b", project: "myproj", cwd: "/home/bob/myproj"),
            session(id: "c", project: "other", cwd: "/home/user/other"),
        ]
        let result = disambiguateNames(sessions)
        XCTAssertNotNil(result["a"])
        XCTAssertNotNil(result["b"])
        XCTAssertNil(result["c"])
    }
}

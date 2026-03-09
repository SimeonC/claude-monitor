import XCTest
@testable import ClaudeMonitorCore

final class GhosttyMatchingTests: XCTestCase {

    // MARK: - Non-tmux titles always score 0

    func testNonTmuxTitleScoresZero() {
        XCTAssertEqual(scoreGhosttyWindow(title: "fish — my-project", doc: "", cwd: "/my-project"), 0)
        XCTAssertEqual(scoreGhosttyWindow(title: "vim my-project", doc: "", cwd: "/my-project"), 0)
        XCTAssertEqual(scoreGhosttyWindow(title: "", doc: "", cwd: "/my-project"), 0)
    }

    func testTmuxPrefixCaseInsensitive() {
        // "tmux " prefix check is lowercased, so "Tmux " should also match
        // (the guard uses lower.hasPrefix("tmux "))
        XCTAssertEqual(scoreGhosttyWindow(title: "Tmux [3] proj", doc: "", cwd: "/proj", sessionId: "3"), 40)
    }

    // MARK: - Bracket ID matching (score 40)

    func testBracketIdMatchScores40() {
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] my-project", doc: "", cwd: "/my-project", sessionId: "3"),
            40)
    }

    func testBracketIdMismatchScoresZero() {
        // Title has [3] but we're looking for session "4" — must not steal the window
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] my-project", doc: "", cwd: "/my-project", sessionId: "4"),
            0)
    }

    func testBracketIdPresentButEmptySessionIdScoresZero() {
        // A session with no monitor_id (empty sessionId) must not match a monitored window
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] my-project", doc: "", cwd: "/my-project", sessionId: ""),
            0)
    }

    func testBracketIdDefaultSessionIdScoresZero() {
        // Default sessionId = "" — same as above via default parameter
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] my-project", doc: "", cwd: "/my-project"),
            0)
    }

    // MARK: - Two sessions, same CWD, different monitor IDs

    func testSameCwdDifferentMonitorIds_correctSessionMatches() {
        // Simulates clicking row A (sessionId "3") when window [3] and [4] both exist
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] proj", doc: "", cwd: "/proj", sessionId: "3"),
            40, "Session 3 should score 40 against window [3]")
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [4] proj", doc: "", cwd: "/proj", sessionId: "3"),
            0, "Session 3 should score 0 against window [4]")
    }

    func testSameCwdDifferentMonitorIds_otherSessionMatches() {
        // Simulates clicking row B (sessionId "4")
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [4] proj", doc: "", cwd: "/proj", sessionId: "4"),
            40, "Session 4 should score 40 against window [4]")
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux [3] proj", doc: "", cwd: "/proj", sessionId: "4"),
            0, "Session 4 should score 0 against window [3]")
    }

    // MARK: - AXDocument CWD matching (score 30)

    func testAxDocumentCwdMatchScores30() {
        XCTAssertEqual(
            scoreGhosttyWindow(
                title: "tmux my-project", doc: "file:///home/user/my-project/",
                cwd: "/home/user/my-project"),
            30)
    }

    func testAxDocumentCwdMatchWithoutTrailingSlash() {
        // doc without trailing slash — normalisation should still match
        XCTAssertEqual(
            scoreGhosttyWindow(
                title: "tmux my-project", doc: "file:///home/user/my-project",
                cwd: "/home/user/my-project"),
            30)
    }

    func testAxDocumentCwdMismatchDoesNotScore30() {
        XCTAssertEqual(
            scoreGhosttyWindow(
                title: "tmux other-project", doc: "file:///home/user/other-project/",
                cwd: "/home/user/my-project"),
            0)
    }

    // MARK: - Basename matching (score 25)

    func testBasenameMatchScores25() {
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux my-project — fish", doc: "", cwd: "/home/user/my-project"),
            25)
    }

    func testBasenameMatchIsCaseInsensitive() {
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux MY-PROJECT", doc: "", cwd: "/home/user/my-project"),
            25)
    }

    func testBasenameNotInTitleScoresZero() {
        XCTAssertEqual(
            scoreGhosttyWindow(title: "tmux something-else", doc: "", cwd: "/home/user/my-project"),
            0)
    }

    // MARK: - Score priority: AXDocument beats basename

    func testAxDocumentBeatsBasename() {
        // doc matches → 30, not 25 from basename
        XCTAssertEqual(
            scoreGhosttyWindow(
                title: "tmux my-project", doc: "file:///home/user/my-project/",
                cwd: "/home/user/my-project"),
            30)
    }

    // MARK: - Score priority: bracket ID beats AXDocument

    func testBracketIdBeatsAxDocument() {
        // Has both [3] match AND matching AXDocument — should return 40
        XCTAssertEqual(
            scoreGhosttyWindow(
                title: "tmux [3] my-project", doc: "file:///home/user/my-project/",
                cwd: "/home/user/my-project", sessionId: "3"),
            40)
    }
}

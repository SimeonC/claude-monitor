import XCTest
@testable import ClaudeMonitorCore

final class TeamLinkResolverTests: XCTestCase {

    // MARK: - Helpers

    private func session(id: String, cwd: String) -> SessionInfo {
        SessionInfo(
            session_id: id, status: "idle",
            project: "proj", cwd: cwd,
            terminal: "", terminal_session_id: "",
            started_at: "2024-01-01T00:00:00Z",
            updated_at: "2024-01-01T00:00:00Z",
            last_prompt: ""
        )
    }

    // MARK: - Bug reproduction

    // Two leads A (cwd=/proj/svg) and B (cwd=/proj/table); team name map says "t" → B;
    // two teammates with cwd=/proj/svg → both must resolve to A (cwd fallback).
    func test_cwdCollisionFallback_picksCwdMatchingLead() {
        let leadA = session(id: "A", cwd: "/proj/svg")
        let leadB = session(id: "B", cwd: "/proj/table")
        let mate1 = session(id: "m1", cwd: "/proj/svg")
        let mate2 = session(id: "m2", cwd: "/proj/svg")
        let sessions = [leadA, leadB, mate1, mate2]
        let teamNameBySession = ["m1": "t", "m2": "t"]
        let leadSessionByTeamName = ["t": "B"]  // wrong lead due to collision

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: leadSessionByTeamName
        )

        XCTAssertEqual(result["m1"], "A")
        XCTAssertEqual(result["m2"], "A")
    }

    // MARK: - Normal path

    func test_normalPath_cwdMatches_resolvesViaMap() {
        let lead = session(id: "L", cwd: "/proj")
        let mate = session(id: "m", cwd: "/proj")
        let sessions = [lead, mate]
        let teamNameBySession = ["m": "myteam"]
        let leadSessionByTeamName = ["myteam": "L"]

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: leadSessionByTeamName
        )

        XCTAssertEqual(result["m"], "L")
    }

    // MARK: - Ambiguous cwd

    // Two non-teammate sessions share the same cwd → can't pick one safely → fall back to map.
    func test_ambiguousCwd_fallsBackToMap() {
        let leadA = session(id: "A", cwd: "/shared")
        let leadB = session(id: "B", cwd: "/shared")
        let mate = session(id: "m", cwd: "/shared")
        let sessions = [leadA, leadB, mate]
        let teamNameBySession = ["m": "t"]
        let leadSessionByTeamName = ["t": "A"]

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: leadSessionByTeamName
        )

        XCTAssertEqual(result["m"], "A")
    }

    // MARK: - Mapped lead not loaded

    // Mapped lead is absent from loaded sessions; unique cwd candidate wins.
    func test_leadNotLoaded_cwdCandidateWins() {
        let actual = session(id: "A", cwd: "/proj")
        let mate = session(id: "m", cwd: "/proj")
        let sessions = [actual, mate]
        let teamNameBySession = ["m": "t"]
        let leadSessionByTeamName = ["t": "MISSING"]

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: leadSessionByTeamName
        )

        XCTAssertEqual(result["m"], "A")
    }

    // MARK: - Non-teammates

    func test_nonTeammateSessions_notInResult() {
        let lead = session(id: "L", cwd: "/proj")
        let plain = session(id: "P", cwd: "/other")
        let sessions = [lead, plain]

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: [:],
            leadSessionByTeamName: [:]
        )

        XCTAssertTrue(result.isEmpty)
    }

    // Unrecognised team name (no entry in leadSessionByTeamName, no cwd candidate) → unlinked.
    func test_unknownTeamName_noCandidate_unlinked() {
        let mate = session(id: "m", cwd: "/proj")
        let sessions = [mate]
        let teamNameBySession = ["m": "t"]
        let leadSessionByTeamName: [String: String] = [:]

        let result = resolveTeamParents(
            sessions: sessions,
            teamNameBySession: teamNameBySession,
            leadSessionByTeamName: leadSessionByTeamName
        )

        XCTAssertNil(result["m"])
    }
}

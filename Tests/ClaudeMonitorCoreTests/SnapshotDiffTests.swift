import XCTest
@testable import ClaudeMonitorCore

final class SnapshotDiffTests: XCTestCase {

    // MARK: - Helpers

    private func session(
        id: String = "s1",
        status: String = "idle",
        project: String = "myproj",
        cwd: String = "/home/user/myproj",
        updatedAt: String = "2024-01-01T12:00:00Z",
        terminalSessionId: String = ""
    ) -> SessionInfo {
        SessionInfo(
            session_id: id, status: status,
            project: project, cwd: cwd,
            terminal: "Ghostty", terminal_session_id: terminalSessionId,
            started_at: "2024-01-01T00:00:00Z",
            updated_at: updatedAt,
            last_prompt: ""
        )
    }

    private func hash(for s: SessionInfo, activeId: String? = nil, teams: [String: TeamInfo] = [:]) -> UInt64 {
        let snap = buildSnapshot(sessions: [s], teams: teams, activeId: activeId, generation: 0)
        return snap.rows[0].identityHash
    }

    // MARK: - Stable hash

    func test_sameInputs_sameHash() {
        let s = session()
        let h1 = hash(for: s)
        let h2 = hash(for: s)
        XCTAssertEqual(h1, h2)
    }

    func test_identicalSessionDifferentInstance_sameHash() {
        let a = session(status: "working", updatedAt: "2024-06-01T10:00:00Z")
        let b = session(status: "working", updatedAt: "2024-06-01T10:00:00Z")
        XCTAssertEqual(hash(for: a), hash(for: b))
    }

    // MARK: - Rendered fields flip the hash

    func test_statusChange_differentHash() {
        let idle = session(status: "idle")
        let working = session(status: "working")
        XCTAssertNotEqual(hash(for: idle), hash(for: working))
    }

    func test_projectChange_differentHash() {
        let a = session(project: "alpha")
        let b = session(project: "beta")
        XCTAssertNotEqual(hash(for: a), hash(for: b))
    }

    func test_updatedAtChange_byOneSecond_differentHash() {
        let a = session(updatedAt: "2024-01-01T12:00:00Z")
        let b = session(updatedAt: "2024-01-01T12:00:01Z")
        XCTAssertNotEqual(hash(for: a), hash(for: b))
    }

    func test_isActiveChange_differentHash() {
        let s = session(id: "s1")
        let inactive = hash(for: s, activeId: nil)
        let active = hash(for: s, activeId: "s1")
        XCTAssertNotEqual(inactive, active)
    }

    func test_teamNameChange_differentHash() {
        let s = session(id: "s1")
        let noTeam = hash(for: s, teams: [:])
        let withTeam = hash(
            for: s,
            teams: ["s1": TeamInfo(name: "MyTeam", activeAgentCount: 0, members: [], tasks: [])]
        )
        XCTAssertNotEqual(noTeam, withTeam)
    }

    func test_permissionModeChange_differentHash() {
        var noMode = session()
        var planMode = session()
        planMode.permission_mode = "plan"
        XCTAssertNotEqual(hash(for: noMode), hash(for: planMode))
    }

    func test_differentPermissionModes_differentHashes() {
        var plan = session()
        plan.permission_mode = "plan"
        var accept = session()
        accept.permission_mode = "acceptEdits"
        XCTAssertNotEqual(hash(for: plan), hash(for: accept))
    }

    // MARK: - Non-rendered fields do NOT flip the hash

    func test_terminalSessionIdChange_sameHash() {
        let a = session(terminalSessionId: "tty1")
        let b = session(terminalSessionId: "tty2")
        XCTAssertEqual(hash(for: a), hash(for: b))
    }

    func test_differentSessionId_sameRenderedFields_sameHash() {
        // Two different sessions with identical rendered fields should have the same identity hash.
        let a = session(id: "session-aaa", status: "idle", updatedAt: "2024-01-01T12:00:00Z")
        let b = session(id: "session-bbb", status: "idle", updatedAt: "2024-01-01T12:00:00Z")
        XCTAssertEqual(hash(for: a), hash(for: b))
    }

    func test_updatedAtChange_subSecond_sameHash() {
        // Sub-second differences in updated_at should NOT flip the hash (bucketed to seconds).
        let a = session(updatedAt: "2024-01-01T12:00:00.000Z")
        let b = session(updatedAt: "2024-01-01T12:00:00.999Z")
        XCTAssertEqual(hash(for: a), hash(for: b))
    }
}

import XCTest
@testable import ClaudeMonitorCore

final class SnapshotBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func session(
        id: String,
        status: String = "idle",
        project: String = "myproj",
        cwd: String = "/home/user/myproj",
        updatedAt: String = "2024-01-01T12:00:00Z",
        mergedIds: [String]? = nil
    ) -> SessionInfo {
        SessionInfo(
            session_id: id, status: status,
            project: project, cwd: cwd,
            terminal: "", terminal_session_id: "",
            started_at: "2024-01-01T00:00:00Z",
            updated_at: updatedAt,
            last_prompt: "",
            merged_session_ids: mergedIds
        )
    }

    // MARK: - Tracer bullet

    func test_emptySessions_emptySnapshot() {
        let snap = buildSnapshot(sessions: [], teams: [:], activeId: nil, generation: 0)
        XCTAssertTrue(snap.rows.isEmpty)
        XCTAssertEqual(snap.totalCount, 0)
        XCTAssertNil(snap.activeSessionId)
    }

    // MARK: - Basic row population

    func test_singleSession_producesOneRow() {
        let s = session(id: "abc", status: "idle", project: "myproj")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 1)
        XCTAssertEqual(snap.rows.count, 1)
        XCTAssertEqual(snap.rows[0].id, "abc")
        XCTAssertEqual(snap.rows[0].session.session_id, "abc")
    }

    func test_rowDisplayName_equalsProjectWhenNoCollision() {
        let s = session(id: "a", project: "myproj")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 1)
        XCTAssertEqual(snap.rows[0].displayName, "myproj")
    }

    func test_generation_passthroughToSnapshot() {
        let snap = buildSnapshot(sessions: [], teams: [:], activeId: nil, generation: 42)
        XCTAssertEqual(snap.generation, 42)
    }

    func test_totalCount_matchesRowCount() {
        let sessions = [session(id: "a"), session(id: "b"), session(id: "c")]
        let snap = buildSnapshot(sessions: sessions, teams: [:], activeId: nil, generation: 0)
        XCTAssertEqual(snap.totalCount, 3)
        XCTAssertEqual(snap.rows.count, 3)
    }

    // MARK: - Disambiguation

    func test_twoSessionsSameProject_rowsGetDisambiguationSuffix() {
        let sessions = [
            session(id: "a", project: "myproj", cwd: "/home/alice/myproj"),
            session(id: "b", project: "myproj", cwd: "/home/bob/myproj"),
        ]
        let snap = buildSnapshot(sessions: sessions, teams: [:], activeId: nil, generation: 0)
        let names = snap.rows.map { $0.displayName }
        XCTAssertTrue(names.contains("alice/myproj"), "Expected alice/myproj, got: \(names)")
        XCTAssertTrue(names.contains("bob/myproj"), "Expected bob/myproj, got: \(names)")
    }

    // MARK: - Active session

    func test_activeId_setsIsActiveOnMatchingRow() {
        let sessions = [session(id: "a"), session(id: "b")]
        let snap = buildSnapshot(sessions: sessions, teams: [:], activeId: "b", generation: 0)
        let rowA = snap.rows.first { $0.id == "a" }!
        let rowB = snap.rows.first { $0.id == "b" }!
        XCTAssertFalse(rowA.isActive)
        XCTAssertTrue(rowB.isActive)
    }

    func test_noActiveId_allRowsInactive() {
        let sessions = [session(id: "a"), session(id: "b")]
        let snap = buildSnapshot(sessions: sessions, teams: [:], activeId: nil, generation: 0)
        XCTAssertTrue(snap.rows.allSatisfy { !$0.isActive })
    }

    func test_activeSessionId_passthroughToSnapshot() {
        let snap = buildSnapshot(sessions: [session(id: "a")], teams: [:], activeId: "a", generation: 0)
        XCTAssertEqual(snap.activeSessionId, "a")
    }

    // MARK: - Team info

    func test_sessionInTeams_rowHasTeamAndIsTeamLead() {
        let s = session(id: "lead")
        let team = TeamInfo(name: "MyTeam", activeAgentCount: 2, members: [], tasks: [])
        let snap = buildSnapshot(sessions: [s], teams: ["lead": team], activeId: nil, generation: 0)
        XCTAssertNotNil(snap.rows[0].team)
        XCTAssertEqual(snap.rows[0].team?.name, "MyTeam")
        XCTAssertTrue(snap.rows[0].isTeamLead)
    }

    func test_sessionNotInTeams_rowHasNoTeam() {
        let s = session(id: "standalone")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 0)
        XCTAssertNil(snap.rows[0].team)
        XCTAssertFalse(snap.rows[0].isTeamLead)
    }

    func test_mergedSessionId_teamLookupFindsTeamViaAggregatedId() {
        // After aggregation, the representative session may not be the team lead directly;
        // the team lead's session_id is in merged_session_ids.
        let representative = session(id: "rep", mergedIds: ["lead-sid", "other-sid"])
        let team = TeamInfo(name: "AgentTeam", activeAgentCount: 1, members: [], tasks: [])
        let snap = buildSnapshot(
            sessions: [representative],
            teams: ["lead-sid": team],
            activeId: nil,
            generation: 0
        )
        XCTAssertNotNil(snap.rows[0].team)
        XCTAssertEqual(snap.rows[0].team?.name, "AgentTeam")
        XCTAssertTrue(snap.rows[0].isTeamLead)
    }

    // MARK: - Status bucket

    func test_statusBucket_attention() {
        let s = session(id: "a", status: "attention")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 0)
        XCTAssertEqual(snap.rows[0].statusBucket, .attention)
    }

    func test_statusBucket_working() {
        let s = session(id: "a", status: "working")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 0)
        XCTAssertEqual(snap.rows[0].statusBucket, .working)
    }

    func test_statusBucket_idle() {
        let s = session(id: "a", status: "idle")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 0)
        XCTAssertEqual(snap.rows[0].statusBucket, .idle)
    }

    func test_statusBucket_unknown_mapsToOther() {
        let s = session(id: "a", status: "shutting_down")
        let snap = buildSnapshot(sessions: [s], teams: [:], activeId: nil, generation: 0)
        XCTAssertEqual(snap.rows[0].statusBucket, .other)
    }

    // MARK: - Identity hash — customTitle

    func test_computeIdentityHash_differentCustomTitle_differentHash() {
        let base = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: nil
        )
        let withTitle = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: "tablecheck/settings-frontend#2169:core"
        )
        XCTAssertNotEqual(base, withTitle)
    }

    func test_computeIdentityHash_sameCustomTitle_stableHash() {
        let h1 = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: "demo-title"
        )
        let h2 = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: "demo-title"
        )
        XCTAssertEqual(h1, h2)
    }

    func test_computeIdentityHash_nilCustomTitle_stableHash() {
        let h1 = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: nil
        )
        let h2 = computeIdentityHash(
            status: "idle", displayName: "myproj",
            updatedAt: "2024-01-01T12:00:00Z",
            teamName: nil, isActive: false,
            permissionMode: nil, customTitle: nil
        )
        XCTAssertEqual(h1, h2)
    }
}

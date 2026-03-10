import XCTest
@testable import ClaudeMonitorCore

final class AggregationTests: XCTestCase {

    // Fixed reference date for deterministic tests
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func makeSession(
        id: String,
        status: String,
        project: String,
        cwd: String,
        terminal: String = "",
        terminalSessionId: String = "",
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        lastPrompt: String = ""
    ) -> SessionInfo {
        let updated = updatedAt ?? referenceDate
        let started = startedAt ?? referenceDate.addingTimeInterval(-60)
        return SessionInfo(
            session_id: id,
            status: status,
            project: project,
            cwd: cwd,
            terminal: terminal,
            terminal_session_id: terminalSessionId,
            started_at: fmt.string(from: started),
            updated_at: fmt.string(from: updated),
            last_prompt: lastPrompt
        )
    }

    // MARK: - Single session

    func testSingleSessionPassesThrough() {
        let session = makeSession(id: "s1", status: "idle", project: "proj", cwd: "/proj")
        let result = aggregateSessions([session], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "s1")
    }

    func testEmptyInputReturnsEmpty() {
        let result = aggregateSessions([], referenceDate: referenceDate)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Status priority: working (fresh) beats idle

    func testFreshWorkingBeatsIdle() {
        // Updated 10s ago — not stale (< 5 min threshold), priority = 1
        let working = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let idle = makeSession(id: "i", status: "idle", project: "proj", cwd: "/proj")
        let result = aggregateSessions([working, idle], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "working")
    }

    // MARK: - Regression: stale working loses to idle

    func testStaleWorkingLosesToIdle() {
        // Updated 6 min ago — stale (> 5 min threshold), demoted to priority 3
        // Idle has priority 2, so idle wins
        let staleWorking = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-360)
        )
        let idle = makeSession(id: "i", status: "idle", project: "proj", cwd: "/proj")
        let result = aggregateSessions([staleWorking, idle], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "idle",
            "Stale working session should lose to idle (regression test for stuck-working bug)")
    }

    func testWorkingExactlyAt5MinIsNotDemoted() {
        // Updated exactly 5 min ago: fiveMinAgo = ref - 300, updated = ref - 300
        // Condition: updated < fiveMinAgo → false (equal is NOT less than)
        // So still treated as fresh working → beats idle
        let working = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-300)
        )
        let idle = makeSession(id: "i", status: "idle", project: "proj", cwd: "/proj")
        let result = aggregateSessions([working, idle], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "working")
    }

    // MARK: - Attention beats working (fresh)

    func testAttentionBeatsEverything() {
        let working = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let idle = makeSession(id: "i", status: "idle", project: "proj", cwd: "/proj")
        let attention = makeSession(id: "a", status: "attention", project: "proj", cwd: "/proj")
        let result = aggregateSessions([working, idle, attention], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "attention")
    }

    // MARK: - CWD merging

    func testSessionsWithSameCWDAreMerged() {
        let a = makeSession(id: "a", status: "idle", project: "proj-a", cwd: "/shared/dir")
        let b = makeSession(id: "b", status: "idle", project: "proj-b", cwd: "/shared/dir")
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1,
            "Sessions with same CWD but different project names should be merged")
    }

    func testSessionsWithSameProjectButDifferentCWDsAreNotMerged() {
        let a = makeSession(id: "a", status: "idle", project: "proj", cwd: "/dir-a")
        let b = makeSession(id: "b", status: "idle", project: "proj", cwd: "/dir-b")
        // Same project name but different CWD → separate rows (e.g. ~/Development/monolith vs .../workspaces/monolith)
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Terminal info merging

    func testTerminalInfoTakenFromFirstSessionThatHasIt() {
        // Both have empty terminal_session_id (recovery sessions), so grouped by project|cwd.
        // Working beats idle on status, but should inherit terminal name from idle.
        let noTerminal = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            terminal: "", terminalSessionId: "",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let withTerminal = makeSession(
            id: "i", status: "idle", project: "proj", cwd: "/proj",
            terminal: "ghostty", terminalSessionId: ""
        )
        let result = aggregateSessions([noTerminal, withTerminal], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "working")
        XCTAssertEqual(result[0].terminal, "ghostty",
            "Terminal info should be inherited from first session that has it")
    }

    func testTerminalInfoPreservedIfRepresentativeHasIt() {
        // Both have empty terminal_session_id (recovery sessions), so grouped by project|cwd.
        let withTerminal = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            terminal: "iterm2", terminalSessionId: "",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let noTerminal = makeSession(
            id: "i", status: "idle", project: "proj", cwd: "/proj",
            terminal: "", terminalSessionId: ""
        )
        let result = aggregateSessions([withTerminal, noTerminal], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].terminal, "iterm2")
    }

    // MARK: - started_at merging

    func testStartedAtTakesEarliestOfGroup() {
        let earlyDate = referenceDate.addingTimeInterval(-3600)  // 1 hour ago
        let lateDate = referenceDate.addingTimeInterval(-60)     // 1 minute ago
        let early = makeSession(
            id: "a", status: "idle", project: "proj", cwd: "/proj",
            startedAt: earlyDate
        )
        let late = makeSession(
            id: "b", status: "idle", project: "proj", cwd: "/proj",
            startedAt: lateDate
        )
        let result = aggregateSessions([early, late], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].started_at, fmt.string(from: earlyDate),
            "Merged session should use the earliest started_at for maximum elapsed time")
    }

    // MARK: - last_prompt merging

    func testLastPromptTakenFromFirstSessionThatHasIt() {
        let noPrompt = makeSession(
            id: "w", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10),
            lastPrompt: ""
        )
        let withPrompt = makeSession(
            id: "i", status: "idle", project: "proj", cwd: "/proj",
            lastPrompt: "hello world"
        )
        let result = aggregateSessions([noPrompt, withPrompt], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].last_prompt, "hello world")
    }

    // MARK: - skip_permissions propagation

    func testSkipPermissionsPropagatedOnMerge() {
        let normal = makeSession(
            id: "n", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        var skipPerms = makeSession(id: "s", status: "idle", project: "proj", cwd: "/proj")
        skipPerms.skip_permissions = true
        let result = aggregateSessions([normal, skipPerms], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].skip_permissions, true,
            "Merged session should inherit skip_permissions from any group member")
    }

    func testSkipPermissionsNilWhenNoMemberHasIt() {
        let a = makeSession(
            id: "a", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let b = makeSession(id: "b", status: "idle", project: "proj", cwd: "/proj")
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].skip_permissions)
    }

    // MARK: - merged_session_ids tracking

    func testMergedSessionIdsContainsAllGroupMembers() {
        // Scenario: qr-code-ordering has 4 sessions sharing terminal_session_id "55".
        // One is a team lead (idle), others are working subagents.
        // After aggregation, the representative is a "working" session, but we need
        // ALL session_ids preserved so team matching (keyed by leadSessionId) still works.
        let teamLead = makeSession(
            id: "ba0b2782", status: "idle", project: "qr-code-ordering",
            cwd: "/workspaces/qr-code-ordering", terminalSessionId: "55"
        )
        let worker1 = makeSession(
            id: "25218267", status: "working", project: "qr-code-ordering",
            cwd: "/workspaces/qr-code-ordering", terminalSessionId: "55",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let worker2 = makeSession(
            id: "9d97c36d", status: "working", project: "qr-code-ordering",
            cwd: "/workspaces/qr-code-ordering", terminalSessionId: "55",
            updatedAt: referenceDate.addingTimeInterval(-20)
        )

        let result = aggregateSessions([teamLead, worker1, worker2], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        // The representative should be "working" (higher priority than idle)
        XCTAssertEqual(result[0].status, "working")
        // ALL session IDs from the group must be discoverable for team matching
        let mergedIds = result[0].merged_session_ids ?? []
        XCTAssertTrue(mergedIds.contains("ba0b2782"),
            "Team lead session_id must be preserved in merged_session_ids")
        XCTAssertTrue(mergedIds.contains("25218267"),
            "Representative session_id must be in merged_session_ids")
        XCTAssertTrue(mergedIds.contains("9d97c36d"),
            "All group member session_ids must be in merged_session_ids")
    }

    func testSingleSessionHasNoMergedSessionIds() {
        let session = makeSession(id: "s1", status: "idle", project: "proj", cwd: "/proj",
            terminalSessionId: "42")
        let result = aggregateSessions([session], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].merged_session_ids,
            "Single sessions should not have merged_session_ids (no merge happened)")
    }

    func testSkipPermissionsPropagatedAcrossTerminalSessionIdGroup() {
        // Scenario: devcontainer session where skip_permissions is set on one session
        // but the representative is a different session. skip_permissions must propagate.
        var withSkip = makeSession(
            id: "lead", status: "idle", project: "proj",
            cwd: "/proj", terminalSessionId: "55"
        )
        withSkip.skip_permissions = true
        let worker = makeSession(
            id: "worker", status: "working", project: "proj",
            cwd: "/proj", terminalSessionId: "55",
            updatedAt: referenceDate.addingTimeInterval(-10)
        )
        let result = aggregateSessions([withSkip, worker], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, "working")
        XCTAssertEqual(result[0].skip_permissions, true,
            "skip_permissions must propagate even when the session with the flag is not the representative")
    }

    // MARK: - terminal_session_id grouping

    func testSameTerminalSessionIdAggregated() {
        let a = makeSession(id: "a", status: "idle", project: "proj", cwd: "/proj",
            terminalSessionId: "/dev/ttys005")
        let b = makeSession(id: "b", status: "working", project: "proj", cwd: "/proj",
            terminalSessionId: "/dev/ttys005",
            updatedAt: referenceDate.addingTimeInterval(-10))
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1,
            "Sessions with the same terminal_session_id should be aggregated")
    }

    func testDifferentTerminalSessionIdSameProjectCwdNotAggregated() {
        let a = makeSession(id: "a", status: "idle", project: "proj", cwd: "/proj",
            terminalSessionId: "/dev/ttys003")
        let b = makeSession(id: "b", status: "idle", project: "proj", cwd: "/proj",
            terminalSessionId: "/dev/ttys004")
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 2,
            "Sessions with different terminal_session_ids should NOT be aggregated even if project+cwd match")
    }

    func testTerminalSessionIdGroupsExemptFromCwdMerge() {
        let a = makeSession(id: "a", status: "idle", project: "proj-a", cwd: "/shared/dir",
            terminalSessionId: "/dev/ttys001")
        let b = makeSession(id: "b", status: "idle", project: "proj-b", cwd: "/shared/dir",
            terminalSessionId: "/dev/ttys002")
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 2,
            "terminal_session_id groups should not be merged by CWD overlap")
    }

    func testEmptyTerminalSessionIdFallsBackToProjectCwdGrouping() {
        let a = makeSession(id: "a", status: "idle", project: "proj", cwd: "/proj")
        let b = makeSession(id: "b", status: "working", project: "proj", cwd: "/proj",
            updatedAt: referenceDate.addingTimeInterval(-10))
        // Both have empty terminal_session_id → should group by project|cwd
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 1,
            "Empty terminal_session_id sessions should fall back to project|cwd grouping")
    }

    func testMixedTerminalSessionIdAndEmptyNotMerged() {
        let a = makeSession(id: "a", status: "idle", project: "proj", cwd: "/proj",
            terminalSessionId: "/dev/ttys007")
        let b = makeSession(id: "b", status: "idle", project: "proj", cwd: "/proj")
        // b has empty terminal_session_id
        let result = aggregateSessions([a, b], referenceDate: referenceDate)
        XCTAssertEqual(result.count, 2,
            "Session with terminal_session_id should not merge with session without one")
    }
}

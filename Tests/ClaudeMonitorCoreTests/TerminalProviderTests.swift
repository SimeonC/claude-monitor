import XCTest
@testable import ClaudeMonitorCore

// MARK: - Mock Provider for testing matchSessions logic

/// Configurable mock that delegates matching to a closure.
private class MockProvider: TerminalProvider {
    let name: String
    let bundleIdentifier: String
    var matchImpl: (([SessionInfo], FocusedSurface, [String: String]) -> [SessionInfo])?

    init(name: String, bundleId: String) {
        self.name = name
        self.bundleIdentifier = bundleId
    }

    func focusedSurface() -> FocusedSurface? { nil }
    func focusSurface(session: SessionInfo, ttyMap: [String: String]) {}
    func matchSessions(_ sessions: [SessionInfo], toSurface surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
        matchImpl?(sessions, surface, ttyMap) ?? []
    }
}

// MARK: - Ghostty-style matching (tests the matching logic patterns)

/// Reusable Ghostty-style matching for unit tests (same logic as GhosttyProvider.matchSessions).
private func ghosttyMatch(_ sessions: [SessionInfo], surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
    let ghosttySessions = sessions.filter { $0.terminal == "ghostty" }

    var candidates = ghosttySessions.filter { $0.ghostty_terminal_id == surface.id }

    if candidates.isEmpty {
        let matchedTTYs = Set(ttyMap.filter { $0.value == surface.id }.map { $0.key })
        candidates = ghosttySessions.filter { matchedTTYs.contains($0.terminal_session_id) }
        let candidateIds = Set(candidates.map { $0.session_id })
        candidates += ghosttySessions.filter {
            $0.terminal_session_id == surface.id && !candidateIds.contains($0.session_id)
        }
    }

    return candidates
}

/// iTerm2-style matching
private func iterm2Match(_ sessions: [SessionInfo], surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
    sessions.filter { session in
        guard session.terminal == "iterm2" else { return false }
        let parts = session.terminal_session_id.split(separator: ":")
        return parts.count >= 2 && String(parts[1]) == surface.id
    }
}

/// Terminal.app-style matching
private func terminalMatch(_ sessions: [SessionInfo], surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
    sessions.filter { $0.terminal == "terminal" && $0.terminal_session_id == surface.id }
}

/// CMUX-style matching — surface ID only. Different tab in same workspace is NOT focused.
/// surface.id = "surfaceRef|surfaceUUID"
private func cmuxMatch(_ sessions: [SessionInfo], surface: FocusedSurface, ttyMap: [String: String]) -> [SessionInfo] {
    let cmux = sessions.filter { $0.terminal == "cmux" }
    let surfaceIds = Set(surface.id.split(separator: "|").map(String.init).filter { !$0.isEmpty })
    return cmux.filter {
        guard let s = $0.cmux_surface_id, !s.isEmpty else { return false }
        return surfaceIds.contains(s)
    }
}

// MARK: - Tests

final class TerminalProviderTests: XCTestCase {

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeSession(
        id: String,
        status: String = "idle",
        terminal: String = "ghostty",
        terminalSessionId: String = "",
        ghosttyTerminalId: String? = nil,
        cmuxSurfaceId: String? = nil,
        cmuxWorkspaceId: String? = nil,
        updatedAt: Date? = nil,
        cwd: String = "/test",
        project: String = "test"
    ) -> SessionInfo {
        let updated = updatedAt ?? referenceDate
        return SessionInfo(
            session_id: id,
            status: status,
            project: project,
            cwd: cwd,
            terminal: terminal,
            terminal_session_id: terminalSessionId,
            started_at: fmt.string(from: referenceDate.addingTimeInterval(-60)),
            updated_at: fmt.string(from: updated),
            last_prompt: "",
            ghostty_terminal_id: ghosttyTerminalId,
            cmux_surface_id: cmuxSurfaceId,
            cmux_workspace_id: cmuxWorkspaceId
        )
    }

    // MARK: - bestCandidate

    func testBestCandidateEmptyReturnsNil() {
        XCTAssertNil(bestCandidate([]))
    }

    func testBestCandidatePicksAttentionOverWorking() {
        let attention = makeSession(id: "a", status: "attention")
        let working = makeSession(id: "w", status: "working")
        let result = bestCandidate([working, attention], referenceDate: referenceDate)
        XCTAssertEqual(result?.session_id, "a")
    }

    func testBestCandidatePicksWorkingOverIdle() {
        let working = makeSession(id: "w", status: "working")
        let idle = makeSession(id: "i", status: "idle")
        let result = bestCandidate([idle, working], referenceDate: referenceDate)
        XCTAssertEqual(result?.session_id, "w")
    }

    func testBestCandidatePicksMostRecentOnTie() {
        let older = makeSession(id: "old", status: "idle",
                                updatedAt: referenceDate.addingTimeInterval(-100))
        let newer = makeSession(id: "new", status: "idle",
                                updatedAt: referenceDate.addingTimeInterval(-10))
        let result = bestCandidate([older, newer], referenceDate: referenceDate)
        XCTAssertEqual(result?.session_id, "new")
    }

    func testBestCandidateStaleWorkingDemotedBelowIdle() {
        // "working" updated 6 minutes ago → stale → demoted below idle
        let now = Date()
        let staleWorking = makeSession(id: "w", status: "working",
                                       updatedAt: now.addingTimeInterval(-360))
        let idle = makeSession(id: "i", status: "idle",
                               updatedAt: now.addingTimeInterval(-10))
        let result = bestCandidate([staleWorking, idle], referenceDate: now)
        XCTAssertEqual(result?.session_id, "i")
    }

    func testBestCandidateFreshWorkingBeatsIdle() {
        let now = Date()
        let freshWorking = makeSession(id: "w", status: "working",
                                       updatedAt: now.addingTimeInterval(-10))
        let idle = makeSession(id: "i", status: "idle",
                               updatedAt: now.addingTimeInterval(-10))
        let result = bestCandidate([freshWorking, idle], referenceDate: now)
        XCTAssertEqual(result?.session_id, "w")
    }

    // MARK: - Ghostty matching

    func testGhosttyDirectUUIDMatch() {
        let session = makeSession(id: "s1", terminal: "ghostty",
                                  terminalSessionId: "/dev/ttys000",
                                  ghosttyTerminalId: "uuid-123")
        let surface = FocusedSurface(id: "uuid-123")
        let result = ghosttyMatch([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "s1")
    }

    func testGhosttyTtyMapReverseLookup() {
        let session = makeSession(id: "s1", terminal: "ghostty",
                                  terminalSessionId: "/dev/ttys005")
        let surface = FocusedSurface(id: "uuid-456")
        let ttyMap = ["/dev/ttys005": "uuid-456"]
        let result = ghosttyMatch([session], surface: surface, ttyMap: ttyMap)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "s1")
    }

    func testGhosttyBackwardCompatDirectUUID() {
        // Old session with UUID directly in terminal_session_id
        let session = makeSession(id: "s1", terminal: "ghostty",
                                  terminalSessionId: "uuid-789")
        let surface = FocusedSurface(id: "uuid-789")
        let result = ghosttyMatch([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
    }

    func testGhosttyNoMatchReturnsEmpty() {
        let session = makeSession(id: "s1", terminal: "ghostty",
                                  terminalSessionId: "/dev/ttys000",
                                  ghosttyTerminalId: "uuid-111")
        let surface = FocusedSurface(id: "uuid-999")
        let result = ghosttyMatch([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testGhosttyFiltersOtherTerminals() {
        let ghosttySession = makeSession(id: "g1", terminal: "ghostty",
                                         ghosttyTerminalId: "uuid-123")
        let itermSession = makeSession(id: "i1", terminal: "iterm2",
                                       terminalSessionId: "uuid-123")
        let surface = FocusedSurface(id: "uuid-123")
        let result = ghosttyMatch([ghosttySession, itermSession], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "g1")
    }

    // MARK: - iTerm2 matching

    func testITerm2GUIDMatch() {
        let session = makeSession(id: "s1", terminal: "iterm2",
                                  terminalSessionId: "w0t0p0:ABC-DEF-123")
        let surface = FocusedSurface(id: "ABC-DEF-123")
        let result = iterm2Match([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
    }

    func testITerm2NoMatchWrongGUID() {
        let session = makeSession(id: "s1", terminal: "iterm2",
                                  terminalSessionId: "w0t0p0:ABC-DEF-123")
        let surface = FocusedSurface(id: "WRONG-GUID")
        let result = iterm2Match([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Terminal.app matching

    func testTerminalAppTTYMatch() {
        let session = makeSession(id: "s1", terminal: "terminal",
                                  terminalSessionId: "/dev/ttys003")
        let surface = FocusedSurface(id: "/dev/ttys003")
        let result = terminalMatch([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
    }

    func testTerminalAppNoMatch() {
        let session = makeSession(id: "s1", terminal: "terminal",
                                  terminalSessionId: "/dev/ttys003")
        let surface = FocusedSurface(id: "/dev/ttys999")
        let result = terminalMatch([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - CMUX matching (ID-based: surface UUID/ref then workspace UUID/ref fallback)

    func testCMUXSurfaceRefMatch() {
        // surface.id = "surface:4|UUID", stored cmux_surface_id = "surface:4" (ref)
        let session = makeSession(id: "s1", terminal: "cmux",
                                  cmuxSurfaceId: "surface:4",
                                  cmuxWorkspaceId: "workspace:2")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "s1")
    }

    func testCMUXSurfaceUUIDMatch() {
        // surface.id = "surface:4|UUID", stored cmux_surface_id = UUID (from env var)
        let session = makeSession(id: "s1", terminal: "cmux",
                                  cmuxSurfaceId: "BFCA-1234",
                                  cmuxWorkspaceId: "WSID-5678")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([session], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "s1")
    }

    func testCMUXDifferentSurfaceSameWorkspaceNotFocused() {
        // Different tab in same workspace — must NOT match (not focused)
        let session = makeSession(id: "s1", terminal: "cmux",
                                  cmuxSurfaceId: "surface:99",
                                  cmuxWorkspaceId: "workspace:2")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testCMUXNoMatchWrongIDs() {
        let session = makeSession(id: "s1", terminal: "cmux",
                                  cmuxSurfaceId: "surface:99",
                                  cmuxWorkspaceId: "workspace:99")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testCMUXSessionWithoutIDsNoMatch() {
        // Session has no cmux IDs stored
        let session = makeSession(id: "s1", terminal: "cmux")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([session], surface: surface, ttyMap: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testCMUXFiltersOtherTerminals() {
        let cmuxSession = makeSession(id: "c1", terminal: "cmux",
                                      cmuxSurfaceId: "BFCA-1234")
        let ghosttySession = makeSession(id: "g1", terminal: "ghostty",
                                         ghosttyTerminalId: "BFCA-1234")
        let surface = FocusedSurface(id: "surface:4|BFCA-1234", tabName: "workspace:2|WSID-5678")
        let result = cmuxMatch([cmuxSession, ghosttySession], surface: surface, ttyMap: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].session_id, "c1")
    }

    // MARK: - Cross-terminal: same CWD, different terminals stay separate

    func testSameCwdGhosttyAndCmuxStaySeparate() {
        // Both sessions at the same directory but in different terminals
        let ghosttySession = makeSession(id: "g1", terminal: "ghostty",
                                         terminalSessionId: "/dev/ttys000",
                                         ghosttyTerminalId: "ghostty-uuid-1",
                                         cwd: "/Users/dev/my-project", project: "my-project")
        let cmuxSession = makeSession(id: "c1", terminal: "cmux",
                                      terminalSessionId: "container:/dev/pts/1",
                                      cmuxSurfaceId: "SURF-UUID-1",
                                      cmuxWorkspaceId: "WS-UUID-1",
                                      cwd: "/workspaces/my-project", project: "my-project")

        // Ghostty surface should only match Ghostty session
        let ghosttySurface = FocusedSurface(id: "ghostty-uuid-1")
        let ghosttyResult = ghosttyMatch([ghosttySession, cmuxSession], surface: ghosttySurface, ttyMap: [:])
        XCTAssertEqual(ghosttyResult.count, 1)
        XCTAssertEqual(ghosttyResult[0].session_id, "g1")

        // CMUX surface should only match CMUX session
        let cmuxSurface = FocusedSurface(id: "surface:1|SURF-UUID-1", tabName: "workspace:1|WS-UUID-1")
        let cmuxResult = cmuxMatch([ghosttySession, cmuxSession], surface: cmuxSurface, ttyMap: [:])
        XCTAssertEqual(cmuxResult.count, 1)
        XCTAssertEqual(cmuxResult[0].session_id, "c1")
    }

    func testSameCwdCmuxAndGhosttyBothKept() {
        // Verify neither provider claims the other terminal's sessions
        let ghostty = makeSession(id: "g1", terminal: "ghostty",
                                  ghosttyTerminalId: "uuid-A",
                                  cwd: "/Users/dev/shared-project", project: "shared-project")
        let cmux = makeSession(id: "c1", terminal: "cmux",
                               cmuxSurfaceId: "SURF-UUID-A",
                               cmuxWorkspaceId: "WS-UUID-A",
                               cwd: "/workspaces/shared-project", project: "shared-project")
        let both = [ghostty, cmux]

        // Ghostty surface: only ghostty session
        let gSurface = FocusedSurface(id: "uuid-A")
        XCTAssertEqual(ghosttyMatch(both, surface: gSurface, ttyMap: [:]).map(\.session_id), ["g1"])

        // CMUX surface: only cmux session
        let cSurface = FocusedSurface(id: "surface:1|SURF-UUID-A", tabName: "workspace:1|WS-UUID-A")
        XCTAssertEqual(cmuxMatch(both, surface: cSurface, ttyMap: [:]).map(\.session_id), ["c1"])
    }

    // MARK: - FocusedSurface

    func testFocusedSurfaceInit() {
        let surface = FocusedSurface(id: "test-id", tabName: "my tab")
        XCTAssertEqual(surface.id, "test-id")
        XCTAssertEqual(surface.tabName, "my tab")
    }

    func testFocusedSurfaceDefaultTabName() {
        let surface = FocusedSurface(id: "test-id")
        XCTAssertNil(surface.tabName)
    }

    // MARK: - Multiple candidates with bestCandidate integration

    func testMultipleGhosttySessionsSameUUIDPicksBest() {
        let attention = makeSession(id: "a1", status: "attention", terminal: "ghostty",
                                    ghosttyTerminalId: "uuid-shared")
        let idle = makeSession(id: "i1", status: "idle", terminal: "ghostty",
                               ghosttyTerminalId: "uuid-shared")
        let surface = FocusedSurface(id: "uuid-shared")
        let candidates = ghosttyMatch([attention, idle], surface: surface, ttyMap: [:])
        XCTAssertEqual(candidates.count, 2)
        let best = bestCandidate(candidates)
        XCTAssertEqual(best?.session_id, "a1")
    }
}
